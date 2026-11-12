# Deploying merged code automatically on a NixOS host (docs/decisions/0011),
# as modules/auto-deploy-darwin.nix does on a Mac: scripts/auto-deploy every
# 5 minutes from this stack's deploy checkout under
# tinytrader-deploy.deployRoot (docs/decisions/0012), never a working copy.
# Off until the machine's config sets tinytrader-deploy.autoDeploy.enable =
# true (and autoDeploy.user). Imported by modules/nas.nix.
#
# A system service run as that user, not a user service: it needs no login
# session, and on Linux gh's token is a file in the user's home
# (~/.config/gh), not a keychain only a login session can read. The script,
# not systemd, keeps runs from overlapping, the market hours, the kill switch
# (~/.config/tinytrader/auto-deploy.off) and what it may deploy. Its log:
# ~/.local/state/tinytrader/auto-deploy.log (and the journal).
#
# On a host whose services all run under systemd, a run fast-forwards the
# deploy checkouts, commits the console's state if the console runs here, and
# notifies what needs a manual deploy: the systemd services are deployed by
# rebuilding the machine (nixos-rebuild, in your machines repository), never
# by this job.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types mkIf;
  cfg = config.tinytrader-deploy.autoDeploy;
  root = config.tinytrader-deploy.deployRoot;
  checkouts = config.tinytrader-deploy.checkouts;
  user = cfg.user;
  home = if user == null then "/nonexistent" else config.users.users.${user}.home;
in
{
  options.tinytrader-deploy = {
    deployRoot = mkOption {
      type = types.str;
      default = "${home}/.local/share/tinytrader/deploy";
      defaultText = lib.literalExpression ''"<autoDeploy.user's home>/.local/share/tinytrader/deploy"'';
      description = ''
        The directory holding the deploy checkouts (scripts/lib/deploy-root.sh,
        docs/decisions/0012). The clones are made by hand once
        (docs/operations.md, "The deploy checkouts").
      '';
    };
    checkouts = {
      site = mkOption {
        type = types.str;
        default = "${root}/site";
        description = "The site's deploy checkout (the role sets it to <deployRoot>/<the deployment's name>).";
      };
      stack = mkOption {
        type = types.str;
        default = "${root}/tinytrader-deploy";
        description = "This stack's deploy checkout: the scripts the timer runs.";
      };
      tinytrader = mkOption {
        type = types.str;
        default = "${root}/tinytrader";
        description = "The tinytrader deploy checkout.";
      };
    };
    autoDeploy = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Run scripts/auto-deploy every `interval` seconds: fast-forward the
          deploy checkouts to origin/main and deploy what the new commits
          change and may be deployed by it (decision 0011), outside market
          hours.
        '';
      };
      interval = mkOption {
        type = types.ints.positive;
        default = 300;
        description = "Seconds between runs.";
      };
      user = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "alice";
        description = "The account it runs as: the deploy checkouts', with gh logged in (its git credentials).";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = user != null && config.users.users ? ${user};
        message = "tinytrader-deploy.autoDeploy: set autoDeploy.user to an account of this machine";
      }
    ];

    environment.variables.TINYTRADER_DEPLOY_ROOT = root;

    systemd.services.tinytrader-auto-deploy = {
      description = "tinytrader auto-deploy (scripts/auto-deploy, decision 0011)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # Bash 5 first (the scripts' `env bash`), then the tools they use.
      path = with pkgs; [
        bash
        coreutils
        gnugrep
        gnused
        findutils
        git
        gh
        jq
        python3
        curl
        sops
        config.nix.package
      ];
      environment = {
        HOME = home;
        USER = user;
        TINYTRADER_DEPLOY_ROOT = root;
        TINYTRADER_SRC = checkouts.tinytrader;
        TINYTRADER_SITE = checkouts.site;
        AUTO_DEPLOY_LOG = "${home}/.local/state/tinytrader/auto-deploy.log";
      };
      serviceConfig = {
        Type = "oneshot";
        User = user;
        ExecStart = "${lib.getExe pkgs.bash} ${checkouts.stack}/scripts/auto-deploy --scheduled";
        Nice = 10;
      };
      # Until the deploy checkouts are cloned, a run is skipped, not failed.
      unitConfig.ConditionPathExists = "${checkouts.stack}/scripts/auto-deploy";
    };
    systemd.timers.tinytrader-auto-deploy = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitInactiveSec = "${toString cfg.interval}s";
      };
    };
    systemd.tmpfiles.rules = [ "d ${home}/.local/state/tinytrader 0755 ${user} - -" ];
  };
}
