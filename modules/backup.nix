# The nightly backup (`backup` in the inventory's services; scripts/backup-state):
# its package and its settings from the inventory's `backup`, shared by the
# role modules (modules/backup-darwin.nix on the Macs, modules/nas.nix) and
# a deployment's packages and checks.
#
#   b = import ./backup.nix { inherit lib pkgs site; };
#   b.package                   backup-state, with its tools and the site's compose.yaml
#   b.restore                   restore-state, the same
#   b.forHost "my-host"         that host's settings:
#     .placed                     the placement map runs it there
#     .environment                BACKUP_* for the nightly run
#     .fresh stateDir             WATCH_FRESH for the host's monitor
#     .authorizedKeys home        the other hosts' keys, restricted to rrsync
#                                 into their directory under home (the
#                                 receiving side, modules/backup-darwin.nix)
{
  lib,
  pkgs,
  site,
}:
let
  inherit (site) inventory compose;
  cfg = inventory.backup;
  # The age recipients the off-host copy is encrypted to: the operator key
  # and, once it exists, the recovery key (secrets.recovery). Public keys.
  recipients = lib.filter (r: r != null) [
    inventory.secrets.operator
    (inventory.secrets.recovery or null)
  ];
  tools = with pkgs; [
    coreutils
    findutils
    gnused
    gnugrep
    gawk
    gnutar
    zstd
    age
    rsync
    openssh
    jq
    yq-go
    python3
    git
    procps
    docker-client
  ];
  # The scripts run as they are in the checkout, after these defaults.
  wrap =
    name: script:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = tools;
      # restore-state's steps are `bash -c '...'` with arguments.
      excludeShellChecks = [ "SC2016" ];
      text = ''
        export BACKUP_STATE_PACKAGED=1
        export BACKUP_COMPOSE="''${BACKUP_COMPOSE:-${compose}}"
        export BACKUP_KEEP_DAILY="''${BACKUP_KEEP_DAILY:-${toString cfg.keep.daily}}"
        export BACKUP_KEEP_WEEKLY="''${BACKUP_KEEP_WEEKLY:-${toString cfg.keep.weekly}}"
        export BACKUP_MIN_FREE_GIB="''${BACKUP_MIN_FREE_GIB:-${toString inventory.monitoring.disk.minFreeGiB}}"
        export BACKUP_RECIPIENTS="''${BACKUP_RECIPIENTS-${lib.concatStringsSep " " recipients}}"
        export BACKUP_PROJECT="''${BACKUP_PROJECT:-${site.name}}"
      ''
      + builtins.readFile script;
    };
  # A sender's directory on the receiving host, under its user's home.
  inbox = home: from: "${home}/Backups/tinytrader-from-${from}";
in
{
  inherit recipients inbox;
  package = wrap "backup-state" ../scripts/backup-state;
  restore = wrap "restore-state" ../scripts/restore-state;

  forHost =
    host:
    let
      to = cfg.offHost.${host} or null;
      # The off-host copy starts once this host's backup key is in the
      # inventory (the receiver accepts it then).
      sending = to != null && (cfg.keys.${host} or null) != null;
      maxAge = toString (inventory.monitoring.backup.maxAgeHours * 3600);
    in
    {
      placed = (inventory.services.backup.perHost or { }) ? ${host};
      inherit sending to;
      environment = {
        BACKUP_HOST = host;
      }
      // lib.optionalAttrs sending {
        BACKUP_OFFHOST = "${cfg.accounts.${to}}@${inventory.hosts.${to}.tailnetName}.${inventory.tailnet.domain}";
      };
      # The monitor's freshness checks (tinytrader's watch, WATCH_FRESH): the
      # newest snapshot, and the newest off-host copy once there is one to make.
      fresh =
        stateDir:
        lib.concatStringsSep " " (
          [ "backup:${maxAge}:${stateDir}/last-backup" ]
          ++ lib.optional sending "backup-offhost:${maxAge}:${stateDir}/last-offhost"
        );
      # authorized_keys lines for the hosts whose copies come here: each key
      # may only run rrsync, write-only, in its own directory, from the
      # tailnet's addresses, with no shell, pty or forwarding.
      authorizedKeys =
        home:
        lib.mapAttrsToList (
          from: _:
          ''restrict,from="100.64.0.0/10,fd7a:115c:a1e0::/48",command="${lib.getExe pkgs.rrsync} -wo ${inbox home from}" ${cfg.keys.${from}}''
        ) (lib.filterAttrs (from: to: to == host && (cfg.keys.${from} or null) != null) cfg.offHost);
      # The senders whose directories this host keeps.
      senders = lib.attrNames (lib.filterAttrs (_: to: to == host) cfg.offHost);
    };
}
