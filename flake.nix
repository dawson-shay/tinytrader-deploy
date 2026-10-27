{
  description = "tinytrader-deploy: an opinionated deployment stack for tinytrader, generic over hosts, made concrete by a site's inventory";

  inputs = {
    tinytrader.url = "git+https://github.com/dawson-shay/tinytrader?ref=main";
    nixpkgs.follows = "tinytrader/nixpkgs";
    nix-darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      tinytrader,
      nixpkgs,
      nix-darwin,
      sops-nix,
      ...
    }:
    let
      deploymentLib = import ./lib {
        inherit
          tinytrader
          nixpkgs
          nix-darwin
          sops-nix
          ;
      };
      # The example site (example/): a made-up deployment of two Macs and a
      # NAS, so that `nix flake check` here exercises every module, script
      # package and check a real site gets. It is also the template.
      example = deploymentLib.mkDeployment {
        inventory = ./example/inventory.nix;
        secrets = ./example/secrets;
        compose = ./example/deploy/local/compose.yaml;
        topology = ./example/deploy/local/topology.json;
        state = ./example/state;
        policy = ./example/tailscale/policy.hujson;
        # The example is the stack's own.
        checkStack = false;
      };
      systems = [
        "aarch64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      # mkDeployment (lib/default.nix, docs/site.md), and the plain-Nix
      # pieces scripts evaluate directly.
      lib = deploymentLib // {
        endpoints = import ./deploy/local/endpoints.nix;
        topology = import ./deploy/local/topology.nix;
        tailscalePolicy = import ./tailscale/policy.nix;
      };

      # The example site's roles (its hosts are made up): what a site's
      # mkDeployment returns for each Mac and NixOS host.
      inherit (example) darwinModules nixosModules;

      # The example site's outputs, evaluated and checked.
      packages = example.packages;

      checks = nixpkgs.lib.genAttrs systems (
        system:
        example.checks.${system}
        // {
          # Nothing deployment-specific in this repository (checks/generic.nix).
          generic = import ./checks/generic.nix { pkgs = nixpkgs.legacyPackages.${system}; };
          # The disk-hygiene job's script on disposable folders (checks/disk-hygiene-test.sh).
          disk-hygiene =
            let
              pkgs = nixpkgs.legacyPackages.${system};
            in
            pkgs.runCommand "disk-hygiene" { nativeBuildInputs = [ pkgs.lsof ]; } ''
              sh ${./checks/disk-hygiene-test.sh} ${./deploy/nomad/disk-hygiene.sh} && touch $out
            '';
        }
      );

      devShells = example.devShells;

      templates.default = {
        path = ./example;
        description = "A tinytrader-deploy site: inventory, compose.yaml, secrets and state";
      };
    };
}
