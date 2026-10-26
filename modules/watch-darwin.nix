# A Mac's monitor and node_exporter, as launchd daemons from tinytrader's
# service definitions (docs/decisions/0006). Imported by the darwin role
# (roles/darwin.nix) where the placement map runs `watch`:
#
#   imports = [ (import ./watch-darwin.nix {
#     inherit tinytrader site;
#     host = "my-mac";
#     dockerSocket = home: "${home}/.colima/default/docker.sock";
#   }) ];
#
# Both are boot-time daemons (tinytrader.services.<name>.launchd = "daemon"),
# run as the primary user, so they start after a reboot or power cut without
# anyone logging in, and the heartbeat says the host is back. With FileVault
# off that is right at boot; with it on, boot still stops at the unlock
# screen until someone types the password, but unlocking is enough; no full
# login is needed after it. (Docker Desktop still starts only at login:
# until then the monitor reports its engine down.)
#
# Switching from the agents they were, activation boots the old agents out
# (tinytrader's darwin-services); docs/operations.md has the manual steps.
#
# nix-darwin's launchd services take no secrets, so the monitor starts through
# a wrapper that decrypts the site's secrets/notify.env with the operator key into its
# own environment only (as scripts/local-up.sh does), then runs `watch`. With
# no notify.env yet, or one it can't decrypt, it says so and runs anyway:
# notices are logged, not sent, and there is no heartbeat.
{
  tinytrader,
  site,
  host,
  # The Docker engine's socket on this Mac, given its primary user's home.
  dockerSocket,
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  home = "/Users/${config.system.primaryUser}";
  # The native services this role enables, but the monitor.
  native = lib.attrNames (
    lib.filterAttrs (name: s: name != "watch" && s.enable) config.tinytrader.services
  );
  w = import ./watch.nix { inherit lib site; } host {
    inherit native;
    dockerSocket = dockerSocket home;
  };
  watch = tinytrader.packages.${pkgs.stdenv.hostPlatform.system}.watch;
  start = pkgs.writeShellApplication {
    name = "watch-${host}";
    runtimeInputs = [
      pkgs.sops
      pkgs.gnused
    ];
    text = ''
      notify_env=${if w.notifyFile == null then "" else lib.escapeShellArg "${w.notifyFile}"}
      if [ -z "$notify_env" ]; then
        echo "watch: secrets/notify.env isn't in this build: notices are logged, not sent (${site.name} secrets/README.md)" >&2
      elif ! env="$(sops decrypt --input-type dotenv --output-type dotenv "$notify_env" 2>/dev/null)"; then
        echo "watch: could not decrypt notify.env (the operator key?): notices are logged, not sent" >&2
      else
        WATCH_NOTIFY="$(sed -n 's/^${w.notifyKey}=//p' <<<"$env" | head -n1)"
        WATCH_HEARTBEAT="$(sed -n 's/^${w.heartbeatKey}=//p' <<<"$env" | head -n1)"
        unset env
        [ -n "$WATCH_NOTIFY" ] || echo "watch: notify.env has no ${w.notifyKey}: notices are logged, not sent" >&2
        [ -n "$WATCH_HEARTBEAT" ] || echo "watch: notify.env has no ${w.heartbeatKey}: no heartbeat" >&2
        export WATCH_NOTIFY WATCH_HEARTBEAT
      fi
      exec ${lib.getExe watch} "$@"
    '';
  };
in
{
  tinytrader.services.watch = {
    enable = true;
    launchd = "daemon";
    package = start;
    environment = w.environment // {
      HOME = home;
      XDG_STATE_HOME = "${home}/.local/state";
      # launchd's PATH is minimal; launchctl is in /bin. (The daemon gets
      # HOME and USER from tinytrader's module too; sops finds the operator
      # key under HOME.)
      PATH = "/usr/bin:/bin:/usr/sbin:/sbin";
    };
  };

  # The machine's CPU, memory, swap and disks for the console's Hosts views
  # and the terminal view (topology.json's `exporter`), on loopback only.
  # Replaces scripts/host-exporter.sh, which ran it by hand in tmux.
  tinytrader.services.node-exporter = {
    enable = true;
    launchd = "daemon";
    package = pkgs.prometheus-node-exporter;
    args = [ "--web.listen-address=127.0.0.1:9100" ];
  };
}
