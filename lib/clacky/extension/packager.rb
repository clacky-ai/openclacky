# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "open-uri"
require "psych"
require "zip"

module Clacky
  # Packs a local extension container into a distributable zip, and installs a
  # zip (local path or URL) into the `installed` layer.
  #
  # These are the local halves of the publish/marketplace flow: `pack` produces
  # the artifact that later gets uploaded, `install` is what a download performs.
  # Both are pure filesystem operations with no network dependency beyond the
  # optional URL fetch in `install`.
  module ExtensionPackager
    MANIFEST     = "ext.yml"
    MAX_ZIP_SIZE = 80 * 1024 * 1024

    # Network timeouts for the download step. `read_timeout` is an *idle*
    # timeout (resets on every chunk received), so a stalled connection with
    # no new bytes flowing for this long is treated as dead — not a "download
    # still going, just slow" situation, which large files on a slow link
    # would otherwise trigger.
    OPEN_TIMEOUT = 15   # seconds to establish the connection
    READ_TIMEOUT = 60   # seconds of silence before giving up mid-download

    # Platform metadata that leaks in from the developer's OS; never ship it.
    SYSTEM_METADATA = [".DS_Store", "__MACOSX", "Thumbs.db", "desktop.ini"].freeze

    # VCS and IDE metadata that must never ship in a pack, even without a .gitignore.
    NEVER_PACK_DIRS = [".git", ".svn", ".hg", ".idea", ".vscode"].freeze

    Result = Struct.new(:ext_id, :path, :units, keyword_init: true)

    class Error < StandardError; end

    class << self
      # Zip up a single container from the local layer into `out_dir`.
      # Runs verify first (blocking on errors) and refuses protected/encrypted
      # units — those are produced by the platform's encryption pipeline, not
      # hand-packed. Returns a Result with the produced zip path.
      def pack(ext_id, source_dir: Clacky::ExtensionLoader::LOCAL_DIR, out_dir: Dir.pwd)
        slug = ext_id.to_s.strip
        raise Error, "invalid extension id: #{ext_id.inspect}" if slug.empty?

        container_dir = File.join(source_dir, slug)
        unless File.directory?(container_dir) && File.file?(File.join(container_dir, MANIFEST))
          raise Error, "no container found at #{container_dir} (expected #{MANIFEST})"
        end

        refuse_id_folder_mismatch!(slug, container_dir)
        verify_container!(slug, container_dir)
        refuse_protected!(slug, container_dir)

        FileUtils.mkdir_p(out_dir)
        zip_path = File.join(out_dir, "#{slug}.zip")
        File.delete(zip_path) if File.exist?(zip_path)

        write_zip(container_dir, zip_path)
        enforce_zip_size!(zip_path)

        Result.new(ext_id: slug, path: zip_path, units: nil)
      end

      # Install a packed container into the `installed` layer. `source` is a
      # local zip path or an http(s) URL. Validates the archive (single top
      # container with an ext.yml, no path traversal), extracts it, then runs
      # verify on the resolved installed layer.
      # on_progress is an optional callable that receives a stage hash, e.g.:
      #   { stage: "downloading", progress: 45 }
      #   { stage: "extracting" }
      #   { stage: "verifying" }
      # Caller can use this for progress reporting without coupling to internals.
      def install(source, installed_dir: Clacky::ExtensionLoader::INSTALLED_DIR, force: false, on_progress: nil)
        Dir.mktmpdir("clacky-ext-install") do |tmp|
          on_progress&.call({ stage: "downloading", progress: 0 })
          zip_path = local_zip_for(source, tmp, on_progress: on_progress)

          on_progress&.call({ stage: "extracting" })
          extract_root = File.join(tmp, "unpacked")
          FileUtils.mkdir_p(extract_root)
          extract_zip(zip_path, extract_root)

          ext_id, container_src = locate_container(extract_root)

          target = File.join(installed_dir, ext_id)
          if Dir.exist?(target) && !force
            raise Error, "extension #{ext_id.inspect} already installed at #{target} (pass force: true to overwrite)"
          end

          FileUtils.mkdir_p(target)
          FileUtils.cp_r(Dir.glob("#{container_src}/*"), target)

          on_progress&.call({ stage: "verifying" })
          Clacky::ExtensionLoader.invalidate_cache!
          units = verify_installed(ext_id, installed_dir)

          Result.new(ext_id: ext_id, path: target, units: units)
        end
      end

      # Install from raw zip bytes (e.g. a multipart upload). Validates the
      # filename/size, writes the bytes to a temp file inside a mktmpdir, then
      # delegates to install(). The temp file lives for the whole install
      # (extract reads it) and is cleaned up on return.
      def install_bytes(data, filename: nil, **opts)
        unless data.is_a?(String) && !data.empty?
          raise Error, "empty upload"
        end
        unless filename.to_s.downcase.end_with?(".zip")
          raise Error, "please upload a .zip file"
        end
        if data.bytesize > MAX_ZIP_SIZE
          raise Error, "upload exceeds #{MAX_ZIP_SIZE / 1024 / 1024}MB limit"
        end

        Dir.mktmpdir("clacky-ext-import") do |dir|
          zip_path = File.join(dir, "upload.zip")
          File.binwrite(zip_path, data)
          install(zip_path, **opts)
        end
      end

      # Verify only the target container in isolation: symlink it into a temp
      # root so sibling containers in the real local dir don't pollute the run.
      private def verify_container!(slug, container_dir)
        Dir.mktmpdir("clacky-ext-verify") do |root|
          FileUtils.ln_s(File.expand_path(container_dir), File.join(root, slug))
          result = Clacky::ExtensionLoader.load_all(layers: { local: root }, force: true)
          issues = Clacky::ExtensionVerifier.verify(result)
          errors = issues.select { |i| i.level == :error && i.ext == slug }
          next if errors.empty?

          detail = errors.map { |e| "  - #{e.code}: #{e.message}" }.join("\n")
          raise Error, "cannot pack #{slug}: verify found errors:\n#{detail}"
        end
      ensure
        Clacky::ExtensionLoader.invalidate_cache!
      end

      # The container's identity must be the same on both sides of the publish
      # boundary: the client keys extensions by folder name, the marketplace
      # keys them by ext.yml `id`. If they diverge, a rename on one side alone
      # lets a container masquerade under a name the uniqueness check never saw.
      private def refuse_id_folder_mismatch!(slug, container_dir)
        manifest = File.join(container_dir, MANIFEST)
        data     = Psych.safe_load(File.read(manifest), permitted_classes: [], aliases: true) || {}
        declared = data["id"].to_s.strip
        return if declared == slug

        raise Error,
              "extension id mismatch: folder is '#{slug}' but #{MANIFEST} declares id '#{declared}'. " \
              "Rename the folder or the id so they match before packing."
      end

      # Packing is for authored (open) containers. Anything already protected or
      # carrying encrypted skills is produced by the platform pipeline; refuse
      # to re-pack it so we never smuggle marketplace artifacts out of band.
      private def refuse_protected!(slug, container_dir)
        enc = Dir.glob(File.join(container_dir, "**", "SKILL.md.enc"))
        return if enc.empty?

        raise Error, "refusing to pack #{slug}: contains encrypted skill(s): #{enc.map { |p| relative(container_dir, p) }.join(', ')}"
      end

      private def write_zip(container_dir, zip_path)
        gitignore = load_container_gitignore(container_dir)
        Zip::File.open(zip_path, create: true) do |zip|
          each_packable(container_dir, gitignore) do |abs|
            rel = relative(container_dir, abs)
            next if system_metadata?(rel)

            entry = File.join(File.basename(container_dir), rel)
            if File.directory?(abs)
              zip.mkdir(entry) unless zip.find_entry(entry)
            else
              zip.add(entry, abs)
            end
          end
        end
      end

      # Same budget the installer enforces on download/extract - without it a
      # creator could publish something no one (themselves included) can install.
      private def enforce_zip_size!(zip_path)
        size = File.size(zip_path)
        return if size <= MAX_ZIP_SIZE

        raise Error, "packed zip is #{size} bytes, exceeds #{MAX_ZIP_SIZE} bytes (#{MAX_ZIP_SIZE / 1024 / 1024}MB) limit"
      end

      private def load_container_gitignore(container_dir)
        path = File.join(container_dir, ".gitignore")
        Clacky::GitignoreParser.new(path) if File.exist?(path)
      end

      # Walk the container yielding every path that should ship. Honors .gitignore
      # strictly: ignored files are excluded even when they are config files
      # (.env, secrets) - packing must never leak gitignored content, unlike the
      # search tools which surface config files. Nested .gitignore files are
      # honored per-subtree without leaking rules into sibling directories.
      private def each_packable(dir, gitignore, root: dir)
        Dir.children(dir).sort.each do |name|
          full = File.join(dir, name)
          rel = relative(root, full)

          if File.directory?(full)
            next if File.symlink?(full)
            next if NEVER_PACK_DIRS.include?(name)
            next if gitignore&.ignored?("#{rel}/")

            yield full
            each_packable(full, gitignore_for_subdir(full, rel, gitignore), root: root) { |p| yield p }
          else
            next if gitignore&.ignored?(rel)

            yield full
          end
        end
      end

      private def gitignore_for_subdir(dir, rel, parent)
        nested = File.join(dir, ".gitignore")
        return parent unless File.exist?(nested)

        merged = parent ? parent.dup : Clacky::GitignoreParser.new(nil)
        merged.merge!(nested, prefix: rel)
        merged
      end

      # True if any path segment is a platform metadata file/dir (e.g. a nested
      # agents/.DS_Store or a whole __MACOSX/ tree).
      private def system_metadata?(rel)
        rel.split(File::SEPARATOR).any? { |seg| SYSTEM_METADATA.include?(seg) }
      end

      private def local_zip_for(source, tmp, on_progress: nil)
        src = source.to_s
        if src.match?(%r{\Ahttps?://})
          dest = File.join(tmp, "download.zip")
          download(src, dest, on_progress: on_progress)
          dest
        else
          path = File.expand_path(src)
          raise Error, "zip not found: #{path}" unless File.file?(path)
          path
        end
      end

      # Download url → dest file.
      # IMPORTANT: OpenURI's block form (`URI.open(url) { |io| ... }`) buffers
      # the *entire* response into a StringIO/Tempfile via Net::HTTP's
      # read_body before ever yielding `io` — so reading `io` in chunks after
      # the fact reports progress only after the download has already
      # finished. To get progress callbacks that fire while bytes are still
      # arriving on the socket, we hook OpenURI's own `progress_proc` /
      # `content_length_proc`, which run inside read_body as each chunk lands.
      # Respects whatever proxy env vars the user has configured (some CDN
      # domains are only reachable at usable speed through a proxy).
      private def download(url, dest, on_progress: nil)
        content_length = nil

        content_length_proc = lambda do |len|
          content_length = len if len&.positive?
        end

        progress_proc = lambda do |size|
          raise Error, "download exceeds #{MAX_ZIP_SIZE} bytes" if size > MAX_ZIP_SIZE
          next unless on_progress

          pct = if content_length&.positive?
                  [(size * 100 / content_length).floor, 99].min
                else
                  (90 - 90 * Math.exp(-size.to_f / (1024 * 1024))).floor
                end
          on_progress.call({ stage: "downloading", progress: pct })
        end

        URI.open(
          url, "rb",
          open_timeout: OPEN_TIMEOUT,
          read_timeout: READ_TIMEOUT,
          content_length_proc: content_length_proc,
          progress_proc: progress_proc
        ) do |io| # rubocop:disable Security/Open
          File.open(dest, "wb") { |out| out.write(io.read) }
        end
      rescue OpenURI::HTTPError, SocketError => e
        raise Error, "failed to download #{url}: #{e.message}"
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        raise Error, "download timed out: #{e.message}"
      end

      private def extract_zip(zip_path, dest_root)
        total = 0
        Zip::File.open(zip_path) do |zip|
          zip.each do |entry|
            safe = safe_join(dest_root, entry.name)
            total += entry.size.to_i
            raise Error, "archive expands beyond #{MAX_ZIP_SIZE} bytes" if total > MAX_ZIP_SIZE

            if entry.directory?
              FileUtils.mkdir_p(safe)
            else
              FileUtils.mkdir_p(File.dirname(safe))
              File.binwrite(safe, entry.get_input_stream.read)
            end
          end
        end
      end

      # Reject zip-slip: the resolved path must stay inside dest_root.
      private def safe_join(dest_root, name)
        path = File.expand_path(File.join(dest_root, name))
        root = File.expand_path(dest_root)
        unless path == root || path.start_with?("#{root}#{File::SEPARATOR}")
          raise Error, "unsafe path in archive: #{name.inspect}"
        end
        path
      end

      # A valid archive holds exactly one top-level directory that is the
      # container (has ext.yml). Returns [ext_id, absolute_container_dir].
      private def locate_container(root)
        children = Dir.children(root).reject { |c| c.start_with?(".") }
        dirs = children.select { |c| File.directory?(File.join(root, c)) }

        if File.file?(File.join(root, MANIFEST))
          id = manifest_id(File.join(root, MANIFEST))
          raise Error, "archive has no top-level container and #{MANIFEST} declares no id" if id.empty?
          return [id, root]
        end

        if dirs.size == 1 && File.file?(File.join(root, dirs.first, MANIFEST))
          return [dirs.first, File.join(root, dirs.first)]
        end

        raise Error, "archive does not contain a single container with #{MANIFEST}"
      end

      private def manifest_id(manifest_path)
        data = YAMLCompat.load_file(manifest_path)
        data.is_a?(Hash) ? data["id"].to_s.strip : ""
      rescue StandardError
        ""
      end

      private def verify_installed(ext_id, installed_dir)
        layers =
          if installed_dir == Clacky::ExtensionLoader::INSTALLED_DIR
            Clacky::ExtensionLoader.default_layers
          else
            { installed: installed_dir }
          end
        result = Clacky::ExtensionLoader.load_all(layers: layers, force: true)
        issues = Clacky::ExtensionVerifier.verify(result)
        errors = issues.select { |i| i.level == :error && i.ext == ext_id }
        unless errors.empty?
          detail = errors.map { |e| "  - #{e.code}: #{e.message}" }.join("\n")
          raise Error, "installed #{ext_id} but verify found errors:\n#{detail}"
        end
        result.units.select { |u| u.ext_id == ext_id }
      end

      private def relative(base, abs)
        Pathname.new(abs).relative_path_from(Pathname.new(base)).to_s
      end
    end
  end
end
