# frozen_string_literal: true

require "json"
require "uri"
require "net/http"
require "securerandom"
require "base64"

module Clacky
  module Channel
    module Adapters
      module Qq
        # Official "lite bind" flow — lets a user create/link a QQ bot by
        # scanning a QR code on Tencent's own page, without manually copying an
        # AppID/AppSecret.
        #
        # Protocol (mirrors @tencent-connect/qqbot-connector):
        #   1. generate a random 32-byte AES key (base64)
        #   2. POST /lite/create_bind_task {key} -> task_id
        #   3. open /qqbot/openclaw/connect.html?task_id=... (Tencent shows QR)
        #   4. poll POST /lite/poll_bind_result {task_id}
        #        status 0 none / 1 pending / 2 completed / 3 expired
        #   5. on completed, decrypt bot_encrypt_secret (AES-256-GCM, nonce is
        #      the first 12 bytes, auth tag the last 16) to get the AppSecret
        #
        # These endpoints require no prior login; the AES key stays on the
        # server so only this server can decrypt the returned secret.
        class QrBinder
          NONCE_LEN = 12
          TAG_LEN   = 16

          HOST          = "q.qq.com"
          CREATE_PATH   = "/lite/create_bind_task"
          POLL_PATH     = "/lite/poll_bind_result"
          CONNECT_PATH  = "/qqbot/openclaw/connect.html"
          SOURCE        = "openclacky"

          STATUS_NONE      = 0
          STATUS_PENDING   = 1
          STATUS_COMPLETED = 2
          STATUS_EXPIRED   = 3

          class BindError < StandardError; end

          def initialize(open_timeout: 10, read_timeout: 15)
            @open_timeout = open_timeout
            @read_timeout = read_timeout
          end

          # Create a bind task.
          # @return [Hash] { task_id:, key:, connect_url: }
          def create_task(source: SOURCE)
            key = SecureRandom.random_bytes(32)
            key_b64 = [key].pack("m0")

            resp = post_json(CREATE_PATH, key: key_b64)
            task_id = resp.dig("data", "task_id").to_s
            raise BindError, "create_bind_task: missing task_id" if task_id.empty?

            { task_id: task_id, key: key_b64, connect_url: connect_url(task_id, source) }
          end

          # Poll a bind task. Does not decrypt; use #extract_credentials when
          # the status is completed.
          # @return [Hash] { status:, bot_app_id:, encrypt_secret:, user_openid: }
          def poll(task_id)
            resp = post_json(POLL_PATH, task_id: task_id)
            data = resp["data"] || {}
            {
              status: data["status"].to_i,
              bot_app_id: data["bot_appid"],
              encrypt_secret: data["bot_encrypt_secret"],
              user_openid: data["user_openid"]
            }
          end

          # Decrypt the returned secret and shape normalised credentials.
          # @return [Hash] { app_id:, app_secret:, user_openid: }
          def extract_credentials(bot_app_id:, encrypt_secret:, user_openid: nil, key: nil)
            raise BindError, "missing AES key" if key.nil? || key.to_s.empty?
            raise BindError, "missing encrypted secret" if encrypt_secret.to_s.empty?

            raw      = Base64.decode64(encrypt_secret)
            aes_key  = Base64.decode64(key)
            raise BindError, "payload too short" if raw.bytesize < NONCE_LEN + TAG_LEN
            raise BindError, "invalid bind key" if aes_key.bytesize != 32

            nonce = raw.byteslice(0, NONCE_LEN)
            tag   = raw.byteslice(raw.bytesize - TAG_LEN, TAG_LEN)
            ct    = raw.byteslice(NONCE_LEN, raw.bytesize - NONCE_LEN - TAG_LEN)

            begin
              require_relative "../../../../aes_gcm"
              secret = Clacky::AesGcm.decrypt(aes_key, nonce, ct, tag)
            rescue OpenSSL::Cipher::CipherError => e
              raise BindError, "failed to decrypt AppSecret (#{e.message})"
            end

            { app_id: bot_app_id.to_s, app_secret: secret, user_openid: user_openid.to_s }
          end

          def connect_url(task_id, source = SOURCE)
            query = URI.encode_www_form(task_id: task_id, source: source, _wv: "2")
            "https://#{HOST}#{CONNECT_PATH}?#{query}"
          end

          private def post_json(path, body)
            uri = URI("https://#{HOST}#{path}")
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = true
            http.open_timeout = @open_timeout
            http.read_timeout = @read_timeout

            req = Net::HTTP::Post.new(uri.request_uri)
            req["Content-Type"] = "application/json"
            req["Accept"]       = "application/json"
            req.body = JSON.generate(body)

            res = http.request(req)
            raise BindError, "HTTP #{res.code} from #{path}" unless res.code.to_i.between?(200, 299)

            parsed =
              begin
                JSON.parse(res.body.to_s)
              rescue JSON::ParserError
                raise BindError, "non-JSON response from #{path}"
              end

            unless parsed["retcode"].to_i.zero?
              msg = parsed["msg"].to_s
              raise BindError, msg.empty? ? "request failed" : msg
            end

            parsed
          end
        end
      end
    end
  end
end
