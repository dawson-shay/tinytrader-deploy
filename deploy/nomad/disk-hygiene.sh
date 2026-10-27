#!/bin/sh
# The disk-hygiene job's work (the site's deploy/nomad/jobs/disk-hygiene.nomad.hcl;
# docs/decisions/0016): frees a Mac's system disk of what builds and
# tools leave behind. Run natively (raw_exec) as the agent's user, after
# the gate. Each step logs what it removed and the bytes freed.
#
#   targets  Rust target/ directories under DISK_HYGIENE_ROOTS: a folder named
#            target beside a Cargo.toml, or holding cargo's CACHEDIR.TAG (a
#            shared CARGO_TARGET_DIR), with nothing in it modified for
#            DISK_HYGIENE_TARGET_DAYS days and nothing in it open (cargo
#            holds its build lock open for a whole build; rustc its outputs;
#            a running binary its executable). Per-repository targets
#            (~/.cache/cargo-target/<repo>/target) are targets like any other
#   nix      nix-collect-garbage --delete-older-than DISK_HYGIENE_NIX_DAYS d
#   docker   docker image prune -f and docker builder prune -f --filter
#            until=336h, where an engine answers and no auto-deploy holds
#            DISK_HYGIENE_DEPLOY_LOCK. Containers, networks and volumes stay
#
#   DISK_HYGIENE_ROOTS        "dir:dir": absolute, or relative to $HOME. Never
#                             under /Volumes; symlinks are not followed, and
#                             no other file system is entered
#   DISK_HYGIENE_DRY_RUN      1: say what would go, remove nothing (or --dry-run)
#   DISK_HYGIENE_TARGET_DAYS  7
#   DISK_HYGIENE_NIX_DAYS     14
#   DISK_HYGIENE_STEPS        "targets nix docker"
#   DISK_HYGIENE_DEPLOY_LOCK  auto-deploy's lock file (relative to $HOME, or
#                             absolute): open in a process means a deploy is on
set -eu
dry="${DISK_HYGIENE_DRY_RUN:-0}"
[ "${1:-}" = --dry-run ] && dry=1
days="${DISK_HYGIENE_TARGET_DAYS:-7}"
nix_days="${DISK_HYGIENE_NIX_DAYS:-14}"
steps="${DISK_HYGIENE_STEPS:-targets nix docker}"

say() { printf '%s disk-hygiene: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
case "$dry" in 0 | 1) ;; *) say "DISK_HYGIENE_DRY_RUN must be 0 or 1, not $dry"; exit 2 ;; esac
case "$days:$nix_days" in *[!0-9:]* | :* | *:) say "the days must be whole numbers"; exit 2 ;; esac
[ "$dry" = 1 ] && say "dry run: nothing is removed"

# The physical path of a folder (symlinks resolved), or nothing.
physical() { (cd -P -- "$1" 2>/dev/null && pwd -P) || true; }
avail() { df -Pk "$HOME" | awk 'NR == 2 { print $4 * 1024 }'; }
before="$(avail)"

# Every file open in a process this user can see, once per run (empty: lsof
# can't say, and everything counts as in use).
open="$(command -v lsof >/dev/null && lsof -n -P -w -F n 2>/dev/null || true)"
# 0 when a process has a file (or its cwd) in $1, or when that can't be told.
in_use() {
  [ -n "$open" ] || return 0
  printf '%s\n' "$open" | awk -v t="$1" '/^n/ { n = substr($0, 2); if (n == t || index(n, t "/") == 1) { f = 1; exit } } END { exit !f }'
}

# The pipeline's loop is a subshell: the bytes freed are counted in $tally.
clean_root() {
  case "$1" in /*) root="$1" ;; *) root="$HOME/$1" ;; esac
  real="$(physical "$root")"
  case "$root/:$real/" in
    /Volumes/* | *:/Volumes/*) say "$root: under /Volumes, never touched"; return ;;
  esac
  if [ -z "$real" ] || [ "$real" = / ]; then say "$root: not a folder (or the whole disk): skipped"; return; fi
  find "$real" -xdev -type d -name target -prune -print 2>/dev/null | while IFS= read -r t; do
    # Each one checked again on its own: a real folder inside the root.
    [ -d "$t" ] && [ ! -L "$t" ] && [ "$(physical "$t")" = "$t" ] || continue
    case "$t" in "$real"/*) ;; *) continue ;; esac
    if [ ! -f "${t%/target}/Cargo.toml" ] && ! grep -qs cargo "$t/CACHEDIR.TAG"; then continue; fi
    if ! recent="$(find "$t" -xdev -mmin "-$((days * 1440))" -print -quit 2>/dev/null)"; then
      say "kept $t: can't read it"; continue
    fi
    if [ -n "$recent" ]; then say "kept $t: modified in the last $days days"; continue; fi
    if in_use "$t"; then say "kept $t: in use (or lsof can't say)"; continue; fi
    bytes=$(($(du -skx "$t" | awk '{ print $1 }') * 1024))
    if [ "$dry" = 1 ]; then
      say "would delete $t ($bytes bytes)"
    elif find "$t" -xdev -delete; then
      say "deleted $t ($bytes bytes)"
    else
      say "partly deleted $t (something in it is another file system or unwritable; not counted)"
      bytes=0
    fi
    echo "$(($(cat "$tally") + bytes))" >"$tally"
  done
}

for step in $steps; do
  case "$step" in
    targets)
      tally="$(mktemp)"
      echo 0 >"$tally"
      IFS=':'
      for r in ${DISK_HYGIENE_ROOTS:-}; do
        unset IFS
        [ -n "$r" ] && clean_root "$r"
      done
      unset IFS
      freed="$(cat "$tally")"
      rm -f "$tally"
      [ -n "${DISK_HYGIENE_ROOTS:-}" ] || say "no DISK_HYGIENE_ROOTS: no targets looked for"
      if [ "$dry" = 1 ]; then say "targets: $freed bytes would be freed"; else say "targets: $freed bytes freed"; fi
      ;;
    nix)
      if [ "$dry" = 1 ]; then
        say "nix: would run nix-collect-garbage --delete-older-than ${nix_days}d"
      elif command -v nix-collect-garbage >/dev/null; then
        say "nix: $(nix-collect-garbage --delete-older-than "${nix_days}d" 2>&1 | tail -n1)"
      else
        say "nix: no nix-collect-garbage here: skipped"
      fi
      ;;
    docker)
      lock="${DISK_HYGIENE_DEPLOY_LOCK:-}"
      case "$lock" in "" | /*) ;; *) lock="$HOME/$lock" ;; esac
      if [ -n "$lock" ] && [ -e "$lock" ] && in_use "$lock"; then
        say "docker: auto-deploy is running (or lsof can't say): skipped"
      elif ! command -v docker >/dev/null || ! timeout 20 docker info >/dev/null 2>&1; then
        say "docker: no engine answering here: skipped"
      elif [ "$dry" = 1 ]; then
        say "docker: would run docker image prune -f; docker builder prune -f --filter until=336h"
      else
        say "docker: images: $(docker image prune -f 2>&1 | tail -n1)"
        say "docker: build cache: $(docker builder prune -f --filter until=336h 2>&1 | tail -n1)"
      fi
      ;;
    *) say "unknown step $step"; exit 2 ;;
  esac
done
say "done: $before bytes free at the start, $(avail) now"
