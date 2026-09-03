# frozen_string_literal: true

module Clacky
  module Server
    # Directory-picker quick-access places + WSL/Windows drive detection.
    # Extracted from HttpServer to keep the path/place helpers cohesive.
    module DirPicker
      # Windows "special" folders under C:\Users that aren't real user profiles.
      WINDOWS_PROFILE_DIRS = ["Public", "Default", "Default User", "All Users"].freeze

      # Sidebar quick-access favorites for the directory picker (Finder-style).
      # Translated client-side via `id`. On WSL every favorite targets the
      # Windows profile (/mnt/<drive>/Users/<name>/...) so they match where a
      # Windows browser actually saves files; elsewhere they stay under Dir.home.
      private def dir_picker_places
        home = Dir.home
        win_home = wsl_windows_home
        places = []

        [["home", win_home || home],
         ["desktop",   File.join(win_home || home, "Desktop")],
         ["downloads", File.join(win_home || home, "Downloads")],
         ["documents", File.join(win_home || home, "Documents")]].each do |id, path|
          places << { id: id, path: path, kind: "favorite" } if Dir.exist?(path)
        end

        places.concat(dir_picker_drives)
        places
      end

      # Drive letters exposed to the picker so Windows users can reach D:/E:/…
      # directly. Under WSL these are the /mnt/<drive> mounts; on native
      # Windows the actual drive letters. Empty on macOS/Linux.
      private def dir_picker_drives
        if wsl?
          mounts = "/mnt"
          return [] unless Dir.exist?(mounts)

          drives = []
          Dir.children(mounts).sort.each do |drive|
            next unless drive.match?(/\A[a-zA-Z]\z/)
            path = File.join(mounts, drive)
            next unless Dir.exist?(path)
            drives << { id: "drive_#{drive.downcase}", path: path, letter: drive.upcase, kind: "drive" }
          end
          drives
        elsif Gem.win_platform?
          drives = []
          ("A".."Z").each do |letter|
            path = "#{letter}:/"
            next unless Dir.exist?(path)
            drives << { id: "drive_#{letter.downcase}", path: path, letter: letter, kind: "drive" }
          end
          drives
        else
          []
        end
      end

      # True when running inside Windows Subsystem for Linux.
      private def wsl?
        return true if ENV["WSL_DISTRO_NAME"]
        return true if File.exist?("/proc/sys/fs/binfmt_misc/WSLInterop")
        version = begin
          File.read("/proc/version")
        rescue StandardError
          ""
        end
        version.downcase.include?("microsoft")
      end

      # Best-effort path to the Windows user profile under WSL, or nil when it
      # can't be determined (then callers fall back to Dir.home). Scans every
      # mounted drive's Users dir instead of assuming the system drive is C:.
      # Username sources are tried most-trusted first:
      #   1. WINDOWS_USERNAME / USERNAME env (explicitly set or WSLENV-forwarded)
      #   2. the live Windows %USERNAME%, read via cmd.exe interop
      #   3. USER (the WSL Linux username, which usually matches the Windows one)
      #   4. the first non-system profile dir found (last-resort guess)
      private def wsl_windows_home
        return nil unless wsl?

        roots = wsl_windows_users_roots
        wsl_profile_for(roots, ENV["WINDOWS_USERNAME"]) ||
          wsl_profile_for(roots, ENV["USERNAME"]) ||
          wsl_profile_for(roots, wsl_windows_username) ||
          wsl_profile_for(roots, ENV["USER"]) ||
          wsl_first_user_profile(roots)
      end

      # The first mounted profile dir named exactly `username`, or nil. WSL
      # never inherits Windows env vars by default, which is why `username`
      # may also come from cmd.exe interop rather than ENV.
      private def wsl_profile_for(roots, username)
        return nil if username.nil? || username.empty?

        roots.each do |root|
          candidate = File.join(root, username)
          return candidate if Dir.exist?(candidate)
        end
        nil
      end

      # Last-resort guess: the first non-system profile dir under any mounted
      # Users root. Filesystem enumeration order is arbitrary, so on
      # multi-profile machines this may pick an inactive profile — every
      # username source in wsl_windows_home exists to keep this unreached.
      private def wsl_first_user_profile(roots)
        roots.each do |root|
          profiles = Dir.children(root).select do |name|
            full = File.join(root, name)
            File.directory?(full) &&
              !WINDOWS_PROFILE_DIRS.include?(name) &&
              !name.start_with?(".")
          end
          return File.join(root, profiles.first) if profiles.any?
        end
        nil
      end

      # The live Windows-side %USERNAME%, read via cmd.exe interop. Returns
      # nil when interop is disabled or cmd.exe is unreachable; callers must
      # still validate against the mounted Users directory. Cached —
      # including failures — because interop availability doesn't change
      # within a process and the spawn otherwise costs 100ms+ on every
      # directory listing.
      private def wsl_windows_username
        return @wsl_windows_username if defined?(@wsl_windows_username)

        @wsl_windows_username = begin
          require "open3"
          out, _err, status = Open3.capture3("cmd.exe", "/c", "echo %USERNAME%", binmode: true)
          status.success? ? out.lines.first&.strip : nil
        rescue StandardError
          nil
        end
      end

      # Every mounted drive that exposes a Windows Users directory, e.g.
      # /mnt/c/Users and /mnt/d/Users.
      private def wsl_windows_users_roots
        mounts = "/mnt"
        return [] unless Dir.exist?(mounts)

        roots = []
        Dir.children(mounts).each do |drive|
          root = File.join(mounts, drive, "Users")
          roots << root if Dir.exist?(root)
        end
        roots
      end
    end
  end
end
