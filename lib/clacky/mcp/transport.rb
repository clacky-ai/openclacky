# frozen_string_literal: true

module Clacky
  module Mcp
    # Abstract transport. Concrete transports must implement:
    #   #start            -> open the channel (spawn process / open connection)
    #   #stop             -> close everything; must be idempotent
    #   #alive?           -> whether the channel is healthy
    #   #send_message(h)  -> serialize and write one JSON-RPC message
    #   #on_message(&b)   -> register callback invoked with each parsed inbound JSON message
    #   #stderr_tail(bytes:) -> recent diagnostic text (may be empty)
    class Transport
      class TransportError < StandardError; end

      def start;             raise NotImplementedError; end
      def stop;              raise NotImplementedError; end
      def alive?;            raise NotImplementedError; end
      def send_message(_);   raise NotImplementedError; end
      def on_message(&_blk); raise NotImplementedError; end
      def stderr_tail(bytes: 4096); ""; end
    end
  end
end
