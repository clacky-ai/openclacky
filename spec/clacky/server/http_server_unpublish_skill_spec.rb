# frozen_string_literal: true

require "spec_helper"
require "clacky/server/http_server"

# DELETE /api/my-skills/:name — the "Unpublish" action on a cloud skill card.
RSpec.describe Clacky::Server::HttpServer, "DELETE /api/my-skills/:name" do
  let(:server)   { described_class.allocate }
  let(:response) { double("response").as_null_object }
  let(:brand)    { instance_double(Clacky::BrandConfig) }

  before do
    @code    = nil
    @payload = nil
    allow(server).to receive(:json_response) { |_res, code, body| @code = code; @payload = body }
    allow(Clacky::BrandConfig).to receive(:load).and_return(brand)
    allow(Clacky::BrandConfig).to receive(:forget_upload!)
  end

  it "soft-deletes the cloud record and forgets the local upload metadata" do
    allow(brand).to receive(:user_licensed?).and_return(true)
    allow(brand).to receive(:delete_skill!).with("add-llm-model").and_return({ success: true })

    server.send(:api_unpublish_my_skill, "add-llm-model", response)

    expect(@code).to eq(200)
    expect(@payload[:ok]).to be(true)
    expect(@payload[:name]).to eq("add-llm-model")
    expect(Clacky::BrandConfig).to have_received(:forget_upload!).with("add-llm-model")
  end

  it "refuses without a user license and never touches the platform" do
    allow(brand).to receive(:user_licensed?).and_return(false)
    expect(brand).not_to receive(:delete_skill!)

    server.send(:api_unpublish_my_skill, "add-llm-model", response)

    expect(@code).to eq(403)
    expect(@payload[:ok]).to be(false)
    expect(Clacky::BrandConfig).not_to have_received(:forget_upload!)
  end

  it "reports the platform error and keeps the upload metadata" do
    allow(brand).to receive(:user_licensed?).and_return(true)
    allow(brand).to receive(:delete_skill!).and_return({ success: false, error: "HTTP 404" })

    server.send(:api_unpublish_my_skill, "gone", response)

    expect(@code).to eq(422)
    expect(@payload[:ok]).to be(false)
    expect(@payload[:error]).to eq("HTTP 404")
    expect(Clacky::BrandConfig).not_to have_received(:forget_upload!)
  end
end
