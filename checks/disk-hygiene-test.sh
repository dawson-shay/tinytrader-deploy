# checks.<system>.disk-hygiene: deploy/nomad/disk-hygiene.sh on disposable
# folders under a temporary HOME, the target step only (nix and Docker in
# dry runs), and scripts/cargo-shim. Run by `nix flake check`; by hand:
# sh checks/disk-hygiene-test.sh deploy/nomad/disk-hygiene.sh scripts/cargo-shim.
set -eu
script="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
work="$(mktemp -d)"
work="$(cd -P "$work" && pwd -P)"
holder=""
trap '[ -z "$holder" ] || { kill "$holder"; wait "$holder"; } 2>/dev/null || true; rm -rf "$work"' EXIT
export HOME="$work/home" DISK_HYGIENE_STEPS=targets
fail() { echo "FAIL: $*" >&2; exit 1; }
old() { find "$1" -exec touch -t 202601010000 {} +; }
# A Rust workspace with a target of $2 bytes, all of it old.
crate() {
  mkdir -p "$1/target/debug"
  echo '[package]' >"$1/Cargo.toml"
  head -c "$2" /dev/zero >"$1/target/debug/out"
  : >"$1/target/debug/.cargo-lock"
  old "$1/target"
}
run() { sh "$script" "$@" >"$work/log" 2>&1 || { cat "$work/log"; fail "exit status"; }; }
gone() { [ ! -e "$1" ] || { cat "$work/log"; fail "$1 should be deleted"; }; }
kept() { [ -e "$1" ] || { cat "$work/log"; fail "$1 should be kept"; }; }
logged() { grep -q -- "$1" "$work/log" || { cat "$work/log"; fail "log lacks: $1"; }; }

r="$HOME/repos"
crate "$r/old" 4096
crate "$r/wt/fresh" 4096
echo new >"$r/wt/fresh/target/debug/new" # modified now
crate "$r/busy" 4096
mkdir -p "$r/maven/target" && echo x >"$r/maven/target/app.jar" && old "$r/maven/target" # not Rust's
mkdir -p "$HOME/.cache/cargo-target/repo/target"
printf 'Signature: 8a477f597d28d172789f06886806bc55\n# created by cargo.\n' >"$HOME/.cache/cargo-target/repo/target/CACHEDIR.TAG"
old "$HOME/.cache/cargo-target/repo/target"
# The old global target's own folders, beside the per-repository ones.
mkdir -p "$HOME/.cache/cargo-target/debug" && echo x >"$HOME/.cache/cargo-target/debug/old-bin"
old "$HOME/.cache/cargo-target/debug"
crate "$work/outside/linked" 4096 # reachable only through a symlink
ln -s "$work/outside" "$r/link"
crate "$work/elsewhere" 4096 # not under a root at all
export DISK_HYGIENE_ROOTS="repos:.cache/cargo-target:/Volumes/anything:missing"

echo "== a dry run removes nothing, and says what it would"
(export DISK_HYGIENE_DRY_RUN=1; run)
kept "$r/old/target"
logged "would delete $r/old/target ("
logged "bytes would be freed"
(export DISK_HYGIENE_STEPS="targets nix docker"; run --dry-run)
kept "$r/old/target"
logged "nix: would run nix-collect-garbage --delete-older-than 14d"
logged "docker: "

echo "== a run deletes only old, idle Rust targets inside the roots"
# Something holding a file open in busy's target, as cargo holds its lock.
tail -f "$r/busy/target/debug/.cargo-lock" >/dev/null 2>&1 &
holder=$!
sleep 1
run
gone "$r/old/target"
kept "$r/old/Cargo.toml"
gone "$HOME/.cache/cargo-target/repo/target"
kept "$HOME/.cache/cargo-target/debug/old-bin" # deleted once, by hand
kept "$r/wt/fresh/target/debug/out"
logged "kept $r/wt/fresh/target: modified in the last 7 days"
if command -v lsof >/dev/null; then
  kept "$r/busy/target"
  logged "kept $r/busy/target: in use"
fi
kept "$r/maven/target/app.jar"
kept "$work/outside/linked/target"
kept "$work/elsewhere/target"
logged "deleted $r/old/target ("
logged "/Volumes/anything: under /Volumes, never touched"
logged "$HOME/missing: not a folder"
freed="$(sed -n 's/.*targets: \([0-9]*\) bytes freed.*/\1/p' "$work/log")"
[ "${freed:-0}" -ge 4096 ] || { cat "$work/log"; fail "bytes freed: ${freed:-none}"; }

if [ -d /Volumes ]; then
  echo "== a root that is a symlink into /Volumes is refused too"
  ln -s /Volumes "$HOME/vols"
  (export DISK_HYGIENE_ROOTS=vols; run)
  logged "under /Volumes, never touched"
fi

echo "== no Docker step while auto-deploy's lock is open (a dry run)"
: >"$HOME/auto-deploy.lock"
kill "$holder"; wait "$holder" 2>/dev/null || true
tail -f "$HOME/auto-deploy.lock" >/dev/null 2>&1 &
holder=$!
sleep 1
(export DISK_HYGIENE_STEPS=docker DISK_HYGIENE_DEPLOY_LOCK=auto-deploy.lock; run --dry-run)
logged "docker: auto-deploy is running"

echo "== bad settings stop it"
if DISK_HYGIENE_DRY_RUN=yes sh "$script" >/dev/null 2>&1; then fail "DRY_RUN=yes accepted"; fi
if DISK_HYGIENE_TARGET_DAYS=x sh "$script" >/dev/null 2>&1; then fail "TARGET_DAYS=x accepted"; fi
echo "== the cargo shim: one target per repository, worktrees included"
shim="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
mkdir -p "$work/real" "$work/shim" && cp "$shim" "$work/shim/cargo"
printf '#!/bin/sh\necho "${CARGO_TARGET_DIR:-unset}"\n' >"$work/real/cargo" && chmod +x "$work/real/cargo"
g() { git -c user.name=t -c user.email=t@example.invalid "$@" >/dev/null 2>&1; }
g init -q "$work/src/myrepo" && g -C "$work/src/myrepo" commit -q --allow-empty -m x
g -C "$work/src/myrepo" worktree add -q "$work/wt/feature"
want="$HOME/.cache/cargo-target/myrepo/target"
for d in "$work/src/myrepo" "$work/wt/feature"; do
  got="$(cd "$d" && PATH="$work/shim:$work/real:$PATH" cargo)"
  [ "$got" = "$want" ] || fail "shim in $d: $got"
done
got="$(cd "$work/wt/feature" && CARGO_TARGET_DIR=/kept PATH="$work/shim:$work/real:$PATH" cargo)"
[ "$got" = /kept ] || fail "shim overrode CARGO_TARGET_DIR: $got"
got="$(cd "$work" && PATH="$work/shim:$work/real:$PATH" cargo)"
[ "$got" = unset ] || fail "shim outside a repository: $got"
echo "disk-hygiene: ok"
