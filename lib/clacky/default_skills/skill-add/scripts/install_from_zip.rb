#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'uri'
require 'net/http'
require 'find'

# Install a skill from a remote zip archive URL.
# Usage: ruby install_from_zip.rb <zip_url>
#
# The zip archive is expected to contain a skill directory at its root, e.g.:
#   my-skill/
#     SKILL.md
#     scripts/
#
# Or the archive may contain multiple skill directories (each with a SKILL.md).
class ZipSkillInstaller
  ZIP_URL_PATTERN = %r{^https?://.+\.zip(\?.*)?$}i

  def initialize(zip_url, skill_name: nil, target_dir: nil)
    @zip_url    = zip_url
    # skill_name can be provided explicitly (e.g. slug from the store API).
    # If not provided, we try to infer it from the filename in the URL, e.g.
    # "ui-ux-pro-max-1.0.0.zip" → "ui-ux-pro-max".
    @skill_name = skill_name || infer_skill_name_from_url(zip_url)
    @target_dir = target_dir || File.join(Dir.pwd, '.clacky', 'skills')
    @installed_skills = []
    @errors = []
  end

  # Main installation entry point.
  def install
    unless valid_zip_url?
      raise ArgumentError, "Invalid zip URL: #{@zip_url}\nURL must be an http(s) address ending with .zip"
    end

    Dir.mktmpdir('clacky-zip-') do |tmpdir|
      zip_path = download_zip(tmpdir)
      extract_zip(zip_path, tmpdir)
      extracted_dir = File.join(tmpdir, 'extracted')
      discover_and_install_skills(extracted_dir)
    end

    report_results
  rescue ArgumentError => e
    puts "❌ #{e.message}"
    exit 1
  rescue StandardError => e
    puts "❌ Installation failed: #{e.message}"
    exit 1
  end

  # Infer a skill name from the zip filename, stripping version suffixes.
  # e.g. "ui-ux-pro-max-1.0.0.zip" → "ui-ux-pro-max"
  private def infer_skill_name_from_url(url)
    filename = File.basename(URI.parse(url).path, '.zip') rescue File.basename(url, '.zip')
    # Strip trailing version segment like "-1.0.0" or "-2.3"
    filename.sub(/-\d+(\.\d+)+$/, '')
  end

  private def valid_zip_url?
    @zip_url.match?(ZIP_URL_PATTERN)
  end

  # Download the zip file to tmpdir and return its local path.
  private def download_zip(tmpdir)
    puts "⬇️  Downloading skill package..."
    puts "   #{@zip_url}"

    zip_path = File.join(tmpdir, 'skill.zip')
    uri = URI.parse(@zip_url)

    # Follow redirects up to 5 times (ActiveStorage often redirects).
    max_redirects = 5
    current_uri = uri

    max_redirects.times do
      Net::HTTP.start(current_uri.host, current_uri.port,
                      use_ssl: current_uri.scheme == 'https',
                      open_timeout: 15, read_timeout: 60) do |http|
        request = Net::HTTP::Get.new(current_uri.request_uri)
        http.request(request) do |response|
          case response.code.to_i
          when 200
            File.open(zip_path, 'wb') { |f| response.read_body { |chunk| f.write(chunk) } }
            return zip_path
          when 301, 302, 303, 307, 308
            location = response['location']
            raise "Redirect loop or missing Location header" if location.nil? || location == current_uri.to_s
            current_uri = URI.parse(location)
          else
            raise "HTTP #{response.code} while downloading #{@zip_url}"
          end
        end
      end
    end

    raise "Too many redirects downloading #{@zip_url}"
  end

  # Extract the zip archive into <tmpdir>/extracted/.
  private def extract_zip(zip_path, tmpdir)
    puts "📂 Extracting package..."
    extracted_dir = File.join(tmpdir, 'extracted')
    FileUtils.mkdir_p(extracted_dir)

    # Prefer the 'unzip' system command; fall back to Ruby's built-in zip support via ZipFile.
    if system('which', 'unzip', out: File::NULL, err: File::NULL)
      result = system('unzip', '-q', zip_path, '-d', extracted_dir)
      raise "unzip failed (exit code #{$?.exitstatus})" unless result
    else
      # Attempt to use the 'zip' gem if available, otherwise raise a clear error.
      begin
        require 'zip'
        Zip::File.open(zip_path) do |zip|
          zip.each do |entry|
            dest = File.join(extracted_dir, entry.name)
            FileUtils.mkdir_p(File.dirname(dest))
            entry.extract(dest)
          end
        end
      rescue LoadError
        raise "Cannot extract zip: 'unzip' command not found and 'zip' gem is not installed.\n" \
              "Install unzip (e.g. brew install unzip) and try again."
      end
    end
  end

  # Walk the extracted directory and install every skill (directory containing SKILL.md).
  # Supports two zip layouts:
  #   Layout A — SKILL.md at zip root (flat): extracted/SKILL.md
  #   Layout B — skill in subdirectory:       extracted/my-skill/SKILL.md
  private def discover_and_install_skills(extracted_dir)
    # Layout A: SKILL.md directly under the extraction root.
    if File.exist?(File.join(extracted_dir, 'SKILL.md'))
      install_skill(extracted_dir, skill_name: @skill_name)
      return
    end

    # Layout B: one or more skill subdirectories each containing SKILL.md.
    skill_dirs = Dir.glob(File.join(extracted_dir, '*/SKILL.md')).map { |f| File.dirname(f) }

    if skill_dirs.empty?
      raise "No SKILL.md found in the zip archive. " \
            "Make sure the package contains a valid skill directory."
    end

    skill_dirs.each { |dir| install_skill(dir) }
  end

  # Copy a single skill directory into the target skills folder.
  # skill_name overrides the directory basename (used for Layout A flat zips).
  private def install_skill(skill_src_dir, skill_name: nil)
    name        = skill_name || File.basename(skill_src_dir)
    target_path = File.join(@target_dir, name)

    if File.exist?(target_path)
      puts "♻️  Skill '#{name}' already exists — overwriting..."
      FileUtils.rm_rf(target_path)
    end

    FileUtils.mkdir_p(target_path)
    # Copy contents of skill_src_dir into target_path (not the dir itself).
    FileUtils.cp_r(Dir.glob("#{skill_src_dir}/*"), target_path)

    description = extract_description(File.join(target_path, 'SKILL.md'))
    @installed_skills << { name: name, path: target_path, description: description }
  rescue StandardError => e
    @errors << "Failed to install '#{name}': #{e.message}"
  end

  # Parse the description field from SKILL.md YAML frontmatter.
  private def extract_description(skill_file)
    return "No description" unless File.exist?(skill_file)

    content = File.read(skill_file)
    if content =~ /\A---\s*\n(.*?)\n---/m
      frontmatter = $1
      return $1.strip if frontmatter =~ /^description:\s*(.+)$/
    end

    "No description"
  rescue StandardError
    "No description"
  end

  # Print a human-readable summary of what was installed.
  private def report_results
    puts "\n" + "=" * 60

    if @installed_skills.empty?
      puts "❌ No skills were installed."
      if @errors.any?
        puts "\nErrors:"
        @errors.each { |e| puts "   • #{e}" }
      end
      exit 1
    end

    puts "✅ Installation complete!"
    puts "\nInstalled #{@installed_skills.size} skill(s):\n\n"
    @installed_skills.each do |skill|
      puts "   ✓ #{skill[:name]}"
      puts "     #{skill[:description]}"
      puts "     → #{skill[:path]}"
      puts
    end

    if @errors.any?
      puts "⚠️  Warnings:"
      @errors.each { |e| puts "   • #{e}" }
      puts
    end

    puts "You can now use these skills with /skill-name"
    puts "=" * 60
  end
end

# ── Entry point ────────────────────────────────────────────────────────────────
if __FILE__ == $0
  if ARGV.empty?
    puts "Usage: ruby install_from_zip.rb <zip_url> [skill_name]"
    puts "\nExamples:"
    puts "  ruby install_from_zip.rb https://example.com/my-skill-1.0.0.zip"
    puts "  ruby install_from_zip.rb https://example.com/my-skill-1.0.0.zip my-skill"
    exit 1
  end

  ZipSkillInstaller.new(ARGV[0], skill_name: ARGV[1]).install
end
