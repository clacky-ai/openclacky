# frozen_string_literal: true

require "json"
require "uri"
require "net/http"
require "time"

module Clacky
  module Channel
    module Adapters
      module Qq
        # Thin HTTPS client for the QQ Official Bot API (api.sgroup.qq.com / api.bot.qq.com).
        #
        # Responsibilities:
        #   * obtain & cache the bot access_token from /app/getAppAccessToken
        #   * attach it as `Authorization: QQBot <token>` on every call
        #   * translate non-zero business codes / HTTP failures into ApiError
        #
        # Docs: https://bot.q.qq.com/wiki/develop/api-v2/
        class ApiClient
          # Base URL for the QQ Open Platform v2 API.
          DEFAULT_BASE_URL = "https://api.sgroup.qq.com"
          TOKEN_URL        = "https://api.bot.qq.com/app/getAppAccessToken"
          GATEWAY_PATH     = "/gateway"

          attr_reader :base_url

          # Refresh a little early so a token never expires mid-request.
          TOKEN_SKEW_S = 120

          # Raised when an API request fails (HTTP error or a QQ error code).
          class ApiError < StandardError
            attr_reader :code, :http_status

            def initialize(message, code: nil, http_status: nil)
              super(message)
              @code        = code
              @http_status = http_status
            end
          end

          def initialize(app_id:, app_secret:, base_url: nil, open_timeout: 10, read_timeout: 30)
            @app_id       = app_id.to_s
            @app_secret   = app_secret.to_s
            @base_url = if base_url.nil? || base_url.to_s.strip.empty?
                          DEFAULT_BASE_URL
                        else
                          base_url.to_s.sub(%r{/+\z}, "")
                        end
            @open_timeout = open_timeout
            @read_timeout = read_timeout

            @token     = nil
            @token_exp = nil
          end

          # Returns the WebSocket gateway URL.
          def gateway_url
            resp = get(GATEWAY_PATH)
            url = resp["url"]
            raise ApiError, "getGateway returned no url" if url.nil? || url.to_s.strip.empty?

            url.to_s
          end

          # Bootstrap data needed by the WebSocket client: gateway URL + raw token.
          # @return [Hash] { url:, token: }
          def connection_info
            token = access_token
            { url: gateway_url, token: token }
          end

          # Public so the gateway client can refresh an expired token on reconnect
          # (QQ bot access tokens are valid for ~2h).
          def access_token
            fetch_access_token
          end

          # POST /v2/groups/{group_openid}/messages
          def send_group_message(group_openid, body)
            post("/v2/groups/#{URI.encode_www_form_component(group_openid)}/messages", body)
          end

          # POST /v2/users/{user_openid}/messages
          def send_c2c_message(user_openid, body)
            post("/v2/users/#{URI.encode_www_form_component(user_openid)}/messages", body)
          end

          # POST /v2/users/{user_openid}/upload_prepare
          def upload_c2c_prepare(user_openid, body)
            post("/v2/users/#{URI.encode_www_form_component(user_openid)}/upload_prepare", body)
          end

          # POST /v2/users/{user_openid}/upload_part_finish
          def upload_c2c_part_finish(user_openid, body)
            post("/v2/users/#{URI.encode_www_form_component(user_openid)}/upload_part_finish", body)
          end

          # POST /v2/users/{user_openid}/files
          def create_c2c_file(user_openid, body)
            post("/v2/users/#{URI.encode_www_form_component(user_openid)}/files", body)
          end

          # POST /v2/groups/{group_openid}/upload_prepare
          def upload_group_prepare(group_openid, body)
            post("/v2/groups/#{URI.encode_www_form_component(group_openid)}/upload_prepare", body)
          end

          # POST /v2/groups/{group_openid}/upload_part_finish
          def upload_group_part_finish(group_openid, body)
            post("/v2/groups/#{URI.encode_www_form_component(group_openid)}/upload_part_finish", body)
          end

          # POST /v2/groups/{group_openid}/files
          def create_group_file(group_openid, body)
            post("/v2/groups/#{URI.encode_www_form_component(group_openid)}/files", body)
          end

          # Raw HTTP PUT used to push a part's bytes to a COS presigned URL.
          def put_raw(url, data, headers = {})
            uri = URI(url)
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = uri.scheme == "https"
            http.open_timeout = @open_timeout
            http.read_timeout = @read_timeout

            req = Net::HTTP::Put.new(uri.request_uri)
            req.body = data
            req["Content-Type"]   = headers["Content-Type"] || "application/octet-stream"
            req["Content-Length"] = data.bytesize.to_s
            headers.each { |k, v| req[k] = v unless k == "Content-Type" }

            res = http.request(req)
            unless res.code.to_i.between?(200, 299)
              raise ApiError.new("PUT failed HTTP #{res.code}: #{res.body.to_s.slice(0, 200)}",
                                 http_status: res.code.to_i)
            end

            Clacky::Logger.debug("[qq] PUT part ok HTTP #{res.code} etag=#{res["ETag"]}")
            { status: res.code.to_i, etag: res["ETag"] }
          end

          def get(path, headers = {})
            request(:get, path, nil, headers)
          end

          def post(path, body, headers = {})
            request(:post, path, body, headers)
          end

          private def request(method, path, body, extra_headers)
            uri = URI.join("#{@base_url}/", path.sub(%r{\A/}, ""))
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = uri.scheme == "https"
            http.open_timeout = @open_timeout
            http.read_timeout = @read_timeout

            req = build_request(method, uri, body, extra_headers)
            res = http.request(req)

            parse_response(res)
          end

          private def build_request(method, uri, body, extra_headers)
            klass = case method
                    when :get then Net::HTTP::Get
                    when :put then Net::HTTP::Put
                    else           Net::HTTP::Post
                    end
            req   = klass.new(uri.request_uri)
            req["Authorization"] = "QQBot #{access_token}" unless token_endpoint?(uri)
            # botpy attaches the bot AppID on every authenticated request.
            req["X-Union-Appid"] = @app_id unless token_endpoint?(uri)
            req["Accept"]        = "application/json"
            req["User-Agent"]    = "openclacky-qq/1.0"
            extra_headers.each { |k, v| req[k] = v }
            if body
              req["Content-Type"] = "application/json"
              req.body = body.is_a?(String) ? body : JSON.generate(body)
            end
            req
          end

          private def token_endpoint?(uri)
            uri.to_s.start_with?(TOKEN_URL)
          end

          private def parse_response(res)
            raw = res.body.to_s
            parsed =
              begin
                raw.empty? ? {} : JSON.parse(raw)
              rescue JSON::ParserError
                raise ApiError.new("non-JSON response (HTTP #{res.code})", http_status: res.code.to_i)
              end

            # Business errors are delivered with HTTP 200 and a numeric `code`.
            if parsed.is_a?(Hash) && parsed.key?("code") && parsed["code"].to_i != 0
              raise ApiError.new(
                parsed["message"].to_s.empty? ? "QQ API code #{parsed["code"]}" : parsed["message"].to_s,
                code: parsed["code"], http_status: res.code.to_i
              )
            end

            unless res.code.to_i.between?(200, 299)
              raise ApiError.new("HTTP #{res.code}: #{raw.slice(0, 300)}", http_status: res.code.to_i)
            end

            parsed
          end

          private def fetch_access_token
            return @token if @token && @token_exp && Time.now < @token_exp

            uri = URI(TOKEN_URL)
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = uri.scheme == "https"
            http.open_timeout = @open_timeout
            http.read_timeout = @read_timeout

            req = Net::HTTP::Post.new(uri.request_uri)
            req["Content-Type"] = "application/json"
            req.body = JSON.generate(appId: @app_id, clientSecret: @app_secret)

            res  = http.request(req)
            data = JSON.parse(res.body.to_s)

            if data["access_token"].nil? || data["access_token"].to_s.empty?
              raise ApiError.new(
                "failed to get access_token (code=#{data["code"]} #{data["message"]})",
                code: data["code"]
              )
            end

            @token     = data["access_token"].to_s
            expires_in = data["expires_in"].to_i
            expires_in = 7200 if expires_in <= 0
            @token_exp = Time.now + (expires_in - TOKEN_SKEW_S)
            @token
          end
        end
      end
    end
  end
end
