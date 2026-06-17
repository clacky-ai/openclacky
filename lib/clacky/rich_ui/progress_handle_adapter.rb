# frozen_string_literal: true

module Clacky
  module RichUI
    class ProgressHandleAdapter
      def initialize(handle)
        @handle = handle
      end

      def update(message: nil, metadata: nil)
        _ = metadata
        @handle.update(message.to_s) if message
      end

      def finish(final_message: nil)
        final_message ? @handle.finish(final_message.to_s) : @handle.finish
      end

      def cancel
        @handle.cancel
      end
    end
  end
end
