# frozen_string_literal: true

# Standalone flock holder used by Server::Master single-instance lock specs.
#
# It is intentionally launched detached (reparented to init) rather than as a
# direct child of the rspec process: POSIX record locks are associated with the
# process, and a holder spawned directly under the test inherits the parent's
# lock relationships, which cannot model two servers started independently
# from separate shells. The launcher backgrounds this through /bin/sh so the
# holder has no kinship with the test.
#
# Arguments:
#   lock_path  - file to flock(LOCK_EX)
#   ready_path - written "locked" / "busy" once the flock attempt settles
#   pid_path   - written with the holder's own pid after the lock is acquired
#   mode       - "normal" (TERM kills us) or "ignore-term" (swallow SIGTERM)
require "fcntl"

lock_path, ready_path, pid_path, mode = ARGV
Signal.trap("TERM") {} if mode == "ignore-term"

lock_file = File.open(lock_path, File::RDWR | File::CREAT, 0o600)
locked = lock_file.flock(File::LOCK_EX | File::LOCK_NB) == 0
File.write(ready_path, locked ? "locked" : "busy")
exit 1 unless locked

lock_file.rewind
lock_file.truncate(0)
lock_file.write(Process.pid.to_s)
lock_file.flush
File.write(pid_path, Process.pid.to_s)

# Keep the lock held until the test kills us.
sleep 120
