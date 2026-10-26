# The nightly backup on a Mac (the inventory's `backup`; scripts/backup-state,
# modules/backup.nix), and other hosts' off-host copies kept here.
# Imported by the darwin role (roles/darwin.nix) on every Mac:
#
#   imports = [ (import ./backup-darwin.nix {
#     inherit site;
#     host = "my-mac";
#     dockerSocket = home: "${home}/.colima/default/docker.sock";
#   }) ];
#
# Sending: where the placement map runs `backup` (perHost, on the services'
# host, so it moves with them), a launchd daemon run as the primary user
# at the inventory's backup.at (outside market hours), whether or not
# anyone is logged in. A Mac asleep then runs it when it wakes; one that is
# off skips the night (and the monitor says so after backup.maxAgeHours). It
# snapshots, prunes, and sends the encrypted newest snapshot to its
# backup.offHost host. Its log: ~/Library/Logs/tinytrader/backup.log. The
# monitor on this host alerts when the newest snapshot or off-host copy is
# older than backup.maxAgeHours.
#
# Receiving (tinytrader-deploy.backup.receive, set by the machine's own config):
# the senders' backup keys, from the inventory's backup.keys, in the primary
# user's authorized keys (nix-darwin's openssh.authorizedKeys), restricted to
# rrsync, write-only, into ~/Backups/tinytrader-from-<host> (mode 700). It
# can't open a shell, read anything back, or write anywhere else.
{
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
  inherit (lib) mkOption types mkIf;
  user = config.system.primaryUser;
  home = "/Users/${user}";
  logs = "${home}/Library/Logs/tinytrader";
  stateDir = "${home}/.local/state/tinytrader-backup";
  b = import ./backup.nix { inherit lib pkgs site; };
  here = b.forHost host;
  at = site.inventory.backup.at;
  cfg = config.tinytrader-deploy.backup;
in
{
  # The repositories it copies are the deploy checkouts, where there are
  # some (scripts/backup-state; docs/decisions/0012).
  imports = [ ./deploy-root-darwin.nix ];

  options.tinytrader-deploy.backup = {
    enable = mkOption {
      type = types.bool;
      default = here.placed;
      defaultText = "whether the inventory places `backup` on this host";
      description = "The nightly backup (scripts/backup-state --scheduled), as the placement map says.";
    };
    receive = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Keep other hosts' off-host copies: accept their backup keys (the inventory's
        backup.keys) for rrsync only, into ~/Backups/tinytrader-from-<host>.
        Needs Remote Login (sshd) on.
      '';
    };
  };

  config = lib.mkMerge [
    (mkIf cfg.enable {
      launchd.daemons.tinytrader-backup.serviceConfig = {
        Label = "com.tinytrader.backup";
        ProgramArguments = [
          (lib.getExe b.package)
          "--scheduled"
        ];
        UserName = user;
        GroupName = "staff";
        StartCalendarInterval = [
          {
            Hour = at.hour;
            Minute = at.minute;
          }
        ];
        EnvironmentVariables = here.environment // {
          HOME = home;
          USER = user;
          DOCKER_HOST = "unix://${dockerSocket home}";
          BACKUP_STATE = stateDir;
          TINYTRADER_DEPLOY_ROOT = config.tinytrader-deploy.deployRoot;
          PATH = "/usr/bin:/bin:/usr/sbin:/sbin";
        };
        ProcessType = "Background";
        LowPriorityIO = true;
        Nice = 10;
        StandardOutPath = "${logs}/backup.log";
        StandardErrorPath = "${logs}/backup.log";
      };
      # The monitor checks the stamps the nightly run leaves.
      tinytrader.services.watch.environment.WATCH_FRESH = here.fresh stateDir;
      environment.systemPackages = [
        b.package
        b.restore
      ];
      system.activationScripts.postActivation.text = ''
        install -d -m 700 -o ${lib.escapeShellArg user} -g staff ${lib.escapeShellArg stateDir}
        install -d -m 755 -o ${lib.escapeShellArg user} -g staff ${lib.escapeShellArg logs}
      '';
    })

    (mkIf cfg.receive {
      users.users.${user}.openssh.authorizedKeys.keys = here.authorizedKeys home;
      system.activationScripts.postActivation.text = lib.concatMapStrings (from: ''
        [ -d ${lib.escapeShellArg "${home}/Backups"} ] || install -d -m 700 -o ${lib.escapeShellArg user} -g staff ${lib.escapeShellArg "${home}/Backups"}
        install -d -m 700 -o ${lib.escapeShellArg user} -g staff ${lib.escapeShellArg (b.inbox home from)}
      '') here.senders;
    })
  ];
}
