#!/usr/bin/env bash
# Retired (docs/decisions/0006). node_exporter now runs as a launchd daemon,
# tinytrader.services.node-exporter (modules/watch-darwin.nix), on
# 127.0.0.1:9100, started at boot and kept running: apply this Mac's role
# (your machines repository's switch, or scripts/darwin-switch).
#
# If an exporter started by the old script is still running in tmux, it holds
# port 9100: stop it first, then apply the role.
#   tmux kill-session -t tinytrader-node-exporter
set -euo pipefail
sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2
if tmux has-session -t tinytrader-node-exporter 2>/dev/null; then
  echo "(the old tmux session tinytrader-node-exporter is still running)" >&2
fi
exit 1
