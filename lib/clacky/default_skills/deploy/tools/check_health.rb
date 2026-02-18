# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module Clacky
  module DeployTools
    # Perform HTTP health check on deployed application
    class CheckHealth
      DEFAULT_PATH = '/'
      DEFAULT_TIMEOUT = 30
      MAX_TIMEOUT = 120

      # Perform health check
      #
      # @param url [String] Optional URL (defaults to RAILWAY_PUBLIC_DOMAIN env var)
      # @param path [String] Health check path (default: "/")
      # @param timeout [Integer] Request timeout in seconds (default: 30)
      # @return [Hash] Result of health check
      def self.execute(url: nil, path: DEFAULT_PATH, timeout: DEFAULT_TIMEOUT)
        # Get URL from parameter or environment
        target_url = url || ENV['RAILWAY_PUBLIC_DOMAIN']
        
        if target_url.nil? || target_url.empty?
          return {
            error: "No URL provided",
            details: "Please provide a URL or set RAILWAY_PUBLIC_DOMAIN environment variable"
          }
        end

        # Ensure URL has protocol
        target_url = "https://#{target_url}" unless target_url.start_with?('http://', 'https://')

        # Build full URL with path
        full_url = "#{target_url.chomp('/')}#{path}"

        # Validate timeout
        timeout = timeout.to_i
        if timeout <= 0 || timeout > MAX_TIMEOUT
          timeout = DEFAULT_TIMEOUT
        end

        puts "🏥 Checking health: #{full_url} (timeout: #{timeout}s)"

        begin
          uri = URI.parse(full_url)
          result = perform_request(uri, timeout)
          
          if result[:success]
            puts "✅ Health check passed: #{result[:status_code]}"
          else
            puts "❌ Health check failed: #{result[:error]}"
          end
          
          result.merge(url: full_url, path: path)
        rescue URI::InvalidURIError => e
          {
            success: false,
            error: "Invalid URL",
            details: e.message,
            url: full_url
          }
        end
      end

      # Perform HTTP request
      #
      # @param uri [URI] Target URI
      # @param timeout [Integer] Timeout in seconds
      # @return [Hash] Request result
      def self.perform_request(uri, timeout)
        start_time = Time.now
        
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        http.open_timeout = timeout
        http.read_timeout = timeout
        
        request = Net::HTTP::Get.new(uri.request_uri)
        request['User-Agent'] = 'Clacky-Deploy-Health-Check/1.0'
        
        response = http.request(request)
        elapsed = Time.now - start_time

        {
          success: response.is_a?(Net::HTTPSuccess),
          status_code: response.code.to_i,
          status_message: response.message,
          elapsed: elapsed.round(2),
          headers: response.to_hash,
          body_preview: response.body&.slice(0, 500) # First 500 chars
        }
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        {
          success: false,
          error: "Request timeout",
          details: e.message,
          elapsed: timeout
        }
      rescue SocketError => e
        {
          success: false,
          error: "Network error",
          details: e.message
        }
      rescue StandardError => e
        {
          success: false,
          error: "Health check failed",
          details: "#{e.class}: #{e.message}"
        }
      end
    end
  end
end
