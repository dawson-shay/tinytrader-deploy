# Deploying merged code automatically (docs/decisions/0011): scripts/auto-deploy
# every 5 minutes, from this stack's deploy checkout under
# tinytrader-deploy.deployRoot (modules/deploy-root-darwin.nix,
# docs/decisions/0012), never a working copy. Off until the machine's config
# sets tinytrader-deploy.autoDeploy.enable = true. Imported by the darwin
# role (roles/darwin.nix) on every Mac:
#
#   imports = [ (import ./auto-deploy-darwin.nix { dockerSocket = home: "${home}/.colima/default/docker.sock"; }) ];
#
# A launchd agent (in the primary user's login session), not a daemon: its
# `git fetch` of a private site authenticates with gh's credential helper,
# whose token is in the login keychain, which a daemon can't read.
# It runs the script from the checkout itself, so a merged change to the
# script is the next run's. Its log: ~/Library/Logs/tinytrader/auto-deploy.log
# (rotated with the others, past 10 MB). The script, not launchd, keeps runs
# from overlapping, the market hours, the kill switch and what it may deploy.
{
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
  cfg = config.tinytrader-deploy.autoDeploy;
  root = config.tinytrader-deploy.deployRoot;
  checkouts = config.tinytrader-deploy.checkouts;
in
{
  imports = [ ./deploy-root-darwin.nix ];

  options.tinytrader-deploy.autoDeploy = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Run scripts/auto-deploy every `interval` seconds: fast-forward the
        checkouts to origin/main and deploy the containers the new commits
        change (never those in the inventory's deployment.autoDeploy.never),
        outside market hours.
      '';
    };
    interval = mkOption {
      type = types.ints.positive;
      default = 300;
      description = "Seconds between runs.";
    };
  };

  config = mkIf cfg.enable {
    launchd.user.agents.tinytrader-auto-deploy.serviceConfig = {
      Label = "com.tinytrader.auto-deploy";
      ProgramArguments = [
        (lib.getExe pkgs.bash)
        "${checkouts.stack}/scripts/auto-deploy"
        "--scheduled"
      ];
      StartInterval = cfg.interval;
      EnvironmentVariables = {
        HOME = home;
        USER = user;
        TINYTRADER_DEPLOY_ROOT = root;
        TINYTRADER_SRC = checkouts.tinytrader;
        TINYTRADER_SITE = checkouts.site;
        DOCKER_HOST = "unix://${dockerSocket home}";
        # Bash 5 first (the scripts' `env bash`), then the Nix-managed tools
        # (docker, sops, nix, gh) and the system's.
        PATH = lib.concatStringsSep ":" [
          "${pkgs.bash}/bin"
          "${home}/.nix-profile/bin"
          "/etc/profiles/per-user/${user}/bin"
          "/run/current-system/sw/bin"
          "/nix/var/nix/profiles/default/bin"
          "/usr/bin"
          "/bin"
          "/usr/sbin"
          "/sbin"
        ];
      };
      ProcessType = "Background";
      StandardOutPath = "${logs}/auto-deploy.log";
      StandardErrorPath = "${logs}/auto-deploy.log";
    };
    system.activationScripts.postActivation.text = ''
      install -d -m 755 -o ${lib.escapeShellArg user} -g staff ${lib.escapeShellArg logs}
    '';
  };
}
