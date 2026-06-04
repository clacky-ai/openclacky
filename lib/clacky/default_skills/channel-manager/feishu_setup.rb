# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module FeishuSetup
  ENDPOINT            = "/oauth/v1/app/registration"
  DEFAULT_DOMAIN      = "https://accounts.feishu.cn"
  DEFAULT_LARK_DOMAIN = "https://accounts.larksuite.com"
  SDK_NAME            = "ruby-sdk"

  class SetupError < StandardError
    attr_reader :code, :description
    def initialize(code, description)
      @code = code
      @description = description
      super("#{code}: #{description}")
    end
  end

  class AppAccessDeniedError < SetupError; end
  class AppExpiredError      < SetupError; end

  def self.run(app_name: nil, app_desc: nil, on_qr_code:, on_status_change: nil,
               domain: DEFAULT_DOMAIN, lark_domain: DEFAULT_LARK_DOMAIN)
    base_url        = domain
    domain_switched = false

    init_res = post(base_url, action: "init")
    methods  = init_res["supported_auth_methods"] || []
    unless methods.include?("client_secret")
      raise SetupError.new("unsupported_auth_method", "client_secret not supported")
    end

    begin_res = post(base_url,
      action:            "begin",
      archetype:         "PersonalAgent",
      auth_method:       "client_secret",
      request_user_info: "open_id"
    )

    device_code = begin_res["device_code"]
    interval    = (begin_res["interval"] || 5).to_i
    expire_in   = (begin_res["expires_in"] || 600).to_i
    qr_url      = build_qr_url(begin_res["verification_uri_complete"], app_name: app_name, app_desc: app_desc)

    on_qr_code.call(qr_url, expire_in)

    deadline = Time.now + expire_in

    loop do
      raise AppExpiredError.new("expired_token", "polling timed out") if Time.now >= deadline

      poll_res = post(base_url, action: "poll", device_code: device_code)

      if poll_res["client_id"] && poll_res["client_secret"]
        return { client_id: poll_res["client_id"], client_secret: poll_res["client_secret"] }
      end

      user_info = poll_res["user_info"] || {}
      if user_info["tenant_brand"] == "lark" && !domain_switched
        base_url        = lark_domain
        domain_switched = true
        on_status_change&.call("domain_switched")
        next
      end

      case poll_res["error"]
      when "authorization_pending"
        on_status_change&.call("polling")
        sleep interval
      when "slow_down"
        interval += 5
        on_status_change&.call("slow_down")
        sleep interval
      when "access_denied"
        raise AppAccessDeniedError.new("access_denied", poll_res["error_description"].to_s)
      when "expired_token"
        raise AppExpiredError.new("expired_token", poll_res["error_description"].to_s)
      else
        err = poll_res["error"].to_s
        raise SetupError.new(err, poll_res["error_description"].to_s) unless err.empty?
        sleep interval
      end
    end
  end

  private_class_method def self.post(base_url, params)
    uri               = URI("#{base_url}#{ENDPOINT}")
    http              = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = uri.scheme == "https"
    http.open_timeout = 10
    http.read_timeout = 30
    req               = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/x-www-form-urlencoded")
    req.body          = URI.encode_www_form(params)
    JSON.parse(http.request(req).body)
  end

  private_class_method def self.build_qr_url(uri_complete, app_name: nil, app_desc: nil)
    uri              = URI.parse(uri_complete)
    params           = URI.decode_www_form(uri.query.to_s).to_h
    params["from"]   = "sdk"
    params["tp"]     = "sdk"
    params["source"] = SDK_NAME
    params["name"]   = app_name if app_name
    params["desc"]   = app_desc if app_desc
    uri.query        = URI.encode_www_form(params)
    uri.to_s
  end
end

if __FILE__ == $PROGRAM_NAME
  product_name = ENV.fetch("CLACKY_PRODUCT_NAME", "OpenClacky")
  date_suffix  = Time.now.strftime("%Y%m%d")
  app_desc     = "Your personal assistant powered by #{product_name}"

  result = FeishuSetup.run(
    app_name: "#{product_name} #{date_suffix}",
    app_desc: app_desc,
    on_qr_code: lambda { |url, expire_in|
      puts "SCAN_URL:#{url}"
      puts "EXPIRE_IN:#{expire_in}"
      $stdout.flush
    },
    on_status_change: lambda { |status|
      $stderr.puts "[feishu-setup] status=#{status}"
    }
  )

  puts "APP_ID:#{result[:client_id]}"
  puts "APP_SECRET:#{result[:client_secret]}"
  $stdout.flush
end
