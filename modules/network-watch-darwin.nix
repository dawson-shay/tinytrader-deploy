# The Mac's wired network, watched (off unless the machine's config sets
# tinytrader-deploy.networkWatch.enable). A Mac whose live feed falls back
# to Wi-Fi falls behind (a relay's options feed lagged by up to a minute
# over Wi-Fi), and a link that flaps drops the relays' sessions. Imported by
# the darwin role (roles/darwin.nix).
#
# A small service (tinytrader.services.network-watch, a launchd daemon run as
# the primary user) looks every `every` seconds:
#   - at the default route: while it goes out through `interface`, it
#     touches <state>/default-route-wired;
#   - at the link: while `interface` has been active for `steadySeconds`
#     without going down, it touches <state>/link-steady. A flap (down, then
#     up) stops that for steadySeconds.
# The monitor (tinytrader's watch, WATCH_FRESH) warns when either stamp is
# older than `maxAge` seconds, as it does for the backup's: "network-wired"
# when the default route isn't wired, "network-link-steady" after a flap or
# while the link is down. Both clear by themselves. A flap shorter than
# `every` can go unseen; each change it sees is in its log
# (~/Library/Logs/tinytrader/network-watch.log).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types mkIf;
  cfg = config.tinytrader-deploy.networkWatch;
  home = "/Users/${config.system.primaryUser}";
  state = "${home}/.local/state/tinytrader-network";
  check = pkgs.writeShellApplication {
    name = "network-watch";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
    ];
    text = ''
      iface="$NETWORK_INTERFACE" state="$NETWORK_STATE"
      every="$NETWORK_EVERY" steady="$NETWORK_STEADY"
      mkdir -p "$state"
      log() { printf '%s network-watch: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
      last="" changed=0 route_was=""
      log "watching $iface (every $every s; steady after $steady s)"
      while :; do
        now="$(date +%s)"
        status="$(/sbin/ifconfig "$iface" 2>/dev/null | sed -n 's/^[[:space:]]*status: //p')"
        [ -n "$status" ] || status="missing"
        if [ "$status" != "$last" ]; then
          if [ -n "$last" ]; then
            log "link $iface: $last -> $status"
            changed="$now"
          fi
          last="$status"
        fi
        route="$(/sbin/route -n get default 2>/dev/null | sed -n 's/^[[:space:]]*interface: //p')"
        if [ "$route" != "$route_was" ]; then
          log "default route: via ''${route:-nothing}"
          route_was="$route"
        fi
        if [ "$route" = "$iface" ]; then touch "$state/default-route-wired"; fi
        if [ "$status" = active ] && [ $((now - changed)) -ge "$steady" ]; then touch "$state/link-steady"; fi
        sleep "$every"
      done
    '';
  };
in
{
  imports = [ ./watch-fresh.nix ];

  options.tinytrader-deploy.networkWatch = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Warn (through the monitor) when the default route isn't on `interface`, or its link flaps.";
    };
    interface = mkOption {
      type = types.str;
      example = "en0";
      description = "The wired interface (networksetup -listallhardwareports names it).";
    };
    every = mkOption {
      type = types.ints.positive;
      default = 5;
      description = "Seconds between looks.";
    };
    steadySeconds = mkOption {
      type = types.ints.positive;
      default = 600;
      description = "How long the link must stay up after a change before it counts as steady again.";
    };
    maxAge = mkOption {
      type = types.ints.positive;
      default = 120;
      description = "Seconds a stamp may go untouched before the monitor warns.";
    };
  };

  config = mkIf cfg.enable {
    tinytrader.services.network-watch = {
      enable = true;
      launchd = "daemon";
      package = check;
      environment = {
        NETWORK_INTERFACE = cfg.interface;
        NETWORK_STATE = state;
        NETWORK_EVERY = toString cfg.every;
        NETWORK_STEADY = toString cfg.steadySeconds;
      };
    };
    tinytrader-deploy.watchFresh = [
      "network-wired:${toString cfg.maxAge}:${state}/default-route-wired"
      "network-link-steady:${toString cfg.maxAge}:${state}/link-steady"
    ];
  };
}
