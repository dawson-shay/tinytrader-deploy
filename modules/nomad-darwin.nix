# A Nomad agent on a Mac (modules/nomad.nix's options): a launchd daemon,
# so it starts at boot without a login, run as the primary user.
#
# Why that user and not root: the work it runs is that user's. raw_exec
# commands (host builds) run as the agent's user, with its cargo, its HOME
# and its deploy checkouts; the docker driver uses the user's engine (Colima's
# socket is theirs); and allocations live under $HOME, which is all Colima
# shares with its VM. Root would make the allocation folders root's, and
# would run host jobs as root.
#
# The machine must allow the unfree package by name
# (nixpkgs.config.allowUnfreePredicate, in your machines repository).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.tinytrader-deploy.nomad;
  user = config.system.primaryUser;
  home = "/Users/${user}";
  configFile = pkgs.writeText "nomad.json" (builtins.toJSON cfg.settings);
in
{
  imports = [ ./nomad.nix ];

  config = lib.mkIf cfg.enable {
    tinytrader-deploy.nomad = {
      package = lib.mkDefault pkgs.nomad;
      dataDir = lib.mkDefault "${home}/.local/share/nomad";
      client.allocDir = lib.mkDefault "${home}/.local/share/nomad/alloc";
    };

    environment.systemPackages = [ cfg.package ];

    launchd.daemons.nomad.serviceConfig = {
      UserName = user;
      ProgramArguments = [
        (lib.getExe cfg.package)
        "agent"
        "-config"
        "${configFile}"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      # Not before the network: the advertise address is the tailnet's,
      # read at start (a failed start is retried, KeepAlive).
      ThrottleInterval = 30;
      EnvironmentVariables = {
        HOME = home;
        # Host jobs inherit it (raw_exec): the user's tools, then the
        # system's, and what the jobs' gate needs (curl, jq, timeout).
        PATH = lib.concatStringsSep ":" [
          (lib.makeBinPath [
            pkgs.coreutils
            pkgs.curl
            pkgs.jq
          ])
          "${home}/.nix-profile/bin"
          "/etc/profiles/per-user/${user}/bin"
          "/run/current-system/sw/bin"
          "/nix/var/nix/profiles/default/bin"
          "/usr/bin:/bin:/usr/sbin:/sbin"
        ];
      };
      SoftResourceLimits.NumberOfFiles = 65536;
      StandardOutPath = "${home}/Library/Logs/tinytrader/nomad.log";
      StandardErrorPath = "${home}/Library/Logs/tinytrader/nomad.log";
    };
  };
}
