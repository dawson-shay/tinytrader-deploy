# A launchd job's argv, started only once the Nix store is mounted: the same
# as tinytrader's lib.launchd.waitForNix (its infra/lib/launchd.nix), for the
# jobs these modules define with their own ProgramArguments. At boot launchd
# may start a job before /nix is mounted; the exec fails, launchd marks it
# EX_CONFIG (78) and never retries it, KeepAlive or not (2026-11-01).
argv:
[
  "/bin/sh"
  "-c"
  "/bin/wait4path /nix/store && exec \"$@\""
  "wait4path"
]
++ argv
