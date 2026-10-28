# frozen_string_literal: true

require "open3"
require "base64"
require "digest"
require "json"
require_relative "environment_detector"
require_relative "encoding"

module Clacky
  module Utils
    # Detects installed Windows applications able to open a given file type.
    #
    # Windows file associations live in the registry (HKEY_CLASSES_ROOT / the
    # per-user FileExts tree) rather than in app bundles, so this module shells
    # out to PowerShell to read them. The result set mirrors what the Explorer
    # "Open with" dialog offers: the user's default handler, the ProgIDs that
    # declared support for the extension, and the user's recent "open with"
    # choices. Desktop apps resolve to their .exe; packaged (UWP/Store) apps
    # resolve to their AppUserModelID and are launched via shell:appsFolder.
    # Non-WSL hosts always answer with an empty list.
    module WindowsAppDetector
      # `$Ext` is injected as a single-quoted literal after sanitisation, so it
      # is safe to interpolate. Writes UTF-8 so Chinese app names survive the
      # pipe (PowerShell 5.1 would otherwise emit the OEM codepage).
      DETECT_SCRIPT = <<~'PWSH'
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $ErrorActionPreference = "SilentlyContinue"
        $Ext = '__CLACKY_EXT__'

        function Parse-ExePath([string]$cmd) {
            if ([string]::IsNullOrWhiteSpace($cmd)) { return $null }
            $cmd = $cmd.Trim()
            if ($cmd.Length -eq 0) { return $null }
            $exe = $null
            if ($cmd[0] -eq '"') {
                $end = $cmd.IndexOf('"', 1)
                if ($end -gt 1) { $exe = $cmd.Substring(1, $end - 1) }
            } else {
                $idx = $cmd.IndexOf(' ')
                if ($idx -lt 0) { $idx = $cmd.IndexOf("`t") }
                if ($idx -gt 0) { $exe = $cmd.Substring(0, $idx) } else { $exe = $cmd }
            }
            if ($exe) { $exe = [Environment]::ExpandEnvironmentVariables($exe) }
            return $exe
        }

        function Get-DefaultValue([string]$keyPath) {
            $p = Get-Item -Path $keyPath -ErrorAction SilentlyContinue
            if ($p) { return $p.GetValue("") }
            return $null
        }

        $nameMap = @{}
        Get-StartApps -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.AppID) { $nameMap[$_.AppID] = $_.Name }
        }

        $ext = $Ext.TrimStart('.').ToLower()
        $script:apps = @()
        $script:defaultApp = $null
        $script:seen = @{}

        function Add-App([string]$launch, [string]$name, [bool]$isDefault) {
            if ([string]::IsNullOrWhiteSpace($launch)) { return }
            # A bare .exe name (no directory) is a stale or PATH-only reference.
            # Resolve it against PATH / App Paths so both launching and icon
            # extraction work; skip the entry when it can't be resolved.
            if ($launch -match '(?i)\.exe$' -and $launch -notmatch '[\\/]') {
                $resolved = (Get-Command $launch -ErrorAction SilentlyContinue | Select-Object -First 1).Source
                if (-not $resolved) {
                    $resolved = Get-DefaultValue "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$launch"
                }
                if ([string]::IsNullOrWhiteSpace($resolved) -or -not (Test-Path $resolved)) { return }
                $launch = $resolved
            }
            $key = $launch.ToLower()
            if ($script:seen.ContainsKey($key)) { return }
            $script:seen[$key] = $true
            if ([string]::IsNullOrWhiteSpace($name)) {
                if ($script:nameMap.ContainsKey($launch)) {
                    $name = $script:nameMap[$launch]
                } elseif ($launch -match '\.exe$') {
                    $name = [System.IO.Path]::GetFileNameWithoutExtension($launch)
                } else {
                    $name = ($launch -split '!')[0]
                }
            }
            $entry = @{ name = $name; path = $launch }
            $script:apps += $entry
            if ($isDefault -and -not $script:defaultApp) { $script:defaultApp = $entry }
        }

        function Add-ProgId([string]$progid, [bool]$isDefault) {
            if ([string]::IsNullOrWhiteSpace($progid)) { return }
            $cmdKey = "Registry::HKEY_CLASSES_ROOT\$progid\shell\open\command"
            $cmdItem = Get-Item -Path $cmdKey -ErrorAction SilentlyContinue
            $exe = if ($cmdItem) { Parse-ExePath ([string]$cmdItem.GetValue("")) } else { $null }
            $name = Get-DefaultValue "Registry::HKEY_CLASSES_ROOT\$progid"

            # Desktop app: a real exe outside the packaged-apps directory.
            if ($exe -and $exe -notmatch '\\WindowsApps\\') {
                Add-App $exe ([string]$name) $isDefault
                return
            }
            # Packaged (UWP) app: launch via its AppUserModelID; the packaged
            # exe under WindowsApps cannot be launched directly.
            $appItem = Get-Item "Registry::HKEY_CLASSES_ROOT\$progid\Application" -ErrorAction SilentlyContinue
            $aumid = if ($appItem) { [string]$appItem.GetValue("AppUserModelID") } else { $null }
            if ($aumid) {
                Add-App $aumid ([string]$name) $isDefault
            }
        }

        $ucItem = Get-Item "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.$ext\UserChoice" -ErrorAction SilentlyContinue
        $userChoice = if ($ucItem) { $ucItem.GetValue("ProgId") } else { $null }
        if ($userChoice) { Add-ProgId ([string]$userChoice) $true }

        $defaultProg = Get-DefaultValue "Registry::HKEY_CLASSES_ROOT\.$ext"
        if ($defaultProg -and $defaultProg -ne $userChoice) { Add-ProgId ([string]$defaultProg) $true }

        $hkcr = Get-Item "Registry::HKEY_CLASSES_ROOT\.$ext\OpenWithProgids" -ErrorAction SilentlyContinue
        if ($hkcr) { foreach ($p in $hkcr.Property) { Add-ProgId ([string]$p) $false } }

        $hkcu = Get-Item "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.$ext\OpenWithProgids" -ErrorAction SilentlyContinue
        if ($hkcu) { foreach ($p in $hkcu.Property) { Add-ProgId ([string]$p) $false } }

        $owList = Get-Item "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.$ext\OpenWithList" -ErrorAction SilentlyContinue
        if ($owList) {
            foreach ($p in $owList.Property) {
                if ($p -eq 'MRUList') { continue }
                $exeName = [string]$owList.GetValue($p)
                if ([string]::IsNullOrWhiteSpace($exeName)) { continue }
                if ($exeName -match '!') {
                    Add-App $exeName $null $false
                } else {
                    $cmd  = Get-DefaultValue "Registry::HKEY_CLASSES_ROOT\Applications\$exeName\shell\open\command"
                    $exe  = Parse-ExePath ([string]$cmd)
                    if (-not $exe) { $exe = $exeName }
                    $name = Get-DefaultValue "Registry::HKEY_CLASSES_ROOT\Applications\$exeName"
                    Add-App $exe ([string]$name) $false
                }
            }
        }

        # No explicit default handler: fall back to the first candidate so the
        # "Open" button still shows a real app logo instead of a generic icon.
        if (-not $script:defaultApp -and $script:apps.Count -gt 0) {
            $script:defaultApp = $script:apps[0]
        }

        @{ apps = $script:apps; default = $script:defaultApp } | ConvertTo-Json -Depth 4
      PWSH

      # Extracts the associated icon of an app as base64 PNG on stdout. Accepts
      # either a desktop .exe path or a packaged (UWP) AUMID; an AUMID is
      # resolved to the package's executable via its AppxManifest before the
      # icon is read. `$Target` is injected as a single-quoted literal (embedded
      # single quotes are doubled) so a value cannot break out of the script.
      ICON_SCRIPT = <<~'PWSH'
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $ErrorActionPreference = "SilentlyContinue"
        $Target = '__CLACKY_TARGET__'

        $exe = $null
        if ($Target -match '\.exe$') {
            $exe = $Target
        } else {
            $parts = $Target -split '!', 2
            $family = $parts[0]
            $appId = if ($parts.Count -gt 1) { $parts[1] } else { $null }
            $pkg = Get-AppxPackage | Where-Object { $_.PackageFamilyName -eq $family } | Select-Object -First 1
            if ($pkg) {
                $manifest = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
                [xml]$xml = Get-Content $manifest
                if ($xml -and $xml.Package -and $xml.Package.Applications) {
                    $app = $null
                    foreach ($a in $xml.Package.Applications.Application) {
                        if ($appId -and $a.Id -eq $appId) { $app = $a; break }
                    }
                    if (-not $app) { $app = $xml.Package.Applications.Application | Select-Object -First 1 }
                    if ($app -and $app.Executable) { $exe = Join-Path $pkg.InstallLocation $app.Executable }
                }
            }
        }
        if (-not $exe -or -not (Test-Path $exe)) { exit 1 }

        try {
            Add-Type -AssemblyName System.Drawing
            $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exe)
            if (-not $icon) { exit 1 }
            $bmp = $icon.ToBitmap()
            $ms = New-Object System.IO.MemoryStream
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            [Convert]::ToBase64String($ms.ToArray())
        } catch {
            exit 1
        }
      PWSH

      DETECT_MUTEX = Mutex.new

      # @param ext [String] file extension, with or without leading dot
      # @return [Array<Hash>] [{ "name" => ..., "path" => exe path or AUMID }]
      def self.apps_for_ext(ext)
        return [] unless wsl?

        ext = normalize_ext(ext)
        return [] if ext.empty?

        data = detect_for_ext(ext)
        data ? data["apps"] : []
      end

      # Return the application Windows would use to open `path`.
      # @param path [String] absolute file path
      # @return [Hash, nil] { "name" => ..., "path" => exe path or AUMID }
      def self.default_app_for(path)
        return nil unless wsl?

        ext = normalize_ext(File.extname(path))
        # Windows has no extension to look up for a Dockerfile or Makefile;
        # ask what handles plain text instead of reporting nothing.
        ext = "txt" if ext.empty?

        data = detect_for_ext(ext)
        data ? data["default"] : nil
      end

      # Open a file with a specific installed application.
      # @param path [String] absolute Linux-side file path
      # @param app [String] app name or path from /api/file/apps
      # @return [Boolean, nil] system() result, nil when the app is unknown
      def self.open_with(path, app)
        return nil unless wsl?

        app = app.to_s
        return nil if app.empty?

        target = resolve_target(path, app)
        return nil unless target

        if aumid?(target)
          # explorer.exe hands the launch off to the shell and always exits
          # non-zero, so the exit status cannot signal success — fire-and-forget.
          system("explorer.exe", "shell:appsFolder\\#{target}")
          true
        else
          win_path = Utils::EnvironmentDetector.linux_to_win_path(path)
          system("cmd.exe", "/c", "start", "", target, win_path)
        end
      end

      # Convert an app's icon to a cached PNG. Accepts a desktop .exe path or a
      # packaged (UWP) AUMID; the AUMID is resolved to the package exe inside
      # the PowerShell script. Answers nil when no icon can be extracted.
      # @param target [String] Windows .exe path or AppUserModelID
      # @return [String, nil] path to the cached PNG file
      def self.icon_png(target)
        return nil unless wsl?

        target = target.to_s
        return nil if target.empty?

        cache_dir = File.join(Dir.home, ".clacky", "cache", "app-icons")
        cache = File.join(cache_dir, Digest::MD5.hexdigest(target) + ".png")
        return cache if File.exist?(cache)

        out, _err, status = run_encoded(ICON_SCRIPT.sub("__CLACKY_TARGET__", target.gsub("'", "''")))
        return nil unless status.success?
        b64 = out.strip
        return nil if b64.empty?

        require "fileutils"
        FileUtils.mkdir_p(cache_dir)
        File.binwrite(cache, Base64.decode64(b64))
        File.exist?(cache) ? cache : nil
      end

      def self.wsl?
        Utils::EnvironmentDetector.os_type == :wsl
      end

      # Strips to [a-z0-9] so the value can never break out of the
      # single-quoted `$Ext` literal inside DETECT_SCRIPT.
      def self.normalize_ext(ext)
        ext.to_s.downcase.sub(/\A\./, "").gsub(/[^a-z0-9]/, "")
      end

      def self.detect_for_ext(ext)
        @detect_cache ||= {}
        return @detect_cache[ext] if @detect_cache.key?(ext)

        # powershell.exe takes 1-3s to spawn on WSL; the mutex keeps concurrent
        # /api/file/apps + /api/file/default-app requests from launching a
        # duplicate process for the same extension.
        DETECT_MUTEX.synchronize do
          return @detect_cache[ext] if @detect_cache.key?(ext)

          out, _err, status = run_encoded(DETECT_SCRIPT.sub("__CLACKY_EXT__", ext))
          parsed = begin
            JSON.parse(out.sub(/\A\xEF\xBB\xBF/, ""))
          rescue StandardError
            nil
          end
          @detect_cache[ext] = status.success? && parsed.is_a?(Hash) ? parsed : nil
        end
      end

      # The app must match an entry returned by /api/file/apps for this file
      # type, mirroring MacAppDetector's all_apps whitelist — a caller
      # supplied exe path or AUMID is never trusted directly.
      def self.resolve_target(path, app)
        ext = normalize_ext(File.extname(path))
        data = detect_for_ext(ext)
        return nil unless data

        match = data["apps"].find { |a| a["name"] == app || a["path"] == app }
        match && match["path"]
      end

      def self.aumid?(target)
        target.to_s.include?("!") && target.to_s !~ /\.exe\z/i
      end

      def self.run_encoded(script)
        encoded = Base64.strict_encode64(script.encode("UTF-16LE"))
        out, err, status = Open3.capture3("powershell.exe", "-NoProfile", "-EncodedCommand", encoded)
        # The script forces UTF-8 output, but capture3 tags the bytes with the
        # host locale (US-ASCII under LANG=C), which makes JSON.parse choke on
        # non-ASCII app names — retag before the caller parses.
        [Clacky::Utils::Encoding.cmd_to_utf8(out, source_encoding: "UTF-8"), err, status]
      end
    end
  end
end
