# The switch guard on a Mac (modules/switch-guard.nix): first thing in
# nix-darwin's activation, before anything is loaded or booted out, so
# `darwin-rebuild switch` refuses during market hours when a live-path
# launchd job changes. Imported by the darwin role (roles/darwin.nix).
{ site }:
{ config, lib, ... }:
{
  imports = [
    (import ./switch-guard.nix {
      inherit site;
      kind = "launchd";
    })
  ];
  config = lib.mkIf config.tinytrader-deploy.switchGuard.enable {
    system.activationScripts.preActivation.text = lib.mkBefore ''
      ${lib.getExe config.tinytrader-deploy.switchGuard.package} "$systemConfig" switch || exit 1
    '';
  };
}
