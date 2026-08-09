# frozen_string_literal: true

require "json"
require "uri"
require "net/http"
require "securerandom"
require "digest"
require "base64"
require "socket"
require "timeout"

module Clacky
  module Mcp
    module OAuth
      class AuthorizationManager
        Response = Struct.new(:status, :headers, :body)
        MAX_RESPONSE_BYTES = 1_048_576

        class Error < StandardError; end

        def self.pkce_challenge(verifier)
          Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
        end

        def initialize(server_name:, config:, store:, requester: nil, callback: nil, clock: nil)
          @server_name = server_name
          @config = config
          @store = store
          @requester = requester || method(:request)
          @callback = callback
          @clock = clock || -> { Time.now.to_i }
        end

        def login(resource_metadata_url: nil)
          raise Error, "MCP server '#{@server_name}' is not configured for OAuth" unless @config.enabled?

          receiver = @callback || CallbackReceiver.new
          redirect_uri = receiver.respond_to?(:redirect_uri) ? receiver.redirect_uri : "http://127.0.0.1:52963/callback"
          metadata = discover_metadata(resource_metadata_url)
          client = register_client(metadata, redirect_uri)
          verifier = SecureRandom.urlsafe_base64(48, false)
          state = SecureRandom.urlsafe_base64(32, false)
          authorization_url = build_authorization_url(metadata, client.fetch("client_id"), redirect_uri, verifier, state)
          callback_result = receiver.call(authorization_url, state)
          raise Error, "OAuth callback state mismatch" unless callback_result["state"].to_s == state
          raise Error, "OAuth authorization returned no code" if callback_result["code"].to_s.empty?

          token = token_request(metadata.fetch("token_endpoint"), {
            "grant_type" => "authorization_code",
            "code" => callback_result.fetch("code"),
            "redirect_uri" => redirect_uri,
            "client_id" => client.fetch("client_id"),
            "code_verifier" => verifier
          })
          grant = normalize_token(token).merge(
            "client_id" => client.fetch("client_id"),
            "client_secret" => client["client_secret"],
            "token_endpoint_auth_method" => client["token_endpoint_auth_method"] || "none",
            "token_endpoint" => metadata.fetch("token_endpoint"),
            "authorization_server" => metadata.fetch("issuer"),
            "resource" => @config.resource
          )
          @store.save(grant)
        ensure
          receiver.close if defined?(receiver) && receiver.respond_to?(:close)
        end

        def refresh(grant)
          refresh_token = grant["refresh_token"].to_s
          raise Error, "OAuth refresh token is missing; log in again" if refresh_token.empty?

          fields = {
            "grant_type" => "refresh_token",
            "refresh_token" => refresh_token,
            "client_id" => grant.fetch("client_id")
          }
          token = token_request(grant.fetch("token_endpoint"), fields,
                                client_secret: grant["client_secret"],
                                auth_method: grant["token_endpoint_auth_method"])
          updated = grant.merge(normalize_token(token))
          updated["refresh_token"] = refresh_token if token["refresh_token"].to_s.empty?
          updated
        rescue KeyError
          raise Error, "stored OAuth grant is incomplete; log in again"
        end

        private def discover_metadata(explicit_resource_metadata_url)
          protected_url = explicit_resource_metadata_url || default_resource_metadata_url
          protected = get_json(protected_url, "protected resource metadata")
          if protected["resource"] && protected["resource"] != @config.resource
            raise Error, "OAuth protected resource metadata does not match the configured MCP resource"
          end

          server = Array(protected["authorization_servers"]).first || protected["authorization_server"]
          server = validate_https_url(server, "authorization server")
          metadata_url = "#{server.sub(%r{/\z}, '')}/.well-known/oauth-authorization-server"
          metadata = get_json(metadata_url, "authorization server metadata")
          metadata["issuer"] ||= server
          %w[issuer authorization_endpoint token_endpoint registration_endpoint].each do |key|
            metadata[key] = validate_https_url(metadata[key], key.tr("_", " "))
          end
          unless Array(metadata["code_challenge_methods_supported"]).include?("S256")
            raise Error, "authorization server does not support PKCE S256"
          end
          metadata
        end

        private def default_resource_metadata_url
          resource = URI.parse(@config.resource)
          origin = "#{resource.scheme}://#{resource.host}"
          origin += ":#{resource.port}" unless resource.port == 443
          "#{origin}/.well-known/oauth-protected-resource#{resource.path}"
        end

        private def register_client(metadata, redirect_uri)
          response = @requester.call("POST", metadata.fetch("registration_endpoint"),
                                     { "Content-Type" => "application/json" },
                                     JSON.generate(
                                       "client_name" => "openclacky",
                                       "application_type" => "native",
                                       "redirect_uris" => [redirect_uri],
                                       "grant_types" => %w[authorization_code refresh_token],
                                       "response_types" => ["code"],
                                       "token_endpoint_auth_method" => "none",
                                       "scope" => "openid profile email offline_access"
                                     ))
          client = parse_success_json(response, "OAuth client registration")
          raise Error, "OAuth client registration returned no client_id" if client["client_id"].to_s.empty?
          client
        end

        private def build_authorization_url(metadata, client_id, redirect_uri, verifier, state)
          uri = URI.parse(metadata.fetch("authorization_endpoint"))
          uri.query = URI.encode_www_form(
            "response_type" => "code",
            "client_id" => client_id,
            "redirect_uri" => redirect_uri,
            "scope" => "openid profile email offline_access",
            "code_challenge" => self.class.pkce_challenge(verifier),
            "code_challenge_method" => "S256",
            "state" => state,
            "resource" => @config.resource
          )
          uri.to_s
        end

        private def token_request(url, fields, client_secret: nil, auth_method: nil)
          headers = { "Content-Type" => "application/x-www-form-urlencoded" }
          if client_secret && auth_method == "client_secret_basic"
            credentials = Base64.strict_encode64("#{fields['client_id']}:#{client_secret}")
            headers["Authorization"] = "Basic #{credentials}"
          elsif client_secret
            fields = fields.merge("client_secret" => client_secret)
          end
          response = @requester.call("POST", validate_https_url(url, "token endpoint"), headers,
                                     URI.encode_www_form(fields))
          parse_success_json(response, "OAuth token exchange")
        end

        private def normalize_token(token)
          access_token = token["access_token"].to_s
          raise Error, "OAuth token response contained no access token" if access_token.empty?
          {
            "access_token" => access_token,
            "refresh_token" => token["refresh_token"],
            "token_type" => token["token_type"] || "Bearer",
            "expires_at" => @clock.call + token.fetch("expires_in", 3600).to_i
          }
        end

        private def get_json(url, label)
          response = @requester.call("GET", validate_https_url(url, label), { "Accept" => "application/json" }, nil)
          parse_success_json(response, label)
        end

        private def parse_success_json(response, label)
          status = response.status.to_i
          raise Error, "#{label} failed with HTTP #{status}" unless status >= 200 && status < 300
          body = response.body.to_s
          raise Error, "#{label} response was too large" if body.bytesize > MAX_RESPONSE_BYTES
          value = JSON.parse(body)
          raise JSON::ParserError unless value.is_a?(Hash)
          value
        rescue JSON::ParserError
          raise Error, "#{label} returned invalid JSON"
        end

        private def validate_https_url(value, label)
          uri = URI.parse(value.to_s)
          unless uri.scheme == "https" && uri.host && !uri.host.empty? && !uri.user && !uri.password
            raise Error, "#{label} must be an HTTPS URL without credentials"
          end
          uri.to_s
        rescue URI::InvalidURIError
          raise Error, "#{label} must be an HTTPS URL"
        end

        private def request(method, url, headers, body)
          uri = URI.parse(url)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = 10
          http.read_timeout = 30
          request_class = method == "GET" ? Net::HTTP::Get : Net::HTTP::Post
          request = request_class.new(uri.request_uri)
          headers.each { |key, value| request[key] = value }
          request.body = body if body
          response = http.request(request)
          Response.new(response.code.to_i, response.each_header.to_h, response.body.to_s)
        rescue StandardError => e
          raise Error, "OAuth network request failed (#{e.class})"
        end

        class CallbackReceiver
          attr_reader :redirect_uri

          def initialize(timeout: 300)
            @server = TCPServer.new("127.0.0.1", 0)
            @timeout = timeout
            @redirect_uri = "http://127.0.0.1:#{@server.addr[1]}/callback"
          end

          def call(authorization_url, _expected_state)
            open_browser(authorization_url)
            socket = Timeout.timeout(@timeout) { @server.accept }
            request_line = socket.gets.to_s
            path = request_line.split(" ")[1].to_s
            query = URI.decode_www_form(URI.parse(path).query.to_s).to_h
            socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nOpenClacky authorization complete. You may close this tab.\n")
            query
          rescue Timeout::Error
            raise Error, "OAuth authorization timed out"
          ensure
            socket.close if defined?(socket) && socket
          end

          def close
            @server.close unless @server.closed?
          end

          private def open_browser(url)
            command = if RUBY_PLATFORM.include?("darwin")
                        ["open", url]
                      elsif RUBY_PLATFORM =~ /mswin|mingw|cygwin/
                        ["cmd", "/c", "start", "", url]
                      else
                        ["xdg-open", url]
                      end
            opened = system(*command, out: File::NULL, err: File::NULL)
            raise Error, "could not open a browser for OAuth authorization" unless opened
          end
        end
      end
    end
  end
end
