# frozen_string_literal: true

require "fiddle"
require "fiddle/import"
require "open3"
require_relative "geometry"
require_relative "keycodes"
require_relative "grid"

module Clacky
  module Computer
    # macOS backend. Screen capture shell outs to `screencapture`; everything else
    # goes straight to CoreGraphics through Fiddle.
    #
    # WHY Fiddle instead of `osascript`: the desktop app runs under a hardened
    # runtime without the com.apple.security.automation.apple-events entitlement,
    # so tccd rejects every AppleEvent it sends. Direct CoreGraphics calls instead
    # inherit the app's own Screen Recording / Accessibility grants.
    #
    # WHY odd-looking signatures: Fiddle cannot receive struct *return* values
    # (libffi struct support is not exposed), so no API returning CGPoint/CGRect is
    # called. Where a CGPoint must be passed *by value* it is declared as two
    # doubles — the register assignment is byte-identical to a {double,double}
    # struct on arm64 and x86_64, so the ABI still matches.
    class MacOS
      class PermissionError < ::Clacky::Computer::PermissionError; end

      APP_SERVICES = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
      CORE_FOUNDATION = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
      SCREENCAPTURE = "/usr/sbin/screencapture"

      # TCC grants bind to the process that launched this server, so point at the
      # user-facing app rather than an internal binary name.
      PERMISSION_HINT = "Open System Settings → Privacy & Security, enable it for the app that launched this server " \
                        "(OpenClacky, or your terminal app), then retry.".freeze

      WINDOW_LIST_ON_SCREEN_ONLY = 1
      NULL_WINDOW_ID = 0
      UTF8 = 0x08000100

      # kCGEventTapLocation / kCGScrollEventUnit / mouse event kinds
      HID_EVENT_TAP = 0
      SESSION_EVENT_TAP = 1
      SCROLL_UNIT_PIXEL = 0
      MOUSE_EVENT_TYPES = {
        "left" => { down: 1, up: 2, dragged: 6, button: 0 },
        "right" => { down: 3, up: 4, dragged: 7, button: 1 },
        "middle" => { down: 25, up: 26, dragged: 27, button: 2 }
      }.freeze
      MOUSE_MOVED = 5
      EVENT_FLAGS_CHANGED = 12
      SCROLL_EVENT = 22
      CLICK_STATE_FIELD = 1

      module API
        extend Fiddle::Importer
        dlload APP_SERVICES, CORE_FOUNDATION

        # -- permissions --
        extern "int CGPreflightScreenCaptureAccess()"
        extern "int CGRequestScreenCaptureAccess()"
        extern "int AXIsProcessTrusted()"

        # -- displays --
        extern "unsigned int CGMainDisplayID()"
        extern "int CGGetActiveDisplayList(unsigned int, void*, void*)"
        extern "int CGDisplayIsMain(unsigned int)"
        extern "int CGDisplayIsBuiltin(unsigned int)"
        extern "void* CGDisplayCopyDisplayMode(unsigned int)"
        extern "unsigned long CGDisplayModeGetWidth(void*)"
        extern "unsigned long CGDisplayModeGetHeight(void*)"
        extern "unsigned long CGDisplayModeGetPixelWidth(void*)"
        extern "unsigned long CGDisplayModeGetPixelHeight(void*)"

        # -- window list (display origins live here) --
        extern "void* CGWindowListCopyWindowInfo(unsigned int, unsigned int)"
        extern "long CFArrayGetCount(void*)"
        extern "void* CFArrayGetValueAtIndex(void*, long)"
        extern "void* CFDictionaryGetValue(void*, void*)"
        extern "void* CFStringCreateWithCString(void*, char*, unsigned int)"
        extern "int CFStringGetCString(void*, char*, long, unsigned int)"
        extern "int CFNumberGetValue(void*, int, void*)"
        extern "int CFGetTypeID(void*)"
        extern "unsigned long CFNumberGetTypeID()"
        extern "unsigned long CFStringGetTypeID()"
        extern "void CFRelease(void*)"

        # -- event injection --
        extern "int CGWarpMouseCursorPosition(double, double)"
        extern "void* CGEventCreate(void*)"
        extern "void* CGEventCreateMouseEvent(void*, unsigned int, double, double, unsigned int)"
        extern "void* CGEventCreateKeyboardEvent(void*, unsigned int, int)"
        extern "void* CGEventCreateScrollWheelEvent2(void*, unsigned int, unsigned int, int, int, int)"
        extern "void CGEventKeyboardSetUnicodeString(void*, unsigned long, void*)"
        extern "void CGEventSetIntegerValueField(void*, unsigned int, long)"
        extern "void CGEventSetFlags(void*, unsigned long)"
        extern "void CGEventPost(unsigned int, void*)"
      end

      MAX_DISPLAYS = 16
      SIPS = "/usr/bin/sips"

      CLICK_INTERVAL = 0.05      # gap between clicks of a double/triple click
      KEY_INTERVAL = 0.05        # gap between repeated key presses
      DRAG_STEPS = 12            # interpolated move events inside one drag
      UNICODE_CHUNK_CHARS = 20   # apps truncate long unicode keyboard events

      def initialize
        @cursor = nil
        @handles = nil
      end

      # macOS cannot read the pointer — CGEventGetLocation returns a CGPoint by
      # value, which Fiddle cannot marshal — so callers always get nil. @cursor
      # still tracks the last position this process moved to, for internal use.
      def cursor
        nil
      end

      def screen_recording_allowed?
        API.CGPreflightScreenCaptureAccess.to_i != 0
      end

      # macOS never prompts for Screen Recording; an app only appears in
      # System Settings after it has asked at least once, so this call is what
      # makes the toggle exist.
      def request_screen_recording!
        API.CGRequestScreenCaptureAccess.to_i != 0
      end

      def accessibility_allowed?
        API.AXIsProcessTrusted.to_i != 0
      end

      # Posts a harmless zero-delta scroll, which is what makes macOS show the
      # "wants to control this computer" prompt and register the app in
      # System Settings > Accessibility.
      def request_accessibility!
        post_scroll(0, 0)
        accessibility_allowed?
      end

      def missing_permissions
        list = []
        list << "screen_recording" unless screen_recording_allowed?
        list << "accessibility" unless accessibility_allowed?
        list
      end

      def require_permissions!
        missing = missing_permissions
        return true if missing.empty?

        raise PermissionError,
              "macOS permission missing: #{missing.join(', ')}. " + PERMISSION_HINT
      end

      # [lines, problems] for `doctor` — what the backend can see, and what is
      # stopping it from working.
      def diagnostics
        lines = [
          "screen recording: #{screen_recording_allowed? ? 'granted' : 'MISSING'}",
          "accessibility: #{accessibility_allowed? ? 'granted' : 'MISSING'}"
        ]
        displays.each do |display|
          lines << "display #{display.id}#{display.main ? ' (main)' : ''}: " \
                   "#{display.width}x#{display.height} points, origin #{display.origin_x},#{display.origin_y}"
        end
        problems = missing_permissions.map { |name| "#{name} permission is missing — #{PERMISSION_HINT}" }
        [lines, problems]
      end

      # All active displays, main first. Origins come from the window server (see
      # #desktop_window_rects); a display whose origin cannot be resolved is
      # returned with origin_known=false so callers refuse it instead of clicking
      # at a silently wrong offset.
      def displays
        main_id = API.CGMainDisplayID
        rects = desktop_window_rects
        active_display_ids.map do |id|
          mode = API.CGDisplayCopyDisplayMode(id)
          width = API.CGDisplayModeGetWidth(mode).to_i
          height = API.CGDisplayModeGetHeight(mode).to_i
          pixel_width = API.CGDisplayModeGetPixelWidth(mode).to_i
          pixel_height = API.CGDisplayModeGetPixelHeight(mode).to_i
          API.CFRelease(mode) if mode.to_i != 0

          is_main = API.CGDisplayIsMain(id).to_i != 0
          origin = is_main ? [0, 0, true] : match_origin(rects, width, height)
          Geometry::Display.new(id, origin[0], origin[1], width, height,
                                pixel_width, pixel_height, is_main,
                                API.CGDisplayIsBuiltin(id).to_i != 0, origin[2])
        end
      end

      def active_display_ids
        buf = Fiddle::Pointer.malloc(4 * MAX_DISPLAYS)
        count = Fiddle::Pointer.malloc(4)
        rc = API.CGGetActiveDisplayList(MAX_DISPLAYS, buf, count)
        return [API.CGMainDisplayID] unless rc.to_i.zero?

        n = count[0, 4].unpack1("L").to_i
        return [API.CGMainDisplayID] if n.zero?

        buf[0, 4 * n].unpack("L*")
      end

      # ---- screen capture ----

      # Captures a point-space rect (a whole display by default) to a PNG and
      # returns a Geometry::Capture describing the image handed to the model.
      # With max_width, a downscaled copy is written next to the original and the
      # Capture reports that copy's measured dimensions, so model coordinates
      # always map through the exact image it actually saw. With grid_step, a
      # labelled coordinate grid is blended over the model copy so pixel
      # positions can be read straight off the image.
      def capture(path:, display: nil, rect: nil, max_width: nil, grid_step: nil)
        display ||= Geometry.pick_display(displays, *(@cursor || [0, 0]))
        rect = display.rect if rect.nil?
        x, y, w, h = rect

        unless screen_recording_allowed?
          raise PermissionError,
                "Screen Recording permission is missing. " + PERMISSION_HINT
        end

        region = format("%d,%d,%d,%d", x.round, y.round, w.round, h.round)
        _out, err, status = Open3.capture3(SCREENCAPTURE, "-x", "-R", region, path)
        unless status.success?
          raise PermissionError, "`#{SCREENCAPTURE} -R #{region}` failed: #{err.to_s.strip}"
        end

        model_path = path
        if max_width && png_size(path)[0] > max_width
          model_path = resample_to_width(path, max_width)
        end
        if grid_step
          begin
            model_path = Grid.annotate(model_path, grid_step)
          rescue Grid::GridError => e
            warn "grid overlay failed: #{e.message} — using the plain screenshot"
          end
        end
        image_width, image_height = png_size(model_path)
        Geometry::Capture.new(
          origin_x: x, origin_y: y, points_width: w, points_height: h,
          path: path, model_path: model_path,
          image_width: image_width, image_height: image_height
        )
      end

      # ---- input injection ----

      def move(x, y, duration: nil)
        require_accessibility!
        x = x.to_f
        y = y.to_f
        if duration.to_f > 0 && @cursor
          from_x, from_y = @cursor
          steps = [[(duration * 60).ceil, 2].max, 90].min
          steps.times do |i|
            t = (i + 1).to_f / steps
            post_event(mouse_event(MOUSE_MOVED, from_x + (x - from_x) * t,
                                                  from_y + (y - from_y) * t, 0))
            sleep(duration.to_f / steps)
          end
        else
          API.CGWarpMouseCursorPosition(x, y)
          post_event(mouse_event(MOUSE_MOVED, x, y, 0))
        end
        @cursor = [x, y]
      end

      def click(x, y, button: "left", count: 1, modifiers: [])
        require_accessibility!
        spec = button_spec(button)
        flags = Keycodes.flags_for(modifiers)
        count.to_i.times do |i|
          post_button_event(spec, :down, x, y, i + 1, flags)
          post_button_event(spec, :up, x, y, i + 1, flags)
          sleep(CLICK_INTERVAL) if i < count - 1
        end
        @cursor = [x.to_f, y.to_f]
      end

      def mouse_down(x, y, button: "left")
        require_accessibility!
        spec = button_spec(button)
        post_button_event(spec, :down, x, y, 1, 0)
        @cursor = [x.to_f, y.to_f]
      end

      def mouse_up(x, y, button: "left")
        require_accessibility!
        spec = button_spec(button)
        post_button_event(spec, :up, x, y, 1, 0)
        @cursor = [x.to_f, y.to_f]
      end

      def drag(from_x, from_y, to_x, to_y, button: "left", duration: 0.3)
        require_accessibility!
        spec = button_spec(button)
        from_x = from_x.to_f
        from_y = from_y.to_f
        to_x = to_x.to_f
        to_y = to_y.to_f
        post_button_event(spec, :down, from_x, from_y, 1, 0)
        steps = DRAG_STEPS
        steps.times do |i|
          t = (i + 1).to_f / steps
          event = API.CGEventCreateMouseEvent(
            nil, spec[:dragged],
            from_x + (to_x - from_x) * t, from_y + (to_y - from_y) * t, spec[:button]
          )
          API.CGEventSetIntegerValueField(event, CLICK_STATE_FIELD, 1)
          post_event(event)
          sleep(duration.to_f / steps)
        end
        post_button_event(spec, :up, to_x, to_y, 1, 0)
        @cursor = [to_x, to_y]
      end

      def scroll(x, y, dx, dy)
        require_accessibility!
        move(x, y)
        post_scroll(dx.to_i, dy.to_i)
      end

      def type(text)
        require_accessibility!
        chunk = +""
        text.to_s.each_char do |char|
          chunk << char
          next if chunk.length < UNICODE_CHUNK_CHARS

          post_unicode_chunk(chunk)
          chunk = +""
        end
        post_unicode_chunk(chunk) unless chunk.empty?
        true
      end

      def key(combo, repeat: 1)
        require_accessibility!
        modifiers, name = Keycodes.parse(combo)
        code = Keycodes.code_for(name)
        raise ArgumentError, "unknown key #{name.inspect} in #{combo.inspect}" if code.nil?

        flags = Keycodes.flags_for(modifiers)
        repeat.to_i.times do
          down = API.CGEventCreateKeyboardEvent(nil, code, 1)
          up = API.CGEventCreateKeyboardEvent(nil, code, 0)
          API.CGEventSetFlags(down, flags) if flags > 0
          API.CGEventSetFlags(up, flags) if flags > 0
          post_event(down)
          post_event(up)
          sleep(KEY_INTERVAL)
        end
        true
      end

      def hold_key(combo, duration: 1.0)
        require_accessibility!
        modifiers, key = Keycodes.parse(combo)
        # `hold "shift"` names a lone modifier; parse reads a single part as the
        # key, so fold it back into the modifier list.
        modifiers = [key] if modifiers.empty? && Keycodes.modifier?(key)
        codes = modifiers.map { |m| Keycodes.modifier_keycode(m) }.compact
        raise ArgumentError, "no modifier keys in #{combo.inspect}" if codes.empty?

        codes.each { |c| post_event(API.CGEventCreateKeyboardEvent(nil, c, 1)) }
        sleep(duration.to_f)
        codes.each { |c| post_event(API.CGEventCreateKeyboardEvent(nil, c, 0)) }
        true
      end

      CF_NUMBER_CGFLOAT = 16

      # Windows that can only be desktop backdrops: display-sized and below every
      # normal layer.
      private def desktop_window_rects
        window_entries.select { |e| e[:width].to_i > 0 && e[:layer].to_i < 0 }
      end

      # The desktop backdrop is display-sized with a very low window number (it is
      # created early in the session). Dock and overlay windows are also
      # display-sized but carry much higher numbers, so the lowest number wins.
      private def match_origin(rects, width, height)
        candidate = rects.select { |r| r[:width] == width && r[:height] == height }
                         .min_by { |r| r[:number].to_i }
        candidate ? [candidate[:x], candidate[:y], true] : [0, 0, false]
      end

      private def window_entries
        list = API.CGWindowListCopyWindowInfo(WINDOW_LIST_ON_SCREEN_ONLY, NULL_WINDOW_ID)
        return [] if list.nil? || list.to_i.zero?

        bounds_key = cf_key("kCGWindowBounds")
        number_key = cf_key("kCGWindowNumber")
        layer_key = cf_key("kCGWindowLayer")
        owner_key = cf_key("kCGWindowOwnerName")
        keys = axis_keys
        entries = (0...API.CFArrayGetCount(list).to_i).map do |i|
          dict = API.CFArrayGetValueAtIndex(list, i)
          bounds = API.CFDictionaryGetValue(dict, bounds_key)
          box = keys.map { |key| cf_number(API.CFDictionaryGetValue(bounds, key)) }
          {
            x: (box[0] || 0).round,
            y: (box[1] || 0).round,
            width: (box[2] || 0).round,
            height: (box[3] || 0).round,
            number: cf_number(API.CFDictionaryGetValue(dict, number_key)).to_i,
            layer: cf_number(API.CFDictionaryGetValue(dict, layer_key)).to_i,
            owner: cf_string_value(API.CFDictionaryGetValue(dict, owner_key))
          }
        end
        API.CFRelease(list)
        entries
      end

      # The app that owns the topmost normal window, per the window server's
      # front-to-back ordering. This is the name `open -a` matches.
      def frontmost_window_owner
        entry = window_entries.find { |e| e[:layer].to_i.zero? && e[:width].to_i.positive? }
        entry && entry[:owner]
      end

      # Brings an application to the front via LaunchServices — no Apple Events
      # automation grant is needed, unlike `osascript ... activate`. Returns
      # [opened, frontmost_owner]: open -a succeeds even when the app is already
      # running, and localized app names may differ from the bundle name.
      def activate(app_name, wait: 2.0)
        _out, err, status = Open3.capture3("/usr/bin/open", "-a", app_name.to_s)
        return [false, err.to_s.strip] unless status.success?

        deadline = Time.now.to_f + wait.to_f
        loop do
          front = frontmost_window_owner
          return [true, front] if front.to_s.casecmp?(app_name.to_s)

          break if Time.now.to_f >= deadline

          sleep(0.1)
        end
        [true, frontmost_window_owner]
      end

      private def axis_keys
        @axis_keys ||= %w[X Y Width Height].map { |name| cf_string(name) }
      end

      private def cf_string(str)
        buf = Fiddle::Pointer.malloc(str.bytesize + 1)
        buf[0, str.bytesize] = str
        API.CFStringCreateWithCString(nil, buf, UTF8).to_i
      end

      # Data symbols such as kCGWindowBounds hold a CFStringRef, hence the extra
      # dereference.
      private def cf_key(name)
        Fiddle::Pointer.new(cg_handle[name])[0, 8].unpack1("Q")
      end

      private def cg_handle
        @handle ||= Fiddle::Handle.new(APP_SERVICES)
      end

      private def cf_number(ref)
        return nil if ref.nil? || ref.to_i.zero?
        return nil unless API.CFGetTypeID(ref).to_i == API.CFNumberGetTypeID.to_i

        out = Fiddle::Pointer.malloc(8)
        API.CFNumberGetValue(ref, CF_NUMBER_CGFLOAT, out)
        out[0, 8].unpack1("D")
      end

      # Window-list values may be CFNumber or CFString; kCGWindowOwnerName is a
      # CFString, everything numeric arrives as CFNumber.
      private def cf_string_value(ref)
        return nil if ref.nil? || ref.to_i.zero?
        return nil unless API.CFGetTypeID(ref).to_i == API.CFStringGetTypeID.to_i

        size = 256
        buf = Fiddle::Pointer.malloc(size)
        API.CFStringGetCString(ref, buf, size, UTF8).zero? ? nil : buf.to_s
      end

      private def require_accessibility!
        return if accessibility_allowed?

        raise PermissionError,
              "Accessibility permission is missing. " + PERMISSION_HINT
      end

      private def button_spec(button)
        MOUSE_EVENT_TYPES.fetch(button.to_s) do
          raise ArgumentError, "unknown button #{button.inspect} (left/right/middle)"
        end
      end

      private def mouse_event(type, x, y, button)
        API.CGEventCreateMouseEvent(nil, type, x.to_f, y.to_f, button)
      end

      private def post_button_event(spec, phase, x, y, click_state, flags)
        event = mouse_event(spec[phase], x, y, spec[:button])
        return if event.nil? || event.to_i.zero?

        API.CGEventSetIntegerValueField(event, CLICK_STATE_FIELD, click_state)
        API.CGEventSetFlags(event, flags) if flags > 0
        post_event(event)
      end

      private def post_event(event)
        API.CGEventPost(HID_EVENT_TAP, event) unless event.nil? || event.to_i.zero?
      end

      # wheel1 = vertical delta (positive scrolls up), wheel2 = horizontal
      # (positive scrolls right). Pixels are the unit. Zero-delta events are the
      # Accessibility prompt trigger (see #request_accessibility!), so this must
      # never early-return and must never require permissions.
      private def post_scroll(dx, dy)
        event = API.CGEventCreateScrollWheelEvent2(nil, SCROLL_UNIT_PIXEL, 2,
                                                   dy.to_i, dx.to_i, 0)
        post_event(event)
      end

      private def post_unicode_chunk(text)
        data = text.encode("UTF-16LE").bytes
        buf = Fiddle::Pointer.malloc(data.size)
        buf[0, data.size] = data.pack("C*")
        down = API.CGEventCreateKeyboardEvent(nil, 0, 1)
        up = API.CGEventCreateKeyboardEvent(nil, 0, 0)
        API.CGEventKeyboardSetUnicodeString(down, data.size / 2, buf)
        API.CGEventKeyboardSetUnicodeString(up, data.size / 2, buf)
        post_event(down)
        post_event(up)
        sleep(0.01)
      end

      # PNG IHDR: width/height are big-endian uint32 at byte offsets 16/20.
      private def png_size(path)
        header = File.binread(path, 24)
        [header[16, 4].unpack1("N"), header[20, 4].unpack1("N")]
      end

      private def resample_to_width(path, width)
        out_path = path.sub(/\.png\z/i, "") + "-#{width}.png"
        ok = system(SIPS, "--resampleWidth", width.to_s, path, "--out", out_path,
                    out: File::NULL, err: File::NULL)
        raise "`#{SIPS} --resampleWidth #{width}` failed" unless ok && File.exist?(out_path)

        out_path
      end
    end
  end
end
