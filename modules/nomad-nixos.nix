# A Nomad agent on NixOS (modules/nomad.nix's options), through NixOS's
# services.nomad. A client runs as root (Nomad's own advice: its drivers
# need it); a server alone drops privileges.
#
# The machine must allow the unfree package by name
# (nixpkgs.config.allowUnfreePredicate, in your machines repository).
{ config, lib, pkgs, ... }:
let
  cfg = config.tinytrader-deploy.nomad;
in
{
  imports = [ ./nomad.nix ];

  config = lib.mkIf cfg.enable {
    tinytrader-deploy.nomad = {
      package = lib.mkDefault pkgs.nomad;
      # NixOS's Docker (services.nomad.enableDocker turns it on).
      client.dockerSocket = lib.mkDefault "/var/run/docker.sock";
    };

    services.nomad = {
      enable = true;
      inherit (cfg) package;
      dropPrivileges = !cfg.client.enable;
      enableDocker = cfg.client.dockerSocket != null;
      # Host jobs and the jobs' gate (deploy/nomad/gate.sh).
      extraPackages = [
        pkgs.coreutils
        pkgs.curl
        pkgs.jq
      ];
      settings = cfg.settings;
    };
  };
}
