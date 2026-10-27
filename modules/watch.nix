# Each host's monitor (tinytrader's `watch`; docs/decisions/0006): its
# settings from the site's inventory, shared by the role modules
# (modules/watch-darwin.nix on a Mac, modules/nas.nix).
#
#   watch = import ./watch.nix { inherit lib site; } "my-host" {
#     native = [ "store" ];   # the native services the role module enables
#   };
#   watch.environment   WATCH_* for tinytrader.services.watch
#   watch.notifyFile    the site's secrets/notify.env, or null until it exists
#   watch.notifyKey     its key holding the ntfy URL
#   watch.heartbeatKey  its key holding this host's healthchecks.io URL
{ lib, site }:
host:
{
  # The native tinytrader services this host's role module enables (not the
  # monitor itself).
  native ? [ ],
  # Extra mount points (the NAS's store volumes).
  extraDisks ? [ ],
  # The Docker socket, when this host runs containers.
  dockerSocket ? null,
}:
let
  inherit (site) inventory;
  inherit (inventory) monitoring;
  services = inventory.services;
  # Single-host services placed here (host agents aside).
  placedHere = name: (services.${name}.host or null) == host;
  # The containers it expects: compose services placed here, in the default
  # profile (`profile` ones are off unless asked for).
  expected = lib.sort lib.lessThan (
    lib.attrNames (
      lib.filterAttrs (name: s: placedHere name && s.runtime == "compose" && !(s ? profile)) services
    )
  );
  here = name: placedHere name || lib.elem name native;
  local = name: "http://127.0.0.1:${toString services.${name}.ports.http}";
  notify = site.secret monitoring.notify.file;
  # Below 15% or 20 GiB free, whichever is more (docs/decisions/0016): a
  # warning at 85% used, high priority under 20 GiB.
  disk = {
    warnPercent = 85;
    critPercent = 95;
    minFreeGiB = 20;
  }
  // (monitoring.disk or { });
in
{
  environment = {
    WATCH_HOST = host;
    WATCH_DISKS = lib.concatStringsSep " " (
      (inventory.hosts.${host}.watch.disks or [ "/" ]) ++ extraDisks
    );
    WATCH_DISK_WARN = toString disk.warnPercent;
    WATCH_DISK_CRIT = toString disk.critPercent;
    WATCH_DISK_MIN_FREE_GIB = toString disk.minFreeGiB;
    WATCH_NEVER_PORTS = lib.concatMapStringsSep " " toString monitoring.gatewayPorts;
  }
  // lib.optionalAttrs (native != [ ]) {
    WATCH_NATIVE = lib.concatStringsSep " " (lib.sort lib.lessThan native);
  }
  // lib.optionalAttrs (dockerSocket != null) {
    WATCH_DOCKER_SOCKET = dockerSocket;
    WATCH_COMPOSE_PROJECT = site.name; # the site's compose.yaml's name
    WATCH_SERVICES = lib.concatStringsSep " " expected;
  }
  # The console (compose.yaml publishes it on loopback) and the store, where
  # they run here: on loopback, at their inventory ports. (Here, not where
  # the map says: a planned host's role runs its own ahead of the map.)
  // lib.optionalAttrs (here "console") { WATCH_CONSOLE = local "console"; }
  // lib.optionalAttrs (here "store") { WATCH_STORE = local "store"; };

  inherit expected;
  # Only files Git tracks are in the flake's source: commit the encrypted file.
  notifyFile = if builtins.pathExists notify then notify else null;
  notifyKey = monitoring.notify.url;
  heartbeatKey = monitoring.heartbeat.${host};
}
