# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "fileutils"
require_relative "locales/i18n"

module Clacky
  # PlatformHttpClient provides a resilient HTTP client for all calls to the
  # OpenClacky platform API (www.openclacky.com and its fallback domain).
  #
  # Features:
  #   - Automatic retry with exponential back-off on transient failures
  #   - Transparent domain failover: if the primary domain times out or returns a
  #     5xx error, the request is automatically retried against the fallback domain
  #   - Unified large-file download entry point (#download_file) that reuses the
  #     same primary → fallback failover policy as API calls
  #   - Override via CLACKY_LICENSE_SERVER env var (auto-detected, used in development)
  #
  # Usage:
  #   client = Clacky::PlatformHttpClient.new
  #   result = client.post("/api/v1/licenses/activate", payload)
  #   # result => { success: true, data: {...} }
  #   #        or { success: false, error: "...", data: {} }
  class PlatformHttpClient
    # Primary endpoint
    PRIMARY_HOST   = "https://www.openclacky.com"
    # Secondary CDN-accelerated endpoint (China mainland)
    SECONDARY_HOST = "https://api.1024code.com"
    # Direct fallback — bypasses EdgeOne, used when the primary times out
    FALLBACK_HOST  = "https://openclacky.up.railway.app"

    # Number of attempts per domain (1 = no retry within the same domain)
    ATTEMPTS_PER_HOST = 1
    # Initial back-off between retries within the same domain (seconds)
    INITIAL_BACKOFF   = 0.5
    # Connection / read timeouts (seconds) for API calls
    OPEN_TIMEOUT  = 5
    READ_TIMEOUT  = 15
    # Read timeout for streaming large file downloads (seconds)
    DOWNLOAD_READ_TIMEOUT = 120
    # Max HTTP redirects followed by #download_file per host attempt
    DOWNLOAD_MAX_REDIRECTS = 10

    # API error code → human-readable message table (shared across all callers)
    # Server error codes that have a localized message under the
    # "platform.error.<code>" i18n key (see locales/en.rb & zh.rb).
    KNOWN_ERROR_CODES = %w[
      invalid_proof invalid_signature nonce_replayed timestamp_expired
      license_revoked license_expired device_limit_reached device_revoked
      invalid_license device_not_found contributor_required missing_device_token
      invalid_device_token device_token_revoked device_token_expired owner_user_not_found
    ].freeze

    # Auto-detects the target host(s):
    #   - When CLACKY_LICENSE_SERVER is set → single host (dev override, no failover)
    #   - Otherwise                   → [PRIMARY_HOST, SECONDARY_HOST, FALLBACK_HOST]
    def initialize
      if (override = ENV["CLACKY_LICENSE_SERVER"]) && !override.empty?
        @hosts = [override]
      else
        @hosts = [PRIMARY_HOST, SECONDARY_HOST, FALLBACK_HOST]
      end
    end

    # Send a POST request with a JSON body and return a normalised result hash.
    #
    # @param path    [String]  API path, e.g. "/api/v1/licenses/activate"
    # @param payload [Hash]    Request body (will be JSON-encoded)
    # @param headers [Hash]    Additional HTTP headers (optional)
    # @return [Hash]  { success: Boolean, data: Hash, error: String }
    def post(path, payload, headers: {})
      request_with_failover(:post, path, payload, headers)
    end

    # Send a GET request and return a normalised result hash.
    # Query string parameters should be appended to path by the caller.
    #
    # @param path    [String]  API path with optional query string
    # @param headers [Hash]    Additional HTTP headers (optional)
    # @return [Hash]  { success: Boolean, data: Hash, error: String }
    def get(path, headers: {})
      request_with_failover(:get, path, nil, headers)
    end

    # Send a PATCH request.  Same contract as #post.
    def patch(path, payload, headers: {})
      request_with_failover(:patch, path, payload, headers)
    end

    # Send a DELETE request (no body).
    def delete(path, headers: {})
      request_with_failover(:delete, path, nil, headers)
    end

    # Send a multipart/form-data POST.
    #
    # @param path       [String]  API path
    # @param body_bytes [String]  Pre-built binary multipart body
    # @param boundary   [String]  Multipart boundary string (without leading --)
    # @param read_timeout [Integer]  Override read timeout (uploads may be slow)
    # @return [Hash]  { success: Boolean, data: Hash, error: String }
    def multipart_post(path, body_bytes, boundary, read_timeout: READ_TIMEOUT)
      headers = { "Content-Type" => "multipart/form-data; boundary=#{boundary}" }
      request_with_failover(:multipart_post, path, body_bytes, headers,
                            read_timeout_override: read_timeout)
    end

    # Send a multipart/form-data PATCH.  Same contract as #multipart_post.
    def multipart_patch(path, body_bytes, boundary, read_timeout: READ_TIMEOUT)
      headers = { "Content-Type" => "multipart/form-data; boundary=#{boundary}" }
      request_with_failover(:multipart_patch, path, body_bytes, headers,
                            read_timeout_override: read_timeout)
    end

    # Stream a remote URL to a local file path, with automatic primary → fallback
    # host failover.
    #
    # This is the unified entry point for all large-file downloads (brand skill
    # ZIPs, platform-hosted assets, etc.). Callers should NOT build their own
    # Net::HTTP loops — failover, retry, redirects, and timeouts are handled here.
    #
    # Host failover policy:
    #   - If +url+'s host matches PRIMARY_HOST and the request fails with a
    #     retryable error (timeout, connection reset, SSL, 5xx), the URL is
    #     rewritten to FALLBACK_HOST (same path/query) and retried.
    #   - Both hosts serve the same Rails backend and share +secret_key_base+,
    #     so ActiveStorage signed_ids resolve identically on either.
    #   - Third-party hosts (e.g. S3 presigned URLs reached via redirect) are
    #     fetched as-is without host rewriting.
    #
    # Each host gets ATTEMPTS_PER_HOST attempts with exponential back-off.
    # Up to DOWNLOAD_MAX_REDIRECTS redirects are followed per attempt.
    #
    # @param url  [String]   Full URL to download
    # @param dest [String]   Local path to write the response body into.
    #                        The file is written atomically (temp path + rename)
    #                        so a failed download cannot leave a half-written file.
    # @param read_timeout [Integer] Override read timeout (seconds)
    # @return [Hash] { success: Boolean, bytes: Integer, error: String }
    def download_file(url, dest, read_timeout: DOWNLOAD_READ_TIMEOUT)
      candidate_urls = [url]
      # Only auto-add a fallback candidate when the URL is on our primary host.
      # External hosts (S3, CDNs, user-provided URLs) are fetched as-is.
      if primary_host_url?(url)
        candidate_urls << swap_to_fallback_host(url)
      end

      last_error = nil
      FileUtils.mkdir_p(File.dirname(dest))
      tmp_dest = "#{dest}.part"

      candidate_urls.each_with_index do |candidate, host_index|
        ATTEMPTS_PER_HOST.times do |attempt|
          begin
            bytes = stream_download(candidate, tmp_dest, read_timeout: read_timeout)
            File.rename(tmp_dest, dest)
            return { success: true, bytes: bytes, error: nil }
          rescue RetryableNetworkError => e
            last_error = e
            backoff    = INITIAL_BACKOFF * (2**attempt)
            Clacky::Logger.debug(
              "[PlatformHTTP] DOWNLOAD #{candidate} attempt #{attempt + 1} failed: " \
              "#{e.message} — retrying in #{backoff}s"
            )
            sleep(backoff)
          end
        end

        if host_index + 1 < candidate_urls.size
          Clacky::Logger.debug(
            "[PlatformHTTP] Primary host exhausted for download, switching to fallback: " \
            "#{candidate_urls[host_index + 1]}"
          )
        end
      end

      FileUtils.rm_f(tmp_dest)
      { success: false, bytes: 0, error: "Download failed: #{last_error&.message || "unknown"}" }
    end

    # True when +url+ targets the primary platform host.
    # Used by #download_file to decide whether fallback-host rewriting is safe.
    private def primary_host_url?(url)
      return false if url.nil? || url.empty?

      uri = URI.parse(url)
      primary = URI.parse(PRIMARY_HOST)
      uri.host == primary.host
    rescue URI::InvalidURIError
      false
    end

    # Rewrite +url+ so its host is the fallback domain (same path + query).
    # Callers must have already confirmed the URL's host is PRIMARY_HOST via
    # #primary_host_url? — this method does not validate that precondition.
    private def swap_to_fallback_host(url)
      uri      = URI.parse(url)
      fallback = URI.parse(FALLBACK_HOST)
      uri.scheme = fallback.scheme
      uri.host   = fallback.host
      # Only apply an explicit port when fallback declares a non-default one
      uri.port = fallback.port if fallback.port && fallback.port != fallback.default_port
      uri.to_s
    end

    # Execute a streaming GET with redirect following, writing the response body
    # to +dest+ as it arrives. Raises RetryableNetworkError on any transient
    # failure so the caller can decide whether to retry / failover.
    #
    # @return [Integer] Number of bytes written
    private def stream_download(url, dest, read_timeout:)
      current_url = url
      DOWNLOAD_MAX_REDIRECTS.times do
        uri  = URI.parse(current_url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = read_timeout

        req = Net::HTTP::Get.new(uri.request_uri)

        written = 0
        redirect_to = nil
        http.start do |h|
          h.request(req) do |resp|
            case resp.code.to_i
            when 200
              expected_len = resp["content-length"]&.to_i
              File.open(dest, "wb") do |f|
                resp.read_body do |chunk|
                  f.write(chunk)
                  written += chunk.bytesize
                end
              end
              if expected_len && expected_len > 0 && written != expected_len
                raise RetryableNetworkError,
                      "Truncated download: got #{written} bytes, expected #{expected_len}"
              end
            when 301, 302, 303, 307, 308
              location = resp["location"]
              raise RetryableNetworkError, "Redirect with no Location header" if location.nil? || location.empty?

              redirect_to = location
            else
              # 5xx is retryable, 4xx is terminal — but we don't have separate
              # handling in the existing API path and fallback is still useful
              # for e.g. upstream 502/503, so treat everything non-2xx/3xx as
              # retryable to match the spirit of request_with_failover.
              raise RetryableNetworkError, "HTTP #{resp.code}"
            end
          end
        end

        return written if redirect_to.nil?

        current_url = redirect_to
      end

      raise RetryableNetworkError, "Too many redirects"
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise RetryableNetworkError, "Timeout: #{e.message}"
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
           Errno::ECONNRESET, EOFError => e
      raise RetryableNetworkError, "Connection error: #{e.message}"
    rescue OpenSSL::SSL::SSLError => e
      raise RetryableNetworkError, "SSL error: #{e.message}"
    rescue RetryableNetworkError
      raise
    rescue StandardError => e
      raise RetryableNetworkError, e.message
    end

    private def request_with_failover(method, path, payload, extra_headers, read_timeout_override: nil)
      last_error = nil

      @hosts.each_with_index do |base, host_index|
        ATTEMPTS_PER_HOST.times do |attempt|
          begin
            return execute_request(method, base, path, payload, extra_headers,
                                   read_timeout_override: read_timeout_override)
          rescue RetryableNetworkError => e
            last_error = e
            backoff    = INITIAL_BACKOFF * (2**attempt)
            Clacky::Logger.debug(
              "[PlatformHTTP] #{method.upcase} #{base}#{path} attempt #{attempt + 1} failed: " \
              "#{e.message} — retrying in #{backoff}s"
            )
            sleep(backoff)
          end
        end

        if host_index + 1 < @hosts.size
          Clacky::Logger.debug(
            "[PlatformHTTP] Primary host exhausted, switching to fallback: #{@hosts[host_index + 1]}"
          )
        end
      end

      # All hosts / attempts exhausted
      { success: false, error: "Network error: #{last_error&.message || "unknown"}", data: {} }
    end

    private def execute_request(method, base, path, payload, extra_headers, read_timeout_override: nil)
      uri  = URI.parse("#{base}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = read_timeout_override || READ_TIMEOUT

      req = build_request(method, uri, payload, extra_headers)

      response = http.request(req)
      parse_response(response)
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise RetryableNetworkError, "Timeout: #{e.message}"
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
           Errno::ECONNRESET, EOFError => e
      raise RetryableNetworkError, "Connection error: #{e.message}"
    rescue OpenSSL::SSL::SSLError => e
      raise RetryableNetworkError, "SSL error: #{e.message}"
    rescue StandardError => e
      raise RetryableNetworkError, e.message
    end

    private def build_request(method, uri, payload, extra_headers)
      # Multipart methods use body_stream to preserve binary null bytes.
      # payload is already the pre-built binary body_bytes string.
      if method == :multipart_post || method == :multipart_patch
        klass = method == :multipart_post ? Net::HTTP::Post : Net::HTTP::Patch
        req   = klass.new(uri.path)
        extra_headers.each { |k, v| req[k] = v }
        req["Content-Length"] = payload.bytesize.to_s
        req.body_stream = StringIO.new(payload)
        return req
      end

      klass = {
        post:   Net::HTTP::Post,
        patch:  Net::HTTP::Patch,
        delete: Net::HTTP::Delete,
        get:    Net::HTTP::Get
      }.fetch(method)

      req = klass.new(uri.request_uri)
      req["Content-Type"] = "application/json"
      extra_headers.each { |k, v| req[k] = v }
      req.body = JSON.generate(payload) if payload
      req
    end

    private def parse_response(response)
      body = JSON.parse(response.body) rescue {}
      code = response.code.to_i

      if code == 200 || code == 201
        { success: true, data: body["data"] || body }
      else
        error_code = body["code"]
        server_msg = extract_server_error_message(body)
        error_msg  = if KNOWN_ERROR_CODES.include?(error_code)
                       Clacky::I18n.t("platform.error.#{error_code}")
                     elsif server_msg
                       server_msg
                     elsif error_code
                       Clacky::I18n.t("platform.error.generic_with_code", code: code, error_code: error_code)
                     else
                       Clacky::I18n.t("platform.error.generic", code: code)
                     end
        { success: false, error: error_msg, data: body }
      end
    end

    # Server error messages can come back under different keys / shapes:
    #   { "error":  "msg" }           — single string
    #   { "errors": ["msg1", "msg2"] } — array of strings (Rails .errors.full_messages)
    #   { "errors": "msg" }            — string (less common)
    #   { "message": "msg" }           — alternative key
    # Returns the first non-blank human-readable string, or nil if none.
    private def extract_server_error_message(body)
      return nil unless body.is_a?(Hash)

      [body["error"], body["errors"], body["message"]].each do |val|
        case val
        when String
          return val unless val.strip.empty?
        when Array
          joined = val.compact.map(&:to_s).reject(&:empty?).join("; ")
          return joined unless joined.empty?
        end
      end
      nil
    end

    # Raised for transient failures that should be retried (timeouts, conn resets, SSL errors).
    class RetryableNetworkError < StandardError; end
  end
end
