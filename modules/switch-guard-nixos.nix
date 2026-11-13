# The switch guard on NixOS (modules/switch-guard.nix): a pre-switch check
# of switch-to-configuration, so `nixos-rebuild switch` (or test) refuses
# during market hours when a live-path unit changes. `boot` is never
# refused. Imported by modules/nas.nix.
{ site }:
{ config, lib, ... }:
{
  imports = [
    (import ./switch-guard.nix {
      inherit site;
      kind = "systemd";
    })
  ];
  config = lib.mkIf config.tinytrader-deploy.switchGuard.enable {
    system.preSwitchChecks.tinytrader-switch-guard = ''
      ${lib.getExe config.tinytrader-deploy.switchGuard.package} "''${1-}" "''${2-}"
    '';
  };
}
