# The switch guard (scripts/switch-guard): a switch of this machine during
# market hours that changes a live-path service's unit is refused. Its
# options, shared by modules/switch-guard-nixos.nix (a pre-switch check) and
# modules/switch-guard-darwin.nix (the start of activation):
#
#   tinytrader-deploy.switchGuard.enable     on by default
#   tinytrader-deploy.switchGuard.services   the live-path services, as shell
#                                            patterns (default: the site's
#                                            deployment.switchGuard.services,
#                                            else what auto-deploy never deploys
#                                            plus the store and the recorders)
#   tinytrader-deploy.switchGuard.hours      New York time (deployment.captureHours)
#
# To switch anyway, inside the hours: sudo touch /var/run/tinytrader-switch-ok
# (honoured for an hour).
{ site, kind }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  deployment = site.inventory.deployment or { };
  cfg = config.tinytrader-deploy.switchGuard;
in
{
  options.tinytrader-deploy.switchGuard = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Refuse a switch on a weekday inside `hours` (New York time) when it
        adds, removes or changes a unit of one of `services`, which the
        switch would restart.
      '';
    };
    services = mkOption {
      type = types.listOf types.str;
      default =
        (deployment.switchGuard or { }).services or (
          ((deployment.autoDeploy or { }).never or [
            "order-gateway-*"
            "relay-*"
          ]
          )
          ++ [
            "store"
            "recorders"
          ]
        );
      defaultText = lib.literalMD "the site's `deployment.switchGuard.services`, else `deployment.autoDeploy.never` plus `store` and `recorders`";
      example = [
        "relay-*"
        "order-gateway-*"
        "store"
      ];
      description = "The live-path services, as shell patterns on their names.";
    };
    hours = mkOption {
      type = types.strMatching "[0-9]{2}:[0-9]{2}-[0-9]{2}:[0-9]{2}";
      default = deployment.captureHours or "09:25-16:20";
      description = "Market hours, New York time, Monday to Friday.";
    };
    package = mkOption {
      type = types.package;
      readOnly = true;
      default = pkgs.writeShellApplication {
        name = "switch-guard";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.diffutils
          pkgs.findutils
        ];
        text = ''
          export SWITCH_GUARD_KIND=${kind}
          export SWITCH_GUARD_SERVICES=${lib.escapeShellArg (lib.concatStringsSep " " cfg.services)}
          export SWITCH_GUARD_HOURS=${cfg.hours}
        ''
        + builtins.readFile ../scripts/switch-guard;
      };
      description = "The guard, configured for this machine.";
    };
  };
}
