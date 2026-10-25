# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "cgi"
require "base64"
require_relative "../utils/encoding"
require_relative "../deepseek_web_tools"

module Clacky
  module Tools
    class WebSearch < Base
      self.tool_name = "web_search"
      self.tool_description = "Search the web for current information. Returns search results with titles, URLs, and snippets."
      self.tool_category = "web"
      self.tool_parameters = {
        type: "object",
        properties: {
          query: {
            type: "string",
            description: "The search query"
          },
          max_results: {
            type: "integer",
            description: "Maximum number of results to return (default: 10)",
            default: 10
          }
        },
        required: %w[query]
      }

      # Ordered list of search providers to try in sequence.
      # Parallel is the primary no-key provider; the HTML scrapers remain as
      # fallbacks, with cn.bing.com accessible in mainland China without VPN.
      # You.com's free tier is a second no-key engine behind Parallel.
      PROVIDERS = %i[parallel you duckduckgo bing].freeze

      SEARCHER_TIMEOUT = 30
      PARALLEL_ENDPOINT = "https://search.parallel.ai/mcp"
      PARALLEL_SNIPPET_MAX_CHARS = 400
      # No key needed: 100 searches/day per IP. Keyed users can pick the
      # bundled ~/.clacky/searchers/you.rb instead.
      YOU_FREE_ENDPOINT = "https://api.you.com/v1/agents/search"
      YOU_USER_AGENT = "youdotcom-integration/clacky-ai-openclacky"
      # Shared by every provider, hosted or free: one failure keeps that
      # provider out of the retry path for the whole window.
      PROVIDER_COOLDOWN_SECONDS = 3600

      def execute(query:, max_results: 10, working_dir: nil)
        if query.nil? || query.strip.empty?
          return { error: "Query cannot be empty" }
        end

        last_error = nil

        providers = active_providers
        providers.each do |provider|
          begin
            results = send(:"search_#{provider}", query, max_results)
            # Consider it a success only if we got real results
            next if results.empty? || results.first[:url].include?("duckduckgo.com") && results.first[:title] == "Web search results"

            return {
              query: query,
              results: results,
              count: results.length,
              provider: provider == :custom ? Clacky::SearchConfig.load["provider"] : provider.to_s,
              error: nil
            }
          rescue StandardError => e
            # Avoid paying the same network/handshake failure on every search.
            case provider
            when :deepseek
              Clacky::DeepSeekWebTools.mark_unavailable!
            when :parallel
              reset_parallel_client
              @parallel_unavailable_until = Time.now + PROVIDER_COOLDOWN_SECONDS
            when :you
              @you_unavailable_until = Time.now + (e.respond_to?(:retry_after) && e.retry_after || PROVIDER_COOLDOWN_SECONDS)
            when :duckduckgo
              @ddg_unavailable_until = Time.now + PROVIDER_COOLDOWN_SECONDS
            end
            last_error = e
            next
          end
        end

        {
          query: query,
          results: [],
          count: 0,
          provider: nil,
          error: search_failure_message(providers, last_error)
        }
      end

      private def search_failure_message(providers, last_error)
        reason = last_error ? "Last error: #{last_error.message.strip.sub(/\.?\z/, ".")}" : "No results returned."

        if providers == [:custom]
          name = Clacky::SearchConfig.load["provider"]
          "Configured search provider '#{name}' failed. #{reason} " \
            "Check the key and the script at #{Clacky::SearchConfig.script_path}, " \
            "or reconfigure it in Settings → Search."
        elsif providers.include?(:deepseek)
          "DeepSeek web search failed and no free engine returned results. #{reason} " \
            "Check the API key and balance in Settings → Web Search; DeepSeek will be " \
            "retried in #{PROVIDER_COOLDOWN_SECONDS / 60} minutes."
        else
          "All search providers failed. #{reason}"
        end
      end

      # Skip DuckDuckGo if it failed recently (within last 10 minutes)
      private def active_providers
        # An explicitly configured searcher is authoritative: falling back to a
        # built-in scraper would silently ignore the user's choice and make a
        # broken key or script look like a low-quality result set.
        return [:custom] if Clacky::SearchConfig.script_path

        free_chain = PROVIDERS.reject do |provider|
          unavailable_until = case provider
                              when :parallel then @parallel_unavailable_until
                              when :you then @you_unavailable_until
                              when :duckduckgo then @ddg_unavailable_until
                              end
          unavailable_until && Time.now < unavailable_until
        end

        return free_chain unless Clacky::SearchConfig.deepseek_web?

        # DeepSeek leads the chain but does not replace the free engines: a
        # missing key, an exhausted balance or an outage should degrade to a
        # working search rather than return nothing.
        return free_chain if Clacky::DeepSeekWebTools.cooling_down?
        return free_chain unless deepseek_web_available?

        [:deepseek] + free_chain
      end

      # ── Parallel Free MCP ──────────────────────────────────────────────────

      private def search_parallel(query, max_results)
        result = parallel_client.call_tool(
          "web_search",
          {
            "objective" => query[0, 5000],
            "search_queries" => [query[0, 200]],
            "session_id" => parallel_logical_session_id
          }
        )

        if result["isError"]
          message = extract_parallel_content_text(result)
          raise(message.empty? ? "Parallel search failed" : message)
        end

        payload = result["structuredContent"]
        payload ||= JSON.parse(extract_parallel_content_text(result))
        raise "Parallel returned malformed search results" unless payload.is_a?(Hash) && payload["results"].is_a?(Array)

        payload["results"].filter_map do |item|
          next unless item.is_a?(Hash)

          url = item["url"].to_s
          next if url.empty?

          snippet = Array(item["excerpts"]).join(" ").gsub(/\s+/, " ").strip
          {
            title: item["title"].to_s,
            url: url,
            snippet: snippet[0, PARALLEL_SNIPPET_MAX_CHARS]
          }
        end.first(max_results)
      rescue JSON::ParserError
        raise "Parallel returned malformed JSON"
      end

      private def parallel_client
        @parallel_client ||= Clacky::Mcp::Client.from_spec(
          "parallel-free",
          { "type" => "http", "url" => PARALLEL_ENDPOINT }
        ).tap(&:start)
      end

      private def reset_parallel_client
        @parallel_client&.stop
        @parallel_client = nil
      end

      private def parallel_logical_session_id
        @parallel_logical_session_id ||= SecureRandom.uuid
      end

      private def extract_parallel_content_text(result)
        Array(result["content"]).filter_map do |item|
          item["text"] if item.is_a?(Hash) && item["type"] == "text"
        end.join("\n")
      end

      # ── You.com free tier (no key) ─────────────────────────────────────────

      # Raised for a non-2xx free-tier answer; carries Retry-After (seconds)
      # so a 429 cools You.com down for as long as the server asks.
      class YouSearchError < StandardError
        attr_reader :retry_after

        def initialize(message, retry_after: nil)
          super(message)
          @retry_after = retry_after
        end
      end

      private def search_you(query, max_results)
        url = URI(YOU_FREE_ENDPOINT)
        url.query = URI.encode_www_form(query: query, count: max_results.clamp(1, 20))
        request = Net::HTTP::Get.new(url)
        request["User-Agent"] = YOU_USER_AGENT
        request["Accept"] = "application/json"

        response = Net::HTTP.start(url.hostname, url.port, use_ssl: true, read_timeout: 10, open_timeout: 5) do |http|
          http.request(request)
        end
        raise you_error(response) unless response.is_a?(Net::HTTPSuccess)

        parse_you_results(response.body, max_results)
      end

      private def you_error(response)
        code = response.code.to_i
        retry_after = Integer(response["retry-after"].to_s, exception: false)
        reason = case code
                 when 401, 403 then "access denied"
                 when 402 then "free quota exhausted"
                 when 429 then "rate limited"
                 else "HTTP #{code}"
                 end
        YouSearchError.new("You.com search failed: #{reason} (#{code})",
                           retry_after: retry_after&.positive? ? retry_after : nil)
      end

      private def parse_you_results(body, max_results)
        payload = JSON.parse(body.to_s)
        web = payload.is_a?(Hash) && payload.dig("results", "web")
        raise "You.com returned malformed search results" unless web.is_a?(Array)

        web.filter_map do |item|
          next unless item.is_a?(Hash)

          url = item["url"].to_s
          next if url.empty?

          snippet = item["description"].to_s
          snippet = Array(item["snippets"]).join(" ") if snippet.strip.empty?
          {
            title: item["title"].to_s,
            url: url,
            snippet: snippet.gsub(/\s+/, " ").strip[0, PARALLEL_SNIPPET_MAX_CHARS]
          }
        end.first(max_results)
      rescue JSON::ParserError
        raise "You.com returned malformed JSON"
      end

      # ── DeepSeek hosted search (paid, opt-in) ──────────────────────────────

      private def deepseek_web_available?
        return false unless agent

        agent.config.deepseek_web_ready?
      rescue StandardError
        false
      end

      private def search_deepseek(query, max_results)
        config = agent.config
        key = config.deepseek_web_key
        Clacky::DeepSeekWebTools.search(
          query: query,
          count: max_results,
          api_key: key,
          base_url: config.deepseek_web_base_url(key)
        )
      end

      # ── Configured searcher (~/.clacky/searchers/<provider>.rb) ────────────

      private def search_custom(query, max_results)
        script = Clacky::SearchConfig.script_path
        return [] unless script

        interpreter = Clacky::Utils::SearcherManager.interpreter_for(script)
        env = { "CLACKY_SEARCH_KEY" => Clacky::SearchConfig.key }

        stdout, stderr, status = Clacky::Utils::ParserManager.capture3_with_timeout(
          env, interpreter, script, query, max_results.to_s, timeout: SEARCHER_TIMEOUT
        )

        raise "Searcher timed out after #{SEARCHER_TIMEOUT}s" if status == :timeout
        raise (stderr.to_s.strip.empty? ? "Searcher exited with #{status.exitstatus}" : stderr.strip) unless status.success?

        parse_custom_results(Clacky::Utils::Encoding.to_utf8(stdout.to_s), max_results)
      end

      private def parse_custom_results(stdout, max_results)
        parsed = JSON.parse(stdout)
        raise "Searcher must output a JSON array" unless parsed.is_a?(Array)

        parsed.filter_map do |item|
          next unless item.is_a?(Hash)

          url = item["url"].to_s
          next if url.empty?

          { title: item["title"].to_s, url: url, snippet: item["snippet"].to_s }
        end.first(max_results)
      end

      # ── DuckDuckGo ─────────────────────────────────────────────────────────

      private def search_duckduckgo(query, max_results)
        encoded_query = CGI.escape(query)
        url = URI("https://html.duckduckgo.com/html/?q=#{encoded_query}")
        response = http_get(url)
        return [] unless response.is_a?(Net::HTTPSuccess)

        parse_duckduckgo_html(response.body, max_results)
      end

      private def parse_duckduckgo_html(html, max_results)
        results = []
        html = Clacky::Utils::Encoding.to_utf8(html)

        links = html.scan(%r{<a[^>]*class="result__a"[^>]*href="//duckduckgo\.com/l/\?uddg=([^"&]+)[^"]*"[^>]*>(.*?)</a>}m)
        snippets = html.scan(%r{<a[^>]*class="result__snippet"[^>]*>(.*?)</a>}m)

        links.each_with_index do |link_data, index|
          break if results.length >= max_results

          url = Clacky::Utils::Encoding.to_utf8(CGI.unescape(link_data[0]))
          title = link_data[1].gsub(/<[^>]+>/, "").strip
          title = CGI.unescapeHTML(title) if title.include?("&")

          snippet = ""
          if snippets[index]
            snippet = snippets[index][0].gsub(/<[^>]+>/, "").strip
            snippet = CGI.unescapeHTML(snippet) if snippet.include?("&")
          end

          results << { title: title, url: url, snippet: snippet }
        end

        results
      end

      # ── Bing ───────────────────────────────────────────────────────────────

      BING_ENDPOINTS = [
        ["cn.bing.com", "zh-CN,zh;q=0.9,en;q=0.8"],
        ["www.bing.com", "en-US,en;q=0.9"]
      ].freeze

      # Race both Bing endpoints in parallel and return the first relevant result.
      # cn.bing.com works best from mainland China; www.bing.com works best from
      # overseas. Racing avoids guessing the network egress and recovers from
      # one endpoint temporarily returning anti-scrape filler. If both return
      # irrelevant garbage, fall back to whichever came back non-empty.
      private def search_bing(query, max_results)
        queue = Queue.new
        threads = BING_ENDPOINTS.map do |host, lang|
          Clacky::ThreadRegistry.spawn(name: "web-search-bing") do
            results = bing_fetch(host, lang, query, max_results)
            queue.push([host, results])
          rescue StandardError
            queue.push([host, []])
          end
        end

        winner = nil
        runner_up = nil
        BING_ENDPOINTS.length.times do
          _host, results = queue.pop
          if bing_results_relevant?(results, query)
            winner = results
            break
          elsif !results.empty? && runner_up.nil?
            runner_up = results
          end
        end

        threads.each(&:kill)
        winner || runner_up || []
      end

      private def bing_fetch(host, lang, query, max_results)
        url = URI("https://#{host}/search?q=#{CGI.escape(query)}&count=#{max_results}&form=QBLH")
        response = http_get(url, accept_language: lang, follow_redirects: 2,
                                 referer: "https://#{host}/")
        return [] unless response.is_a?(Net::HTTPSuccess)

        parse_bing_html(response.body, max_results)
      end

      # A real Bing answer mentions at least one query token in the titles or
      # snippets. The anti-scrape fallback returns top-domain filler (Yandex,
      # Bunnings, WikiLeaks, …) that shares nothing with the query.
      private def bing_results_relevant?(results, query)
        return false if results.empty?

        tokens = query.downcase.scan(/[\p{L}\p{N}]+/).reject { |t| t.length < 2 }
        return true if tokens.empty?

        results.any? do |r|
          haystack = "#{r[:title]} #{r[:snippet]}".downcase
          tokens.any? { |t| haystack.include?(t) }
        end
      end

      private def parse_bing_html(html, max_results)
        results = []
        html = Clacky::Utils::Encoding.to_utf8(html)

        # Bing result blocks: <li class="b_algo">...</li>
        blocks = html.scan(%r{<li[^>]*class="b_algo"[^>]*>(.*?)</li>}m)

        blocks.each do |block_arr|
          break if results.length >= max_results
          block = block_arr[0]

          # Extract URL and title from <h2><a href="URL">TITLE</a></h2>
          title_match = block.match(%r{<h2[^>]*>.*?<a[^>]*href="(https?://[^"]+)"[^>]*>(.*?)</a>}m)
          next unless title_match

          raw_url = CGI.unescapeHTML(title_match[1])
          url = decode_bing_url(raw_url)
          title = title_match[2].gsub(/<[^>]+>/, "").strip
          title = CGI.unescapeHTML(title) if title.include?("&")

          # Extract snippet from <p class="b_lineclamp..."> or <div class="b_caption"><p>
          snippet = ""
          snippet_match = block.match(%r{<p[^>]*class="b_lineclamp[^"]*"[^>]*>(.*?)</p>}m) ||
                          block.match(%r{<div[^>]*class="b_caption"[^>]*>.*?<p[^>]*>(.*?)</p>}m)
          if snippet_match
            snippet = snippet_match[1].gsub(/<[^>]+>/, "").strip
            snippet = CGI.unescapeHTML(snippet) if snippet.include?("&")
          end

          results << { title: title, url: url, snippet: snippet }
        end

        results
      end

      # Decode Bing's redirect URL: bing.com/ck/a?...&u=a1BASE64URL&ntb=1
      # The "u" param is "a1" prefix + base64-encoded real URL
      private def decode_bing_url(url)
        return url unless url.include?("bing.com/ck/")

        u_param = url.match(/[?&]u=([^&]+)/)
        return url unless u_param

        encoded = u_param[1]
        # Remove "a1" prefix then base64-decode
        return url unless encoded.start_with?("a1")

        base64_part = encoded[2..]
        # Bing uses URL-safe base64 without padding
        padded = base64_part + "=" * ((4 - base64_part.length % 4) % 4)
        decoded = Base64.urlsafe_decode64(padded)
        decoded.force_encoding("UTF-8").valid_encoding? ? decoded : url
      rescue StandardError
        url
      end

      # ── Shared HTTP helper ─────────────────────────────────────────────────

      USER_AGENTS = [
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
      ].freeze

      # Shared browser-like GET request — no Accept-Encoding to avoid gzip/br
      # detection tricks used by Bing. Supports redirect following.
      private def http_get(url, accept_language: "en-US,en;q=0.9", follow_redirects: 0, referer: nil)
        request = Net::HTTP::Get.new(url)
        request["User-Agent"] = USER_AGENTS.sample
        request["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        request["Accept-Language"] = accept_language
        # Deliberately omit Accept-Encoding — sending gzip causes Bing to return
        # a JS-only skeleton (~39KB) instead of the real HTML results (~120KB)
        request["Sec-Fetch-Dest"] = "document"
        request["Sec-Fetch-Mode"] = "navigate"
        request["Sec-Fetch-Site"] = referer ? "same-origin" : "none"
        request["Upgrade-Insecure-Requests"] = "1"
        request["Referer"] = referer if referer

        response = Net::HTTP.start(url.hostname, url.port,
          use_ssl: url.scheme == "https",
          read_timeout: 8,
          open_timeout: 5) { |http| http.request(request) }

        # Follow redirects (e.g. cn.bing.com redirects to www.bing.com for non-China IPs)
        if follow_redirects > 0 && response.is_a?(Net::HTTPRedirection)
          location = response["location"]
          redirect_url = location.start_with?("http") ? URI(location) : URI("#{url.scheme}://#{url.hostname}#{location}")
          return http_get(redirect_url, accept_language: accept_language, follow_redirects: follow_redirects - 1, referer: referer)
        end

        response
      end

      # ── Formatting ─────────────────────────────────────────────────────────

      def format_call(args)
        query = args[:query] || args["query"] || ""
        display_query = query.length > 40 ? "#{query[0..37]}..." : query
        "web_search(\"#{display_query}\")"
      end

      def format_result(result)
        if result[:error]
          "[Error] #{result[:error]}"
        else
          count = result[:count] || 0
          provider = result[:provider] ? " via #{result[:provider]}" : ""
          "[OK] Found #{count} results#{provider}"
        end
      end

      def ui_result(result)
        {
          type: "web_search",
          query: result[:query],
          count: result[:count],
          provider: result[:provider],
          results: result[:results],
          error: result[:error]
        }
      end

    end
  end
end
