# frozen_string_literal: true

require "json"
require "set"
require "fileutils"
require "base64"
require "tmpdir"

# Meeting Extension — real-time transcription, on-demand agent Q&A, and
# post-meeting summarization. Mounted at /api/ext/meeting/.
class MeetingExt < Clacky::ApiExtension
  timeout 30

  MEETINGS_ROOT = File.expand_path("~/.clacky/meetings")
  VOCABULARY_PATH = File.join(MEETINGS_ROOT, "vocabulary.txt")
  # Always injected into STT vocabulary — these are our own wake words / brand
  # names and must not be droppable by the user's saved list.
  SYSTEM_VOCABULARY = "Clacky, 小克".freeze
  DEFAULT_VOCABULARY = "Clacky, 小克, OpenClacky, openclacky"

  # annotate is a read-only analysis: block every side-effecting tool so the
  # forked subagent can only read/think, never write files, run commands,
  # spawn more work, or prompt the user.
  WRITE_TOOLS = %w[write edit terminal trash_manager invoke_skill ask_user browser].freeze

  # ── Vocabulary (STT biasing hints) ────────────────────────────────────────

  # GET /api/ext/meeting/vocabulary
  get "/vocabulary" do
    json(vocabulary: read_vocabulary)
  end

  # POST /api/ext/meeting/vocabulary
  # body: { vocabulary }
  post "/vocabulary" do
    text = json_body["vocabulary"].to_s.strip
    FileUtils.mkdir_p(MEETINGS_ROOT)
    File.write(VOCABULARY_PATH, text)
    json(ok: true, vocabulary: text)
  end

  # ── Lifecycle ─────────────────────────────────────────────────────────────

  # POST /api/ext/meeting/start
  # body: { session_id }
  # Creates a new meeting tied to the current session.
  post "/start" do
    sid = json_body["session_id"]
    error!("session_id required", status: 422) unless sid && !sid.empty?

    meeting_id = "mtg-#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(4)}"
    dir = File.join(MEETINGS_ROOT, sid, meeting_id)
    FileUtils.mkdir_p(dir)

    meta = { session_id: sid, meeting_id: meeting_id, started_at: Time.now.utc.iso8601 }
    File.write(File.join(dir, "meta.json"), JSON.pretty_generate(meta))
    File.write(File.join(dir, "transcript.jsonl"), "")

    json(meeting_id: meeting_id, dir: dir)
  end

  # POST /api/ext/meeting/end
  # body: { session_id, meeting_id, display_message? }
  # Finalizes the meeting and triggers summarization via the session agent.
  post "/end" do
    sid, mid = json_body.values_at("session_id", "meeting_id")
    error!("session_id and meeting_id required", status: 422) unless sid && mid

    display_message = json_body["display_message"].to_s
    display_message = "🛑 Meeting ended — generating meeting minutes…" if display_message.strip.empty?

    dir = meeting_dir(sid, mid)
    error!("meeting not found", status: 404) unless File.directory?(dir)

    meta_path = File.join(dir, "meta.json")
    meta = JSON.parse(File.read(meta_path))
    meta["ended_at"] = Time.now.utc.iso8601
    File.write(meta_path, JSON.pretty_generate(meta))

    transcript_path = File.join(dir, "transcript.jsonl")
    lines = File.readlines(transcript_path).map { |l| JSON.parse(l)["text"] }.reject { |t| t.nil? || t.strip.empty? }
    transcript = lines.join("\n")

    logger.info("end: sid=#{sid} mid=#{mid} lines=#{lines.size} transcript_len=#{transcript.length}")

    prompt = <<~PROMPT
      A meeting just ended. Your ONLY next action is to call the tool `invoke_skill` with `name: "meeting-summarizer"` and pass the transcript below as the input. Do not use any other tool. Do not answer directly. Do not open a browser or run shell commands.

      Transcript:
      #{transcript}
    PROMPT

    submit_task(sid, prompt, display_message: display_message, interrupt: true)
    json(ok: true, meeting_id: mid)
  end

  # ── Transcription ─────────────────────────────────────────────────────────

  # POST /api/ext/meeting/transcribe
  # body: { session_id, meeting_id, audio_base64, format: "wav" }
  # Sends audio chunk to LLM proxy for STT, appends result to transcript.
  post "/transcribe" do
    sid, mid = json_body.values_at("session_id", "meeting_id")
    audio_b64 = json_body["audio_base64"]
    error!("session_id, meeting_id, audio_base64 required", status: 422) unless sid && mid && audio_b64

    dir = meeting_dir(sid, mid)
    error!("meeting not found", status: 404) unless File.directory?(dir)

    mime = json_body["mime_type"].to_s.split(";").first.strip
    mime = "audio/webm" if mime.empty?
    vocabulary = merge_vocabulary(json_body["vocabulary"])
    result = call_stt(audio_b64, mime, vocabulary)

    if result["success"]
      text = result["text"].to_s.strip
      transcript_path = File.join(dir, "transcript.jsonl")
      if !text.empty? && !hallucinated_transcript?(text, vocabulary, transcript_path)
        entry = { ts: Time.now.utc.iso8601, text: text }
        File.open(transcript_path, "a") { |f| f.puts(JSON.generate(entry)) }
        json(text: text)
      else
        json(text: "")
      end
    else
      error!(result["error"] || "STT failed", status: 502)
    end
  end

  # ── Agent Q&A (when @-mentioned) ─────────────────────────────────────────

  # POST /api/ext/meeting/ask
  # body: { session_id, meeting_id, question }
  # Submits a question to the session agent with recent transcript as context.
  post "/ask" do
    sid, mid = json_body.values_at("session_id", "meeting_id")
    question = json_body["question"].to_s.strip
    error!("session_id, meeting_id, question required", status: 422) unless sid && mid && !question.empty?

    dir = meeting_dir(sid, mid)
    error!("meeting not found", status: 404) unless File.directory?(dir)

    meaningful = question.gsub(/[^\p{L}\p{N}]/, "")
    if meaningful.length < 4
      logger.warn("ask: question too short, dropping (question=#{question.inspect})")
      next json(ok: false, dropped: true, reason: "question_too_short")
    end
    if question.match?(/\A(open)?clacky\z/i) || question.match?(/\A小?克\z/) || question.match?(/\A克拉奇\z/)
      logger.warn("ask: question is a bare wake/brand word, dropping (question=#{question.inspect})")
      next json(ok: false, dropped: true, reason: "question_is_brand_word")
    end

    context = recent_transcript(dir, minutes: 5)

    prompt = <<~PROMPT
      [Meeting Mode] You are in a team meeting and have been called on to speak. Based on the recent transcript below, answer the question concisely.
      Keep it short — one or two sentences. Do not elaborate at length.

      --- Recent Transcript ---
      #{context}

      --- Question ---
      #{question}
    PROMPT

    submit_task(sid, prompt, display_message: "🎤 #{question}", interrupt: true)
    json(ok: true)
  end

  # ── Annotation (periodic background tagging) ──────────────────────────────

  # POST /api/ext/meeting/annotate
  # body: { session_id, meeting_id }
  # Analyzes recent transcript and returns tags (decisions, actions, AI-answerable).
  # Runs as a one-off side LLM call — it must NOT enter the session, otherwise
  # its raw JSON would pollute the chat transcript.
  post "/annotate" do
    sid, mid = json_body.values_at("session_id", "meeting_id")
    error!("session_id and meeting_id required", status: 422) unless sid && mid

    dir = meeting_dir(sid, mid)
    error!("meeting not found", status: 404) unless File.directory?(dir)

    context = recent_transcript(dir, minutes: 2)
    next json(annotations: []) if context.strip.empty?

    prompt = <<~PROMPT
      Analyze the following meeting transcript excerpt and identify:
      1. Decisions (something someone decided)
      2. Action Items (a task assigned to someone)
      3. AI-answerable questions (technical/factual questions asked but not yet answered)

      Output a JSON array only, no prose, no code fences. Each item:
      {"type":"decision|action|question","text":"...","speaker":"..."}
      If none found, output [].

      Transcript:
      #{context}
    PROMPT

    result = dispatch_to_session(sid, prompt, model: "lite", forbidden_tools: WRITE_TOOLS)
    next json(annotations: [], busy: true) if result[:busy]

    json(annotations: parse_annotations(result[:text].to_s))
  rescue Clacky::ApiExtension::Halt
    raise
  rescue StandardError => e
    logger.error("annotate failed: #{e.message}")
    json(annotations: [])
  end

  # ── Transcript retrieval ──────────────────────────────────────────────────

  # GET /api/ext/meeting/transcript/:session_id/:meeting_id
  get "/transcript/:session_id/:meeting_id" do
    sid = params[:session_id]
    mid = params[:meeting_id]
    dir = meeting_dir(sid, mid)
    error!("meeting not found", status: 404) unless File.directory?(dir)

    path = File.join(dir, "transcript.jsonl")
    lines = File.exist?(path) ? File.readlines(path).map { |l| JSON.parse(l) } : []
    json(transcript: lines)
  end

  # GET /api/ext/meeting/active/:session_id
  # Returns the most recent in-progress meeting (no ended_at) for the session,
  # so a page refresh can restore the live captions instead of losing them.
  get "/active/:session_id" do
    sid = params[:session_id]
    session_root = File.join(MEETINGS_ROOT, sid)
    next json(active: false) unless File.directory?(session_root)

    dir = active_meeting_dir(session_root)
    next json(active: false) unless dir

    mid = File.basename(dir)
    path = File.join(dir, "transcript.jsonl")
    lines = File.exist?(path) ? File.readlines(path).map { |l| JSON.parse(l) } : []
    json(active: true, meeting_id: mid, transcript: lines)
  end

  # POST /api/ext/meeting/speak
  # body: { text, voice? }
  # Synthesizes speech from text and returns it as base64 for the browser to play.
  post "/speak" do
    text = json_body["text"].to_s.strip
    error!("text required", status: 422) if text.empty?

    voice = json_body["voice"].to_s.strip
    voice = nil if voice.empty?

    Dir.mktmpdir("meeting-tts") do |tmp|
      result = Clacky::Media::Generator.new(agent_config).generate_speech(
        input: text,
        voice: voice,
        output_dir: tmp
      )

      error!(result["error"] || "TTS failed", status: 502) unless result["success"]

      path = result["audio"]
      error!("TTS produced no audio", status: 502) unless path && File.exist?(path)

      audio_b64 = Base64.strict_encode64(File.binread(path))
      mime = result["mime_type"] || "audio/wav"
      json(audio_base64: audio_b64, mime_type: mime)
    end
  rescue Clacky::ApiExtension::Halt
    raise
  rescue StandardError => e
    logger.error("TTS call failed: #{e.message}")
    error!(e.message, status: 502)
  end

  private def meeting_dir(session_id, meeting_id)
    File.join(MEETINGS_ROOT, session_id, meeting_id)
  end

  private def active_meeting_dir(session_root)
    Dir.children(session_root)
       .map { |name| File.join(session_root, name) }
       .select { |d| File.directory?(d) && File.exist?(File.join(d, "meta.json")) }
       .reject { |d| (JSON.parse(File.read(File.join(d, "meta.json"))) rescue {})["ended_at"] }
       .max_by { |d| File.mtime(File.join(d, "meta.json")) }
  end

  private def read_vocabulary
    return DEFAULT_VOCABULARY unless File.exist?(VOCABULARY_PATH)

    saved = File.read(VOCABULARY_PATH).strip
    saved.empty? ? "" : saved
  end

  private def merge_vocabulary(user_terms)
    parts = SYSTEM_VOCABULARY.split(/\s*,\s*/) + user_terms.to_s.split(/\s*,\s*/)
    parts.map(&:strip).reject(&:empty?).uniq.join(", ")
  end

  HALLUCINATION_PHRASES = Set.new(%w[
    no no. yes yes. ok okay you bye . .. ...
    thanks thank\ you
    uh um hmm mm mm-hmm yeah yeah. yep but and so oh ah ahh huh
    an a i the more well right hi hey wow
    嗯 啊 哦 呃 谢谢 谢谢观看 谢谢大家 好 好的 对
  ]).freeze

  DEDUP_WINDOW_SECONDS = 3.0

  private def hallucinated_transcript?(text, vocabulary, transcript_path)
    normalized = normalize_transcript(text)
    return true if normalized.empty?
    return true if HALLUCINATION_PHRASES.include?(normalized)
    return true if only_vocabulary_term?(normalized, vocabulary)
    return true if recent_duplicate?(normalized, transcript_path)
    false
  end

  private def normalize_transcript(text)
    text.to_s.downcase.gsub(/[[:space:][:punct:]]+/, " ").strip
  end

  private def only_vocabulary_term?(normalized, vocabulary)
    terms = vocabulary.to_s.split(/\s*,\s*/).map { |t| normalize_transcript(t) }.reject(&:empty?)
    terms.include?(normalized)
  end

  private def recent_duplicate?(normalized, transcript_path)
    return false unless File.exist?(transcript_path)

    cutoff = Time.now.utc - DEDUP_WINDOW_SECONDS
    File.foreach(transcript_path).to_a.last(5).any? do |line|
      entry = JSON.parse(line) rescue nil
      next false unless entry
      ts = Time.parse(entry["ts"].to_s) rescue nil
      next false unless ts && ts >= cutoff
      normalize_transcript(entry["text"]) == normalized
    end
  end

  private def recent_transcript(dir, minutes: 5)
    path = File.join(dir, "transcript.jsonl")
    return "" unless File.exist?(path)

    cutoff = Time.now.utc - (minutes * 60)
    File.readlines(path).filter_map do |line|
      entry = JSON.parse(line)
      ts = Time.parse(entry["ts"]) rescue Time.at(0)
      entry["text"] if ts >= cutoff
    end.join("\n")
  end

  private def parse_annotations(reply)
    json = reply.strip
    json = json.sub(/\A```(?:json)?\s*/, "").sub(/\s*```\z/, "") # strip code fences if any
    start = json.index("[")
    finish = json.rindex("]")
    return [] unless start && finish && finish > start

    arr = JSON.parse(json[start..finish])
    return [] unless arr.is_a?(Array)

    arr.filter_map do |item|
      next unless item.is_a?(Hash)
      text = item["text"].to_s.strip
      next if text.empty?
      { "type" => item["type"].to_s, "text" => text, "speaker" => item["speaker"].to_s }
    end
  rescue JSON::ParserError
    []
  end

  private def call_stt(audio_base64, mime_type, vocabulary = nil)
    Clacky::Media::Generator.new(agent_config).generate_transcription(
      audio_base64: audio_base64,
      mime_type: mime_type,
      prompt: vocabulary.to_s.empty? ? nil : vocabulary
    )
  rescue StandardError => e
    logger.error("STT call failed: #{e.message}")
    { "success" => false, "text" => nil, "error" => e.message }
  end
end
