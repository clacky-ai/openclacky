# frozen_string_literal: true

module Clacky
  module Computer
    # Pure coordinate math — no OS APIs live here so the logic is testable on
    # any platform.
    #
    # Three coordinate spaces are involved:
    #   points — macOS logical global space. Origin is the top-left corner of the
    #            main display, y grows downwards. This is the space CGEvent uses.
    #   pixels — backing-store pixels. A Retina display has pixel = point * 2.
    #   image  — pixels of the (usually downscaled) PNG handed to the model.
    #
    # The model reports coordinates in *image* space because that is what it can
    # see, so every capture records the transform back to global points.
    # Base class for failures a backend raises and the CLI reports verbatim, so
    # the CLI never has to know which platform it is talking to.
    class BackendError < StandardError; end

    # Raised by backends when the platform's screen or input permission is
    # missing. Lives here — not in a backend — so callers can rescue it on any
    # platform.
    class PermissionError < BackendError; end

    module Geometry
      # One physical display. width/height are points, pixel_* are backing pixels.
      # origin_known is false when the window server could not tell us where the
      # display sits, in which case global coordinates for it cannot be trusted.
      Display = Struct.new(:id, :origin_x, :origin_y, :width, :height,
                           :pixel_width, :pixel_height, :main, :builtin,
                           :origin_known) do
        # Backing scale factor, e.g. 2.0 on Retina.
        def scale
          return 1.0 if width.to_i.zero?

          pixel_width.to_f / width.to_f
        end

        def rect
          [origin_x, origin_y, width, height]
        end

        def contains?(x, y)
          x >= origin_x && x < origin_x + width && y >= origin_y && y < origin_y + height
        end

        def to_h
          {
            id: id,
            main: main ? true : false,
            builtin: builtin ? true : false,
            origin: [origin_x, origin_y],
            origin_known: origin_known ? true : false,
            points: [width, height],
            pixels: [pixel_width, pixel_height],
            scale: scale.round(2)
          }
        end
      end

      # Shrink width/height to fit max_width, preserving the aspect ratio.
      # Never upscales: a small screen stays at its native size.
      def self.fit(width, height, max_width)
        width = width.to_i
        height = height.to_i
        return [width, height] if max_width.to_i <= 0 || width <= max_width.to_i

        ratio = max_width.to_f / width
        [max_width.to_i, [(height * ratio).round, 1].max]
      end

      def self.pick_display(displays, x, y)
        found = displays.find { |d| d.contains?(x.to_f, y.to_f) }
        found || displays.find(&:main) || displays.first
      end

      # A screenshot plus everything needed to translate the coordinates the
      # model sees back into global points. Covers one rectangular region in
      # point space — a whole display, or a zoomed crop of one.
      class Capture
        attr_reader :origin_x, :origin_y, :points_width, :points_height,
                    :path, :model_path, :image_width, :image_height

        def initialize(origin_x:, origin_y:, points_width:, points_height:,
                       path:, model_path:, image_width:, image_height:)
          @origin_x = origin_x
          @origin_y = origin_y
          @points_width = points_width
          @points_height = points_height
          @path = path
          @model_path = model_path || path
          @image_width = image_width
          @image_height = image_height
        end

        # Points of screen covered by one pixel of the image the model sees.
        def points_per_image_pixel_x
          @points_width.to_f / @image_width.to_f
        end

        def points_per_image_pixel_y
          @points_height.to_f / @image_height.to_f
        end

        # Image coordinates (what the model reports) -> global points.
        def image_to_points(x, y)
          [@origin_x + x.to_f * points_per_image_pixel_x,
           @origin_y + y.to_f * points_per_image_pixel_y]
        end

        # Global points -> image coordinates. Used to report the cursor position
        # in the same space the model is looking at.
        def points_to_image(x, y)
          [(x.to_f - @origin_x) / points_per_image_pixel_x,
           (y.to_f - @origin_y) / points_per_image_pixel_y]
        end

        def include?(x, y)
          x.to_f >= 0 && y.to_f >= 0 && x.to_f < @image_width && y.to_f < @image_height
        end

        def to_h
          {
            image: [@image_width, @image_height],
            points: [@points_width, @points_height],
            origin: [@origin_x, @origin_y],
            points_per_image_pixel: [points_per_image_pixel_x.round(4),
                                     points_per_image_pixel_y.round(4)]
          }
        end
      end
    end
  end
end
