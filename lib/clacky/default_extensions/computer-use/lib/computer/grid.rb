# frozen_string_literal: true

require "fiddle"
require "fiddle/import"

module Clacky
  module Computer
    # Draws a labelled measurement grid over a captured PNG so the model can
    # read pixel coordinates straight off the image instead of counting pixels
    # or scripting its own PIL overlays.
    #
    # WHY Fiddle + vImage instead of an image gem: the extension ships no
    # native dependencies, and every macOS box carries CoreGraphics and
    # Accelerate. Every struct argument (vImage_Buffer, vImage_CGImageFormat)
    # is passed by pointer, so the ABI is identical on arm64 and x86_64 —
    # Fiddle cannot pass structs by value.
    module Grid
      APP_SERVICES = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
      CORE_FOUNDATION = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
      ACCELERATE = "/System/Library/Frameworks/Accelerate.framework/Accelerate"
      LIBSYSTEM = "/usr/lib/libSystem.dylib"
      UTF8 = 0x08000100

      # kCGImageAlphaPremultipliedFirst | kCGImageByteOrder32Little — BGRA8888,
      # the layout vImageAlphaBlend_ARGB8888 expects on a little-endian host.
      BITMAP_INFO = 2 | (2 << 12)
      FONT_SIZE = 14.0
      LINE_ALPHA = 0.85

      module API
        extend Fiddle::Importer
        dlload APP_SERVICES, CORE_FOUNDATION, ACCELERATE, LIBSYSTEM

        extern "void* CGColorSpaceCreateDeviceRGB()"
        extern "void* CGColorCreate(void*, void*)"
        extern "void* CGBitmapContextCreate(void*, unsigned long, unsigned long, unsigned long, unsigned long, void*, unsigned int)"
        extern "void CGContextSetStrokeColorWithColor(void*, void*)"
        extern "void CGContextSetFillColorWithColor(void*, void*)"
        extern "void CGContextSetLineWidth(void*, double)"
        extern "void CGContextSetTextDrawingMode(void*, int)"
        extern "void CGContextStrokeLineSegments(void*, void*, unsigned long)"
        extern "int CGContextSelectFont(void*, char*, double, int)"
        extern "void CGContextShowTextAtPoint(void*, double, double, char*, unsigned long)"
        extern "void* CGBitmapContextCreateImage(void*)"
        extern "void CGContextRelease(void*)"
        extern "void* CFURLCreateWithFileSystemPath(void*, void*, int, unsigned char)"
        extern "void* CFStringCreateWithCString(void*, char*, unsigned int)"
        extern "void* CGImageSourceCreateWithURL(void*, void*)"
        extern "void* CGImageSourceCreateImageAtIndex(void*, unsigned long, void*)"
        extern "unsigned long CGImageGetWidth(void*)"
        extern "unsigned long CGImageGetHeight(void*)"
        extern "void* CGImageDestinationCreateWithURL(void*, void*, unsigned long, void*)"
        extern "void CGImageDestinationAddImage(void*, void*, void*)"
        extern "int CGImageDestinationFinalize(void*)"
        extern "int vImageBuffer_InitWithCGImage(void*, void*, void*, void*, unsigned int)"
        extern "void vImageAlphaBlend_ARGB8888(void*, void*, void*, unsigned int)"
        extern "void* vImageCreateCGImageFromBuffer(void*, void*, void*, void*, unsigned int)"
        extern "void free(void*)"
      end

      K_CG_TEXT_FILL_STROKE = 2
      CG_ERROR_SUCCESS = 0

      class GridError < StandardError; end

      # Overlays a grid with pixel labels on `png` and writes it next to it as
      # `<name>-grid.png`. Returns the new path. Labels are image-space pixels,
      # matching the coordinates `click`/`move` expect from the model.
      def self.annotate(png, step)
        step = step.to_i
        raise GridError, "grid step must be >= 25px" if step < 25

        dst = png.to_s.sub(/\.png\z/i, "") + "-grid.png"
        space = API.CGColorSpaceCreateDeviceRGB.to_i
        format = cg_image_format(space)

        pixels = buffer_from_png(png, format)
        overlay = buffer_from_grid(pixels[:width], pixels[:height], step, space)

        err = API.vImageAlphaBlend_ARGB8888(overlay[:struct], pixels[:struct],
                                            pixels[:struct], 0)
        raise GridError, "vImageAlphaBlend failed (#{err})" unless err.to_i == CG_ERROR_SUCCESS

        write_png(pixels, format, space, dst)
        dst
      ensure
        free_buffer(overlay) if defined?(overlay)
        free_buffer(pixels) if defined?(pixels)
      end

      # ---- buffers ----

      def self.buffer_from_png(png, format)
        path = cf_string(png.to_s)
        url = API.CFURLCreateWithFileSystemPath(nil, path, 0, 0)
        src = API.CGImageSourceCreateWithURL(url.to_i, nil)
        raise GridError, "cannot read #{png}" if src.nil? || src.to_i.zero?

        image = API.CGImageSourceCreateImageAtIndex(src.to_i, 0, nil)
        raise GridError, "cannot decode #{png}" if image.nil? || image.to_i.zero?

        width = API.CGImageGetWidth(image.to_i)
        height = API.CGImageGetHeight(image.to_i)
        buffer = wrap_buffer(width, height)
        err = API.vImageBuffer_InitWithCGImage(buffer, format, nil, image.to_i, 0)
        raise GridError, "cannot decode #{png} (#{err})" unless err.to_i == CG_ERROR_SUCCESS
        { struct: buffer, data: buffer_data(buffer), width: width, height: height }
      end

      def self.buffer_from_grid(width, height, step, space)
        ctx = API.CGBitmapContextCreate(nil, width, height, 8, width * 4,
                                        space, BITMAP_INFO)
        raise GridError, "CGBitmapContextCreate failed" if ctx.nil? || ctx.to_i.zero?

        draw_grid(ctx.to_i, width, height, step, space)

        image = API.CGBitmapContextCreateImage(ctx.to_i)
        API.CGContextRelease(ctx.to_i)
        raise GridError, "grid image creation failed" if image.nil? || image.to_i.zero?

        format = cg_image_format(space)
        buffer = wrap_buffer(width, height)
        err = API.vImageBuffer_InitWithCGImage(buffer, format, nil, image.to_i, 0)
        raise GridError, "grid buffer init failed (#{err})" unless err.to_i == CG_ERROR_SUCCESS
        { struct: buffer, data: buffer_data(buffer), width: width, height: height }
      end

      # CoreGraphics text uses a bottom-left origin; the image the model sees is
      # top-left, so labels flip: y_image = height - y_cg.
      def self.draw_grid(ctx, width, height, step, space)
        magenta = API.CGColorCreate(space, [1.0, 0.0, 1.0, LINE_ALPHA].pack("D*")).to_i
        white = API.CGColorCreate(space, [1.0, 1.0, 1.0, 1.0].pack("D*")).to_i
        black = API.CGColorCreate(space, [0.0, 0.0, 0.0, 1.0].pack("D*")).to_i

        segments = []
        (step...width).step(step) { |x| segments << [x, 0, x, height] }
        (step...height).step(step) { |y| segments << [0, height - y, width, height - y] }
        points = Fiddle::Pointer.malloc(segments.length * 32)
        points[0, segments.length * 32] = segments.flatten.pack("D*")

        API.CGContextSetStrokeColorWithColor(ctx, magenta)
        API.CGContextSetLineWidth(ctx, 1.0)
        API.CGContextStrokeLineSegments(ctx, points, segments.length * 2)

        API.CGContextSelectFont(ctx, "Helvetica", FONT_SIZE, 1)
        API.CGContextSetTextDrawingMode(ctx, K_CG_TEXT_FILL_STROKE)
        API.CGContextSetFillColorWithColor(ctx, white)
        API.CGContextSetStrokeColorWithColor(ctx, black)
        API.CGContextSetLineWidth(ctx, 2.0)

        (step...width).step(step) { |x| show_label(ctx, x.to_s, x + 2, height - FONT_SIZE) }
        (step...height).step(step) { |y| show_label(ctx, y.to_s, 2, height - y - FONT_SIZE) }
      end

      def self.show_label(ctx, text, x, y)
        buf = Fiddle::Pointer.malloc(text.bytesize + 1)
        buf[0, text.bytesize] = text
        API.CGContextShowTextAtPoint(ctx, x.to_f, y.to_f, buf, text.bytesize)
      end

      def self.write_png(pixels, format, space, dst)
        image = API.vImageCreateCGImageFromBuffer(pixels[:struct], format, nil,
                                                  Fiddle::Pointer.malloc(4), 0)
        raise GridError, "vImageCreateCGImageFromBuffer failed" if image.nil? || image.to_i.zero?

        url = API.CFURLCreateWithFileSystemPath(nil, cf_string(File.expand_path(dst)), 0, 0)
        dest = API.CGImageDestinationCreateWithURL(url.to_i, cf_string("public.png").to_i, 1, nil)
        raise GridError, "CGImageDestinationCreateWithURL failed" if dest.nil? || dest.to_i.zero?

        API.CGImageDestinationAddImage(dest.to_i, image.to_i, nil)
        API.CGImageDestinationFinalize(dest.to_i)
        raise GridError, "writing #{dst} failed" unless File.exist?(dst)
      end

      # ---- Fiddle struct helpers ----
      # All structs are zeroed first: Fiddle::Pointer.malloc returns uninitialized
      # memory, and vImage dereferences every field (a garbage decode pointer
      # segfaults).

      def self.cg_image_format(colorspace)
        format = Fiddle::Pointer.malloc(40)
        format[0, 40] = "\0" * 40
        format[0, 4] = [8].pack("L")
        format[4, 4] = [32].pack("L")
        format[8, 8] = [colorspace.to_i].pack("Q")
        format[16, 4] = [BITMAP_INFO].pack("L")
        format
      end

      def self.wrap_buffer(width, height)
        buffer = Fiddle::Pointer.malloc(32)
        buffer[0, 32] = "\0" * 32
        buffer[8, 8] = [height].pack("Q")
        buffer[16, 8] = [width].pack("Q")
        buffer[24, 8] = [width * 4].pack("Q")
        buffer
      end

      def self.buffer_data(buffer)
        Fiddle::Pointer.new(buffer[0, 8].unpack1("Q"))
      end

      def self.free_buffer(buffer)
        API.free(buffer[:data].to_i) if buffer[:data] && buffer[:data].to_i != 0
      end

      def self.cf_string(str)
        buf = Fiddle::Pointer.malloc(str.bytesize + 1)
        buf[0, str.bytesize] = str
        API.CFStringCreateWithCString(nil, buf, UTF8).to_i
      end
    end
  end
end
