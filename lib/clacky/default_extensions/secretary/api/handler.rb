# frozen_string_literal: true
class SecretaryExt < Clacky::ApiExtension
  get "/work" do
    error!("session_id required", status: 422) if query["session_id"].to_s.empty?
    json(work: work_service.list(query["session_id"]), schedules: work_service.schedules(query["session_id"]))
  end

end
