# frozen_string_literal: true

require "json"
require "timeout"
require "uri"

module Clacky
  module Server
    # Routes /api/ext/<name>/<sub-path> requests to the matching ApiExtension
    # subclass. Wraps each handler invocation with a timeout and a unified
    # JSON error envelope so a misbehaving extension cannot break neighboring
    # extensions or the host process.
    module ApiExtensionDispatcher
      MOUNT_PREFIX = "/api/ext/"

      class << self
        # Public entry called from HttpServer#_dispatch_rest.
        # Returns true to indicate the request was handled (200/4xx/5xx).
        def handle(req, res, http_server:)
          ext_id, sub_path = parse_path(req.path)
          return not_found(res, "extension id missing") unless ext_id

          klass = Clacky::ApiExtension.registry[ext_id]
          return not_found(res, "extension '#{ext_id}' not found") unless klass

          method = req.request_method.to_s.downcase.to_sym
          route, params = find_route(klass, method, sub_path)
          return not_found(res, "no route for #{req.request_method} #{req.path}") unless route

          # Public-endpoint check is done at HttpServer level (it owns access-key
          # logic); by the time we get here, auth has already been resolved.

          timeout_sec = route.options[:timeout] || klass.class_timeout || Clacky::ApiExtension::DEFAULT_TIMEOUT
          invoke_route(klass, route, params, req, res, http_server, timeout_sec)
          true
        end

        # Tells HttpServer whether a given /api/ext/... path can skip access-key
        # auth, so the host can keep its single-source-of-truth auth logic.
        def public_path?(path, method)
          ext_id, sub_path = parse_path(path)
          return false unless ext_id

          klass = Clacky::ApiExtension.registry[ext_id]
          return false unless klass
          return false if klass.public_paths.empty?

          route, _params = find_route(klass, method.to_s.downcase.to_sym, sub_path)
          return false unless route

          klass.public_paths.include?(route.pattern)
        end

        private def parse_path(path)
          return [nil, nil] unless path.to_s.start_with?(MOUNT_PREFIX)

          tail = path[MOUNT_PREFIX.length..]
          slash = tail.index("/")
          if slash
            [tail[0...slash], tail[slash..]]
          else
            [tail, "/"]
          end
        end

        private def find_route(klass, method, sub_path)
          klass.routes.each do |route|
            next unless route.method == method
            next unless (m = route.regex.match(sub_path))

            params = {}
            route.param_names.each_with_index do |name, i|
              params[name] = URI.decode_www_form_component(m[i + 1].to_s)
            end
            return [route, params]
          end
          [nil, nil]
        end

        private def invoke_route(klass, route, params, req, res, http_server, timeout_sec)
          instance = klass.new(req: req, res: res, route: route, params: params, http_server: http_server)
          Timeout.timeout(timeout_sec) { instance.invoke }

          # Handler exited without writing — empty 204
          empty_response(res)
        rescue Clacky::ApiExtension::Halt => halt
          write_response(res, halt.status, halt.payload, halt.content_type)
        rescue Timeout::Error
          Clacky::Logger.warn("[api_ext:#{klass.ext_id}] Timed out after #{timeout_sec}s on #{route.method.upcase} #{route.pattern}")
          write_json(res, 503, error: "request timed out")
        rescue StandardError => e
          Clacky::Logger.warn("[api_ext:#{klass.ext_id}] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
          write_json(res, 500, error: e.message)
        end

        private def write_response(res, status, body, content_type)
          res.status = status
          res.content_type = content_type
          res["Access-Control-Allow-Origin"] = "*"
          res.body = body
        end

        private def write_json(res, status, payload)
          write_response(res, status, JSON.generate(payload), "application/json; charset=utf-8")
        end

        private def empty_response(res)
          res.status = 204
          res["Access-Control-Allow-Origin"] = "*"
          res.body = ""
        end

        private def not_found(res, message)
          write_json(res, 404, error: message)
          true
        end
      end
    end
  end
end
