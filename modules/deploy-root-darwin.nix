# Where a Mac's services run from (docs/decisions/0012): the deploy
# checkouts, plain clones of origin/main under <deployRoot> that only
# scripts/auto-deploy changes, so working copies are free for any branch or
# work in progress:
#   <deployRoot>/<site>               the site (checkouts.site; by default named
#                                     after the deployment, inventory.nix
#                                     deployment.name)
#   <deployRoot>/tinytrader-deploy    this stack (checkouts.stack)
#   <deployRoot>/tinytrader           the platform (checkouts.tinytrader)
# Imported by modules/auto-deploy-darwin.nix and modules/backup-darwin.nix.
#
# The launchd jobs that use the checkouts get TINYTRADER_DEPLOY_ROOT from
# this option, and so do the shells nix-darwin manages (environment.variables;
# where it doesn't manage the shell, a shell relies on the scripts' default,
# which is this option's: change both together). A Mac without the clones
# runs from the checkout a script is in, as before.
{ config, lib, ... }:
let
  home = "/Users/${config.system.primaryUser}";
  cfg = config.tinytrader-deploy;
  str = lib.types.str;
in
{
  options.tinytrader-deploy = {
    deployRoot = lib.mkOption {
      type = str;
      default = "${home}/.local/share/tinytrader/deploy";
      defaultText = lib.literalExpression ''"/Users/''${config.system.primaryUser}/.local/share/tinytrader/deploy"'';
      description = ''
        The directory holding the deploy checkouts: what the containers,
        auto-deploy and the backup use (scripts/lib/deploy-root.sh). The
        clones are made by hand once (docs/operations.md, "The deploy
        checkouts").
      '';
    };
    checkouts = {
      site = lib.mkOption {
        type = str;
        default = "${cfg.deployRoot}/site";
        defaultText = lib.literalExpression ''"''${config.tinytrader-deploy.deployRoot}/<inventory.nix deployment.name>"'';
        description = "The site's deploy checkout (the role sets it to <deployRoot>/<the deployment's name>).";
      };
      stack = lib.mkOption {
        type = str;
        default = "${cfg.deployRoot}/tinytrader-deploy";
        defaultText = lib.literalExpression ''"''${config.tinytrader-deploy.deployRoot}/tinytrader-deploy"'';
        description = "This stack's deploy checkout: the scripts the launchd jobs run.";
      };
      tinytrader = lib.mkOption {
        type = str;
        default = "${cfg.deployRoot}/tinytrader";
        defaultText = lib.literalExpression ''"''${config.tinytrader-deploy.deployRoot}/tinytrader"'';
        description = "The tinytrader checkout scripts/deploy builds images from.";
      };
    };
  };

  config.environment.variables.TINYTRADER_DEPLOY_ROOT = cfg.deployRoot;
}
