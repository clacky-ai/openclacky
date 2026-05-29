# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::PlatformHttpClient, "#parse_response" do
  let(:client) { described_class.new }

  def fake_response(code, body)
    Struct.new(:code, :body).new(code.to_s, body)
  end

  def parse(code, payload)
    body = payload.is_a?(String) ? payload : JSON.generate(payload)
    client.send(:parse_response, fake_response(code, body))
  end

  describe "successful responses" do
    it "returns success and unwraps data envelope" do
      result = parse(200, { "data" => { "id" => 1 } })
      expect(result).to eq(success: true, data: { "id" => 1 })
    end

    it "treats whole body as data when no `data` key" do
      result = parse(201, { "id" => 7, "name" => "x" })
      expect(result).to eq(success: true, data: { "id" => 7, "name" => "x" })
    end
  end

  describe "error responses" do
    it "maps known error code to localized message" do
      result = parse(401, { "code" => "invalid_proof" })
      expect(result[:success]).to be false
      expect(result[:error]).to eq(Clacky::PlatformHttpClient::API_ERROR_MESSAGES["invalid_proof"])
    end

    it "uses `error` string from body when no code mapping" do
      result = parse(422, { "error" => "boom" })
      expect(result[:error]).to eq("boom")
    end

    it "joins `errors` array (Rails-style full_messages)" do
      result = parse(422, {
        "status" => "error",
        "code"   => "upload_failed",
        "errors" => ["Skill name 'ab-test-analysis' is reserved", "second issue"]
      })
      expect(result[:error]).to eq("Skill name 'ab-test-analysis' is reserved; second issue")
    end

    it "uses `errors` string when present" do
      result = parse(422, { "errors" => "single string error" })
      expect(result[:error]).to eq("single string error")
    end

    it "uses `message` as a fallback key" do
      result = parse(500, { "message" => "internal failure" })
      expect(result[:error]).to eq("internal failure")
    end

    it "ignores blank/empty entries and falls back to generic message" do
      result = parse(500, { "error" => "", "errors" => [], "message" => "  " })
      expect(result[:error]).to match(/Request failed \(HTTP 500\)/)
    end

    it "includes machine code in generic fallback when present" do
      result = parse(422, { "code" => "totally_unknown_code" })
      expect(result[:error]).to include("code: totally_unknown_code")
    end

    it "handles non-JSON body gracefully" do
      result = parse(502, "<html>Bad Gateway</html>")
      expect(result[:success]).to be false
      expect(result[:error]).to match(/Request failed \(HTTP 502\)/)
    end
  end
end
