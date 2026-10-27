# frozen_string_literal: true

require "net/http"
require "socket"
require "timeout"
require "uri"

module Clacky
  module Server
    # Preview panel routes: static workspace-file serving
    # (/preview/s/<session>/<path>) and localhost dev-server proxying
    # (/preview/p/<port>/<path>). Mixed into HttpServer so the route table
    # (send(:serve_preview, ...)) dispatches into it unchanged.
    module Preview
      # MIME types served by the /preview/s/<session>/<path> route. Anything
      # not listed falls back to a download (application/octet-stream) so an
      # AI-generated page's sibling files can never execute as HTML.
      PREVIEW_CONTENT_TYPES = {
        ".html"  => "text/html; charset=utf-8",
        ".htm"   => "text/html; charset=utf-8",
        ".css"   => "text/css; charset=utf-8",
        ".js"    => "text/javascript; charset=utf-8",
        ".mjs"   => "text/javascript; charset=utf-8",
        ".json"  => "application/json; charset=utf-8",
        ".map"   => "application/json; charset=utf-8",
        ".svg"   => "image/svg+xml",
        ".png"   => "image/png",
        ".jpg"   => "image/jpeg",
        ".jpeg"  => "image/jpeg",
        ".gif"   => "image/gif",
        ".webp"  => "image/webp",
        ".avif"  => "image/avif",
        ".ico"   => "image/x-icon",
        ".bmp"   => "image/bmp",
        ".woff"  => "font/woff",
        ".woff2" => "font/woff2",
        ".ttf"   => "font/ttf",
        ".otf"   => "font/otf",
        ".eot"   => "application/vnd.ms-fontobject",
        ".txt"   => "text/plain; charset=utf-8",
        ".xml"   => "application/xml; charset=utf-8",
        ".csv"   => "text/csv; charset=utf-8",
        ".wasm"  => "application/wasm",
        ".mp4"   => "video/mp4",
        ".webm"  => "video/webm",
        ".mp3"   => "audio/mpeg",
        ".wav"   => "audio/wav",
        ".ogg"   => "audio/ogg"
      }.freeze

      # Injected into preview HTML responses. The preview iframe is cross-origin
      # to the host page, so the host cannot read its location (and the iframe's
      # src property does not follow internal navigations). Each served page
      # therefore announces its own URL to the parent. Re-reporting is not just
      # the initial load: Turbo/htmx/React-Router navigations swap the DOM
      # without a full page load, so the same script also listens for their
      # events, patches the History API and falls back to a slow poll.
      PREVIEW_NAV_REPORT = <<~JS.freeze
        <script>(function(){
          var last = null;
          function report(){
            try {
              if (location.href === last) return;
              last = location.href;
              parent.postMessage({__clackyPreview:1,href:location.href},"*");
            } catch(e){}
          }
          report();
          ["turbo:load","turbo:render","turbo:frame-load","htmx:afterSwap","pjax:end","DOMContentLoaded"].forEach(function(n){
            document.addEventListener(n, report);
          });
          window.addEventListener("popstate", report);
          window.addEventListener("hashchange", report);
          var push = history.pushState, replace = history.replaceState;
          history.pushState = function(){ push.apply(history, arguments); report(); };
          history.replaceState = function(){ replace.apply(history, arguments); report(); };
          setInterval(report, 500);
        })()</script>
      JS


      # Must match ISOLATED_PREVIEW_HOST in
      # default_extensions/preview/panels/preview/view.js. Chrome resolves
      # every *.localhost name to loopback, so the preview frame runs on this
      # origin while the UI stays on 127.0.0.1/localhost.
      ISOLATED_PREVIEW_HOST = "preview.localhost"

      # Hostnames a dev server may redirect to with an absolute URL. Only these
      # are folded back into the proxy prefix; anything else is a deliberate
      # off-box redirect and is passed through untouched.
      LOOPBACK_HOSTS = %w[127.0.0.1 localhost ::1].freeze

      # Headers dropped when proxying a localhost dev server through the
      # preview panel. X-Frame-Options is what blocks the sandboxed iframe and
      # hop-by-hop headers are recomputed by WEBrick. Set-Cookie is handled
      # separately (see #preview_cookie) because the isolated preview origin
      # needs the upstream session to survive inside a third-party frame.
      PROXY_SKIP_HEADERS = %w[
        x-frame-options
        transfer-encoding
        content-length
        connection
        keep-alive
        proxy-authenticate
        proxy-authorization
        te
        trailer
        upgrade
      ].freeze

      # Connection-stage failures when dialing the localhost dev server. The
      # proxy retries the next loopback stack on these and answers 502 only
      # when both stacks fail.
      PROXY_CONNECT_ERRORS = [
        Errno::ECONNREFUSED,
        Errno::ECONNRESET,
        Errno::EHOSTUNREACH,
        Net::OpenTimeout,
        SocketError
      ].freeze

      private def preview_not_found(res)
        res.status = 404
        res.body   = "not found"
      end

      private def preview_method_not_allowed(res)
        res.status   = 405
        res["Allow"] = "GET, HEAD"
        res.body     = "method not allowed"
      end

      private def preview_invalid_port(res)
        res.status = 400
        res.body   = "invalid port"
      end

      private def preview_unreachable(res, port)
        res.status = 502
        res.body   = "cannot reach localhost:#{port}"
      end

      # GET /preview/s/<session_id>/<rel> — serve a workspace file for the
      # preview panel. The session id resolves to that session's working_dir
      # and rel must stay inside it. Directory requests fall back to
      # index.html so the page's relative asset references keep resolving.
      # Extensions missing from PREVIEW_CONTENT_TYPES download (octet-stream)
      # instead of rendering, so a non-listed file can never execute as HTML.
      private def serve_preview(req, res)
        unless req.request_method == "GET" || req.request_method == "HEAD"
          preview_method_not_allowed(res)
          return
        end

        rest = preview_decode_path(req.path.delete_prefix("/preview/"))
        sid, _, rel = rest.delete_prefix("s/").partition("/")

        session     = sid.empty? ? nil : @session_manager.load(sid)
        working_dir = session ? session[:working_dir].to_s : ""
        if working_dir.empty?
          preview_not_found(res)
          return
        end

        root = File.expand_path(working_dir)
        abs  = File.expand_path(File.join(root, rel))
        unless abs == root || abs.start_with?(root + File::SEPARATOR)
          preview_not_found(res)
          return
        end

        serve_preview_file(req, res, abs)
      end

      # GET /preview/f/<absolute-path> — serve a local file outside the
      # workspace, addressed by its absolute path (the panel maps file:// URLs
      # here). Restricted to the user's home directory so it cannot read
      # system files elsewhere.
      private def serve_preview_local(req, res)
        unless req.request_method == "GET" || req.request_method == "HEAD"
          preview_method_not_allowed(res)
          return
        end

        abs = preview_decode_path(req.path.delete_prefix("/preview/f"))
        return preview_not_found(res) if abs.empty? || !abs.start_with?("/")

        abs  = File.expand_path(abs)
        home = File.expand_path(Dir.home)
        unless abs == home || abs.start_with?(home + File::SEPARATOR)
          preview_not_found(res)
          return
        end

        serve_preview_file(req, res, abs)
      end

      # Shared tail for the file-serving routes: resolve a directory to its
      # index.html, then stream the file with the MIME whitelist and the
      # injected navigation reporter.
      private def serve_preview_file(req, res, abs)
        abs = File.join(abs, "index.html") if File.directory?(abs)
        unless File.file?(abs)
          preview_not_found(res)
          return
        end

        res.status                      = 200
        res["Content-Type"]             = PREVIEW_CONTENT_TYPES[File.extname(abs).downcase] || "application/octet-stream"
        res["Cache-Control"]            = "no-store"
        res["Pragma"]                   = "no-cache"
        res["X-Content-Type-Options"]  = "nosniff"
        if req.request_method == "HEAD"
          res["Content-Length"] = File.size(abs).to_s
          res.body = ""
        else
          body = preview_body(abs)
          res["Content-Length"] = body.bytesize.to_s
          res.body = body
        end
      end

      # Injected right after <head> (falling back to <html>, <!DOCTYPE>, or
      # the document start) so the reporter runs before page scripts while a
      # leading <!DOCTYPE> stays first — prepending would flip the document
      # into quirks mode.
      private def inject_nav_report(html)
        html = html.force_encoding(Encoding::UTF_8)
        if (m = html.match(/<head[^>]*>/i))
          html[m.end(0), 0] = PREVIEW_NAV_REPORT
        elsif (m = html.match(/<html[^>]*>/i))
          html[m.end(0), 0] = PREVIEW_NAV_REPORT
        elsif (m = html.match(/<!DOCTYPE[^>]*>/i))
          html[m.end(0), 0] = PREVIEW_NAV_REPORT
        else
          html = PREVIEW_NAV_REPORT + html
        end
        html
      end

      private def preview_body(abs)
        body = File.binread(abs)
        return body unless (PREVIEW_CONTENT_TYPES[File.extname(abs).downcase] || "").start_with?("text/html")

        inject_nav_report(body)
      end

      # Decode %XX escapes in a preview path segment without treating "+" as
      # space: "+" is a legal literal character in file names.
      private def preview_decode_path(seg)
        return seg unless seg.include?("%")

        seg.gsub(/%([0-9A-Fa-f]{2})/) { |m| m[1, 2].to_i(16).chr }
           .force_encoding(Encoding::UTF_8)
      end

      # GET /preview/p/<port>/<path> — proxy a localhost dev server through the
      # preview panel. Rails/Next.js and friends ship X-Frame-Options / CSP
      # frame-ancestors by default, which blocks a sandboxed iframe; the proxy
      # strips those so the page renders. The host is restricted to the loopback
      # interfaces (127.0.0.1 then ::1 — the port is the only variable), so this
      # route can never be pointed at the public internet or another internal
      # host — no SSRF.
      private def serve_preview_proxy(req, res)
        unless req.request_method == "GET" || req.request_method == "HEAD"
          preview_method_not_allowed(res)
          return
        end

        port_str, _, rel = req.path.delete_prefix("/preview/p/").partition("/")
        unless port_str.match?(/\A\d+\z/)
          preview_invalid_port(res)
          return
        end
        port = port_str.to_i
        if port < 1 || port > 65_535
          preview_invalid_port(res)
          return
        end

        target = "/" + rel
        target += "?" + req.query_string if req.query_string && !req.query_string.empty?

        klass = req.request_method == "HEAD" ? Net::HTTP::Head : Net::HTTP::Get

        resp = nil
        # Vite 5 binds only the IPv6 loopback (::1) on macOS, so connecting to
        # 127.0.0.1 alone 502s even while the dev server is up. Try both stacks.
        %w[127.0.0.1 ::1].each do |host|
          up_req = klass.new(target)
          # Accept-Encoding is dropped so the upstream answers with plain bytes
          # instead of gzip.
          %w[Accept User-Agent Cookie Accept-Language Referer Range].each do |h|
            v = req[h]
            up_req[h] = v if v && !v.empty?
          end

          http = Net::HTTP.new(host, port)
          http.open_timeout = 2
          http.read_timeout  = 20
          begin
            resp = http.request(up_req)
            break
          rescue *PROXY_CONNECT_ERRORS
            next
          end
        end

        if resp.nil?
          preview_unreachable(res, port)
          return
        end

        res.status = resp.code.to_i
        is_html = false
        is_css  = false
        upstream_frameable = true
        resp.each_capitalized do |name, value|
          down = name.downcase
          upstream_frameable = false if down == "x-frame-options"
          if down == "content-security-policy" || down == "content-security-policy-report-only"
            upstream_frameable = false if value =~ /frame-ancestors/i
            value = strip_frame_ancestors(value)
            next if value.nil? || value.empty?
          end
          next if PROXY_SKIP_HEADERS.include?(down)
          if down == "set-cookie"
            cookie = preview_cookie(value)
            res.cookies << cookie if cookie && isolated_preview_request?(req)
            next
          end
          if down == "location"
            res[name] = rewrite_preview_location(value, port, req)
            next
          end
          if down == "content-type"
            is_html = value.start_with?("text/html")
            is_css  = value.start_with?("text/css")
          end
          res[name] = value
        end
        # Tells the preview panel whether the upstream can be framed directly.
        # Vite-style dev servers send no X-Frame-Options, and their JS relies
        # on absolute-path ESM imports the proxy cannot rewrite — for those,
        # a direct iframe (which also keeps HMR websockets alive) is the only
        # rendering path that works.
        res["X-Clacky-Upstream-Frameable"] = upstream_frameable ? "1" : "0"
        if req.request_method != "HEAD"
          body = resp.body.to_s
          if is_html
            body = inject_nav_report(rewrite_preview_paths(body, port))
          elsif is_css
            body = rewrite_preview_css(body, port)
          end
          res.body = body
        end
      rescue Net::ReadTimeout, Timeout::Error, EOFError
        preview_unreachable(res, port)
      end

      # Removes the frame-ancestors directive from a Content-Security-Policy
      # value so the proxied page may be framed, keeping the rest of the
      # policy intact. Returns nil when nothing (or an empty policy) remains.
      private def strip_frame_ancestors(csp)
        stripped = csp.to_s.gsub(/frame-ancestors[^;]*;?/i, "")
        stripped = stripped.gsub(/;\s*;/, ";").gsub(/^\s*;|;\s*$/, "").strip
        stripped.empty? ? nil : stripped
      end

      # Rewrites an upstream Set-Cookie so it survives inside the preview
      # frame. The frame is a third-party context for the host UI, where Chrome
      # drops SameSite=Lax/Strict cookies outright, so the session cookie the
      # dev server just set would be discarded and every page would look like a
      # fresh, cookie-less visit. SameSite=None needs Secure, which Chrome
      # accepts over http for *.localhost because it is a trustworthy origin.
      # Domain is dropped so the cookie stays pinned to the preview origin and
      # can never be read by the host UI.
      private def preview_cookie(value)
        parts = value.to_s.split(";").map(&:strip).reject(&:empty?)
        return nil if parts.empty?

        kept = parts[1..-1].reject do |attr|
          attr =~ /\A(?:domain|samesite)\s*=/i || attr =~ /\Asecure\z/i
        end
        ([parts.first] + kept + ["SameSite=None", "Secure"]).join("; ")
      end

      private def isolated_preview_request?(req)
        req["Host"].to_s.split(":").first.to_s.downcase == ISOLATED_PREVIEW_HOST
      end

      # An upstream 3xx points at the dev server root (/dashboard). Inside the
      # isolated preview frame that resolves against the proxy origin and loses
      # the /preview/p/<port> prefix, so the redirect lands on a 404 — and the
      # address bar never sees the new page. Keep root-relative redirects inside
      # the prefix and fold absolute ones that point back at the same dev
      # server. Off-box and already-prefixed URLs pass through untouched.
      private def rewrite_preview_location(value, port, req)
        return value unless isolated_preview_request?(req)

        prefix = "/preview/p/#{port}"
        if value.start_with?("/") && !value.start_with?("//")
          return value if value == prefix || value.start_with?("#{prefix}/", "#{prefix}?")

          return "#{prefix}#{value}"
        end

        uri = begin
          URI.parse(value)
        rescue URI::InvalidURIError
          return value
        end
        return value unless uri.host
        return value unless LOOPBACK_HOSTS.include?(uri.host.downcase)
        return value unless uri.port == port

        path = uri.path.to_s.empty? ? "/" : uri.path
        path += "?#{uri.query}" if uri.query
        path += "##{uri.fragment}" if uri.fragment
        "#{prefix}#{path}"
      end

      # Rewrites absolute-path resource URLs (/assets/app.js) in a proxied HTML
      # page to the proxy prefix so the browser resolves them against the dev
      # server instead of the host origin. Protocol-relative (//), already
      # proxied and scheme URLs are left untouched.
      private def rewrite_preview_paths(html, port)
        prefix = "/preview/p/#{port}"
        html.gsub(/(\b(?:src|href)\s*=\s*["'])(\/[^"']*?)(["'])/i) do
          if $2.start_with?("//", "/preview/p/")
            $&
          else
            "#{$1}#{prefix}#{$2}#{$3}"
          end
        end
      end

      # Rewrites absolute-path url() references inside a proxied stylesheet so
      # fonts/images resolve against the dev server instead of the host origin.
      private def rewrite_preview_css(css, port)
        prefix = "/preview/p/#{port}"
        css.gsub(/url\(\s*(["']?)(\/[^"')]*?)\1\s*\)/i) do
          if $2.start_with?("//", "/preview/p/")
            $&
          else
            "url(#{$1}#{prefix}#{$2}#{$1})"
          end
        end
      end
    end
  end
end
