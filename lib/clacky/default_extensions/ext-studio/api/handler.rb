# frozen_string_literal: true

require "json"
require "tmpdir"
require "socket"
require "digest"

# Extension Studio — backend for the debug/publish panels. Mounted at
# /api/ext/ext-studio/. Reads the resolved extension tree, runs the verifier,
# packs and publishes local containers to the marketplace.
class ExtStudioExt < Clacky::ApiExtension
  timeout 60

  # GET /api/ext/ext-studio/extensions
  # List every local-layer container with a units summary and verify status,
  # so the debug panel can populate its picker and detail view.
  get "/extensions" do
    result = Clacky::ExtensionLoader.load_all(force: true)
    issues = Clacky::ExtensionVerifier.verify(result)

    exts = local_containers(result).map do |ext_id, container|
      serialize_container(ext_id, container, result, issues)
    end
    exts.sort_by! { |e| -e[:mtime] }

    json(extensions: exts)
  end

  # POST /api/ext/ext-studio/verify
  # body: { ext_id? }  — omit ext_id to verify the whole tree.
  # Returns structured issues (same shape the CLI prints) plus resolved units.
  post "/verify" do
    ext_id = json_body["ext_id"].to_s.strip
    result = Clacky::ExtensionLoader.load_all(force: true)
    issues = Clacky::ExtensionVerifier.verify(result)

    scoped = ext_id.empty? ? issues : issues.select { |i| i.ext == ext_id }
    units  = result.units
    units  = units.select { |u| u.ext_id == ext_id } unless ext_id.empty?

    json(
      ext_id: ext_id.empty? ? nil : ext_id,
      units: units.map { |u| serialize_unit(u) },
      issues: scoped.map { |i| serialize_issue(i) },
      ok: scoped.none? { |i| i.level == :error }
    )
  end

  # POST /api/ext/ext-studio/pack
  # body: { ext_id }
  # Packs a local container and streams the zip back as a file download.
  post "/pack" do
    ext_id = require_ext_id!
    Dir.mktmpdir("clacky-ext-studio-pack") do |tmp|
      res      = Clacky::ExtensionPackager.pack(ext_id, out_dir: tmp)
      zip_data = File.binread(res.path)
      send_data(zip_data, content_type: "application/zip", filename: "#{res.ext_id}.zip")
    end
  rescue Clacky::ExtensionPackager::Error => e
    error!(e.message, status: 422)
  end

  # POST /api/ext/ext-studio/publish
  # body: { ext_id, force?, status?, changelog? }
  # Packs then uploads to the marketplace. Requires the device to be bound to a
  # platform account (device token). When unbound, returns a 428 with a hint so
  # the UI can trigger the on-demand device-authorization flow.
  post "/publish" do
    ext_id = require_ext_id!

    unless Clacky::Identity.load.bound?
      error!("device not bound to a platform account; authorize this device to publish",
             status: 428, needs_binding: true)
    end

    brand = Clacky::BrandConfig.load

    origin = presence(json_body["origin"]) || "marketplace"
    if origin == "self" && !brand.user_licensed?
      error!("only brand administrators can publish to a brand", status: 403)
    end

    Dir.mktmpdir("clacky-ext-studio-publish") do |tmp|
      res      = Clacky::ExtensionPackager.pack(ext_id, out_dir: tmp)
      zip_data = File.binread(res.path)

      # Read readme from local README.md if present, so first-publish carries it.
      local_readme = nil
      result_load  = Clacky::ExtensionLoader.load_all(force: false)
      container    = Array(result_load.containers).find { |id, _| id == res.ext_id }&.last
      if container
        readme_path = File.join(container[:dir], "README.md")
        if File.exist?(readme_path)
          local_readme = File.read(readme_path, encoding: "utf-8").strip
          local_readme = nil if local_readme.empty?
        end
      end

      result = brand.upload_extension!(
        res.ext_id, zip_data,
        force:     json_body["force"] == true,
        status:    presence(json_body["status"]),
        changelog: presence(json_body["changelog"]),
        readme:    local_readme,
        origin:    origin
      )

      if result[:success]
        ext = result[:extension] || {}
        ver = (ext["latest_version"] || {})["version"]
        json(ok: true, ext_id: res.ext_id, version: ver, status: ext["status"])
      elsif result[:already_exists]
        # The same user has already published this extension — they need to use
        # force: true to publish a new version.
        json(ok: false, already_exists: true,
             error: "#{res.ext_id} already published. Publish a new version with force.")
      elsif result[:error].to_s.include?("already taken")
        # Another user has claimed this name globally — the creator must rename
        # their extension before publishing.
        json(ok: false, name_taken: true,
             error: result[:error])
      else
        error!(result[:error] || "publish failed", status: 502)
      end
    end
  rescue Clacky::ExtensionPackager::Error => e
    error!(e.message, status: 422)
  end

  # GET /api/ext/ext-studio/published
  # List the current user's published extensions from the marketplace.
  get "/published" do
    brand  = Clacky::BrandConfig.load
    result = brand.fetch_my_extensions!
    error!(result[:error] || "failed to fetch published extensions", status: 502) unless result[:success]

    exts = Array(result[:extensions]).map do |ext|
      {
        id: ext["name"] || ext["slug"] || ext["id"],
        name: ext["display_name"] || ext["name"],
        version: (ext["latest_version"] || {})["version"] || ext["version"],
        status: ext["status"],
        origin: ext["origin"],
        units: ext["units"] || {}
      }
    end
    json(extensions: exts)
  end

  # GET /api/ext/ext-studio/published_brand
  # List extensions published to the current brand's library. Only available to
  # brand administrators (user-licensed); used by the publish panel to detect
  # existing brand versions for the "publish to brand" flow.
  get "/published_brand" do
    brand = Clacky::BrandConfig.load
    error!("only brand administrators can list brand extensions", status: 403) unless brand.user_licensed?

    result = brand.fetch_brand_extensions!
    error!(result[:error] || "failed to fetch brand extensions", status: 502) unless result[:success]

    exts = Array(result[:extensions]).map do |ext|
      {
        id: ext["name"] || ext["slug"] || ext["id"],
        name: ext["display_name"] || ext["name"],
        version: (ext["latest_version"] || {})["version"] || ext["version"],
        status: ext["status"] || "published"
      }
    end
    json(extensions: exts)
  end

  # DELETE /api/ext/ext-studio/local
  # body: { ext_id }
  # Permanently removes a local extension directory. Only allowed for
  # unpublished extensions (caller must check; server enforces dir existence).
  delete "/local" do
    ext_id = require_ext_id!

    result    = Clacky::ExtensionLoader.load_all(force: false)
    container = Array(result.containers).find { |id, _| id == ext_id }&.last
    error!("extension not found: #{ext_id}", status: 404) unless container
    error!("not a local extension", status: 422) unless container[:layer] == :local

    dir = container[:dir]
    error!("extension directory not found", status: 404) unless Dir.exist?(dir)

    FileUtils.rm_rf(dir)
    Clacky::ExtensionLoader.load_all(force: true)
    json(ok: true, ext_id: ext_id)
  end

  # POST /api/ext/ext-studio/unpublish
  # body: { ext_id }
  post "/unpublish" do
    ext_id = require_ext_id!
    result = Clacky::BrandConfig.load.delete_extension!(ext_id)
    error!(result[:error] || "unpublish failed", status: 502) unless result[:success]
    json(ok: true, ext_id: ext_id)
  end

  # PATCH /api/ext/ext-studio/readme
  # body: { ext_id, readme }
  # Two modes:
  #   - Extension already published → save to platform via API
  #   - Extension not yet published → write readme field to local ext.yml
  patch "/readme" do
    ext_id = require_ext_id!
    readme = json_body["readme"].to_s

    # Check whether this extension has been published on the platform.
    brand    = Clacky::BrandConfig.load
    identity = Clacky::Identity.load
    published = false

    if identity.bound?
      my_result = brand.fetch_my_extensions!
      if my_result[:success]
        published = Array(my_result[:extensions]).any? { |e| (e["name"] || e["slug"]) == ext_id }
      end
    end

    if published
      # Already on the platform — update readme there.
      result = brand.update_extension_readme!(ext_id, readme)
      error!(result[:error] || "readme update failed", status: 502) unless result[:success]
    else
      # Not yet published — persist readme to local README.md so it's included on first publish.
      result    = Clacky::ExtensionLoader.load_all(force: false)
      container = Array(result.containers).find { |id, _| id == ext_id }&.last
      error!("extension not found: #{ext_id}", status: 404) unless container

      readme_path = File.join(container[:dir], "README.md")
      File.write(readme_path, readme, encoding: "utf-8")
    end

    json(ok: true, ext_id: ext_id, saved_to: published ? "platform" : "local")
  end

  # POST /api/ext/ext-studio/screenshot
  # Multipart body: { ext_id (field), file (image file) }
  # Uploads a screenshot image via the platform's model-agnostic upload API
  # and returns the CDN URL. Does NOT require the extension to be published yet.
  post "/screenshot" do
    q = req.query
    ext_id = q["ext_id"].to_s.strip
    error!("ext_id required", status: 422) if ext_id.empty?

    uploaded = q["file"]
    error!("missing file", status: 422) unless uploaded

    # WEBrick::HTTPUtils::FormData inherits from String — .to_s is the file bytes,
    # .filename is the original filename, .["content-type"] gives the MIME type.
    filename     = uploaded.respond_to?(:filename) ? (uploaded.filename || "screenshot.png") : "screenshot.png"
    content_type = (uploaded.respond_to?(:[]) ? uploaded["content-type"].to_s : "")
    content_type = "image/png" if content_type.empty?
    data         = uploaded.to_s
    error!("missing file", status: 422) if data.empty?

    unless Clacky::Identity.load.bound?
      error!("device not bound to a platform account", status: 428, needs_binding: true)
    end

    result = Clacky::BrandConfig.load.upload_file!(
      data,
      filename:     filename,
      content_type: content_type
    )
    error!(result[:error] || "screenshot upload failed", status: 502) unless result[:success]
    json(ok: true, url: result[:url], filename: result[:filename])
  end

  # POST /api/ext/ext-studio/set_meta
  # body: { ext_id, name?, description?, entry_points? }
  # entry_points: [{ unit_id, slot }] — stored under contributes.panels[id].entry_points
  # Writes display metadata back to the local ext.yml without touching other fields.
  post "/set_meta" do
    ext_id = require_ext_id!

    result    = Clacky::ExtensionLoader.load_all(force: false)
    container = Array(result.containers).find { |id, _| id == ext_id }&.last
    error!("extension not found: #{ext_id}", status: 404) unless container

    yml_path = File.join(container[:dir], "ext.yml")
    error!("ext.yml not found", status: 404) unless File.exist?(yml_path)

    manifest = Psych.safe_load(File.read(yml_path), permitted_classes: [], aliases: true) || {}

    manifest["name"]        = presence(json_body["name"])        if json_body.key?("name")
    manifest["description"] = presence(json_body["description"]) if json_body.key?("description")

    if json_body.key?("entry_points")
      eps = json_body["entry_points"]
      by_panel = Hash.new { |h, k| h[k] = [] }
      Array(eps).each { |ep| by_panel[ep["unit_id"].to_s] << { "slot" => ep["slot"] } if ep["slot"] }
      panels = Array((manifest["contributes"] || {})["panels"])
      panels.each do |panel|
        pid = panel["id"].to_s
        slots = by_panel[pid]
        if slots.any?
          panel["entry_points"] = slots
        else
          panel.delete("entry_points")
        end
      end
    end

    File.write(yml_path, Psych.dump(manifest))
    Clacky::ExtensionLoader.load_all(force: true)

    json(ok: true, ext_id: ext_id)
  end

  # POST /api/ext/ext-studio/set_version
  # body: { ext_id, version }
  # Writes the new version string back to the local ext.yml.
  post "/set_version" do
    ext_id  = require_ext_id!
    version = presence(json_body["version"])
    error!("version required", status: 422) unless version

    result  = Clacky::ExtensionLoader.load_all(force: false)
    container = Array(result.containers).find { |id, _| id == ext_id }&.last
    error!("extension not found: #{ext_id}", status: 404) unless container

    yml_path = File.join(container[:dir], "ext.yml")
    error!("ext.yml not found", status: 404) unless File.exist?(yml_path)

    content = File.read(yml_path)
    if content =~ /^version:/
      content = content.sub(/^version:.*$/, "version: #{version}")
    else
      content = content.rstrip + "\nversion: #{version}\n"
    end
    File.write(yml_path, content)

    json(ok: true, ext_id: ext_id, version: version)
  end


  # POST /api/ext/ext-studio/set_id
  # body: { ext_id, new_id }
  # Renames an extension: updates the `id` field in ext.yml and renames the
  # local container directory. Used when the user wants to republish under a
  # different name (e.g. after a name-taken conflict on the marketplace).
  post "/set_id" do
    ext_id = require_ext_id!
    new_id = presence(json_body["new_id"])
    error!("new_id required", status: 422) unless new_id

    slug_format = /\A[a-z0-9][a-z0-9\-]*[a-z0-9]\z/
    unless new_id.length <= 64 && new_id.match?(slug_format)
      error!("new_id must be lowercase letters, digits and hyphens (e.g. my-ext)", status: 422)
    end

    result    = Clacky::ExtensionLoader.load_all(force: false)
    container = Array(result.containers).find { |id, _| id == ext_id }&.last
    error!("extension not found: #{ext_id}", status: 404) unless container

    old_dir = container[:dir]
    new_dir = File.join(File.dirname(old_dir), new_id)
    error!("An extension named '#{new_id}' already exists locally", status: 409) if File.exist?(new_dir)

    yml_path = File.join(old_dir, "ext.yml")
    error!("ext.yml not found", status: 404) unless File.exist?(yml_path)

    # Update the id field in ext.yml, preserving all other content.
    content = File.read(yml_path)
    if content =~ /^id:/
      content = content.sub(/^id:.*$/, "id: #{new_id}")
    else
      content = "id: #{new_id}\n" + content
    end
    File.write(yml_path, content)

    # Rename the container directory.
    File.rename(old_dir, new_dir)

    # Reload so the new id is visible immediately.
    Clacky::ExtensionLoader.load_all(force: true)

    json(ok: true, old_id: ext_id, new_id: new_id)
  end

  # body: { idea? }
  # Spawns a session bound to the ext-developer agent, optionally seeded with
  # the user's idea as the first task — the "let AI build it for me" entry.
  post "/develop" do
    idea = presence(json_body["idea"])
    name = idea ? "扩展开发: #{idea[0, 40]}" : "扩展开发"
    sid  = create_session(name: name, prompt: idea, profile: "ext-developer")
    json(ok: true, session_id: sid)
  end

  # GET /api/ext/ext-studio/binding
  # Reports whether this device is bound to a platform account, so the publish
  # panel can decide up-front whether to run the binding flow.
  get "/binding" do
    identity = Clacky::Identity.load
    json(bound: identity.bound?, user_id: identity.user_id)
  end

  # POST /api/ext/ext-studio/binding/start
  # Kicks off an RFC 8628 device-authorization flow against the platform and
  # returns the verification URL the panel opens plus the device_code to poll.
  post "/binding/start" do
    client = Clacky::PlatformHttpClient.new
    result = client.post("/api/v1/device/authorize", {
      device_id:   binding_device_id,
      device_info: { os: RUBY_PLATFORM, hostname: Socket.gethostname, app_version: Clacky::VERSION }
    })

    error!(result[:error] || "could not start authorization", status: 502) unless result[:success]

    data = result[:data]
    json(
      ok:                        true,
      device_code:               data["device_code"],
      user_code:                 data["user_code"],
      verification_uri:          data["verification_uri"],
      verification_uri_complete: data["verification_uri_complete"],
      interval:                  data["interval"] || 5
    )
  end

  # POST /api/ext/ext-studio/binding/poll  { device_code }
  # Polls the platform once. On approval, binds the issued device token to the
  # local Identity so subsequent publishes authenticate as the platform account.
  post "/binding/poll" do
    device_code = presence(json_body["device_code"])
    error!("device_code required", status: 422) unless device_code

    client = Clacky::PlatformHttpClient.new
    result = client.post("/api/v1/device/token", { device_code: device_code })
    data   = result[:data] || {}
    status = data["status"]

    if result[:success] && status == "approved"
      Clacky::Identity.load.bind!(
        device_token: data["device_token"],
        user_id:      data["user_id"]
      ) if data["device_token"]
      json(ok: true, status: "approved")
    elsif status == "pending"
      json(ok: true, status: "pending")
    else
      json(ok: false, status: status || "error", error: result[:error])
    end
  end

  private def local_containers(result)
    Array(result.containers).select { |_id, c| c[:layer] == :local }
  end

  private def serialize_container(ext_id, container, result, issues)
    raw = container[:raw] || {}
    ext_issues = issues.select { |i| i.ext == ext_id }
    dir = container[:dir]
    ext_units = result.units.select { |u| u.ext_id == ext_id }
    panels = Array((raw["contributes"] || {})["panels"])
    entry_points = panels.flat_map do |p|
      Array(p["entry_points"]).map { |ep| { panel_id: p["id"], slot: ep["slot"] } }
    end
    readme_path    = File.join(dir, "README.md")
    readme_content = File.exist?(readme_path) ? File.read(readme_path, encoding: "utf-8").strip : nil
    readme_content = nil if readme_content&.empty?
    {
      id: ext_id,
      name: raw["name"] || ext_id,
      description: raw["description"],
      version: raw["version"],
      origin: container[:origin],
      layer: container[:layer].to_s,
      dir: dir,
      mtime: File.mtime(File.join(dir, "ext.yml")).to_i,
      units: ext_units.map { |u| serialize_unit(u) },
      unit_counts: unit_counts(ext_units),
      contributes: raw["contributes"] || {},
      entry_points: entry_points,
      readme: readme_content,
      error_count: ext_issues.count { |i| i.level == :error },
      warning_count: ext_issues.count { |i| i.level == :warning }
    }
  end

  private def serialize_unit(unit)
    { kind: unit.kind.to_s, id: unit.id, layer: unit.layer.to_s }
  end

  private def unit_counts(units)
    units.each_with_object({}) do |unit, counts|
      kind = unit.kind.to_s
      counts[kind] = (counts[kind] || 0) + 1
    end
  end

  private def serialize_issue(issue)
    {
      ext: issue.ext,
      unit: issue.unit,
      level: issue.level.to_s,
      code: issue.code,
      message: issue.message,
      file: issue.file,
      hint: issue.hint
    }
  end

  private def require_ext_id!
    id = json_body["ext_id"].to_s.strip
    error!("ext_id required", status: 422) if id.empty?
    id
  end

  private def presence(value)
    str = value.to_s.strip
    str.empty? ? nil : str
  end

  # Stable per-machine id for the device-authorization flow. Matches the
  # onboarding device_id so binding reuses the same device row on the platform.
  private def binding_device_id
    components = [Socket.gethostname, ENV["USER"] || ENV["USERNAME"] || "", RUBY_PLATFORM]
    Digest::SHA256.hexdigest(components.join(":"))
  end
end
