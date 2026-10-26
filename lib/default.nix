# lib.mkDeployment: a deployment of tinytrader from a site, the private
# repository that holds only what is the deployment's own (docs/site.md):
#
#   outputs = { tinytrader-deploy, ... }:
#     tinytrader-deploy.lib.mkDeployment {
#       inventory = ./inventory.nix;              # hosts, placement, tailnet, data roots, secrets recipients
#       secrets = ./secrets;                      # sops-encrypted files (the inventory's secrets.files)
#       compose = ./deploy/local/compose.yaml;    # the containers (deploy/local/compose.example.yaml here)
#       topology = ./deploy/local/topology.json;  # the console's panels, bundles and links (optional)
#       state = ./state;                          # state kept in git: state/console (optional)
#       policy = ./tailscale/policy.hujson;       # the committed tailnet policy, checked current (optional)
#     };
#
# It returns flake outputs, to use as they are or merge with the site's own:
#   darwinModules.<host>   the role of each Mac something is placed on (roles/darwin.nix),
#                          for the machine's own configuration to import
#   nixosModules.<host>    the role of each NixOS host something is placed on (modules/nas.nix)
#   packages.<system>      topology, endpoints, backup-state, restore-state, tailscale-policy
#   checks.<system>        the placement map against compose.yaml, the roles, the data roots,
#                          the secrets and the backup; auto-deploy; the policy; secrets encrypted
#   devShells.<system>     sops, age, jq
#   inventory              the inventory, evaluated
#   lib                    darwinRole { host; dockerSocket ? null; }, nixosRole host, site
#   examples               each role on a minimal machine (what the checks read)
{
  tinytrader,
  nixpkgs,
  nix-darwin,
  sops-nix,
}:
let
  inherit (nixpkgs) lib;
  load = x: if builtins.isAttrs x then x else import x;
in
{
  mkDeployment =
    {
      inventory,
      secrets,
      compose,
      topology ? null,
      state ? null,
      policy ? null,
      # checks.stack-generic: that nothing of this site leaks into the stack
      # (the stack's own example site turns it off: it is the stack's).
      checkStack ? true,
      systems ? [
        "aarch64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ],
    }:
    let
      inv = load inventory;
      name = inv.deployment.name or "tinytrader";
      # What the role modules know of the site.
      site = {
        inventory = inv;
        inherit name compose state;
        secrets = secrets;
        # A file under secrets/ (it may not exist yet: builtins.pathExists says).
        secret = file: secrets + "/${file}";
        endpoints = import ../deploy/local/endpoints.nix { inventory = inv; };
      };
      endpoints = site.endpoints;

      places = s: if s ? perHost then lib.attrNames s.perHost else [ s.host ];
      placedHosts = lib.unique (lib.concatMap places (lib.attrValues inv.services));
      hostsOf = os: lib.filter (h: (inv.hosts.${h}.os or null) == os) placedHosts;
      darwinHosts = hostsOf "darwin";
      nixosHosts = hostsOf "nixos";

      darwinRole =
        {
          host,
          dockerSocket ? null,
        }:
        import ../roles/darwin.nix {
          inherit
            tinytrader
            site
            host
            dockerSocket
            ;
        };
      nixosRole =
        host:
        import ../modules/nas.nix {
          inherit
            tinytrader
            sops-nix
            site
            host
            ;
        };
      darwinModules = lib.genAttrs darwinHosts (host: darwinRole { inherit host; });
      nixosModules = lib.genAttrs nixosHosts nixosRole;

      # Each role on a minimal machine, so the checks can read what it
      # declares (the real machines are the machines repository's, which
      # imports sops-nix and decrypts with the SSH host key, as here).
      examples = {
        darwin = lib.genAttrs darwinHosts (
          host:
          nix-darwin.lib.darwinSystem {
            modules = [
              sops-nix.darwinModules.sops
              darwinModules.${host}
              {
                nixpkgs.hostPlatform = inv.hosts.${host}.system;
                system.primaryUser = "example";
                # The batch scheduler (Nomad, BSL): unfree in nixpkgs, allowed by name.
                nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "nomad";
                system.stateVersion = 6;
                sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
                sops.gnupg.sshKeyPaths = [ ];
              }
            ];
          }
        );
        # A NixOS role on a minimal host, so `nix eval` checks the module
        # before the hardware exists (not a machine of the deployment).
        nixos = lib.genAttrs nixosHosts (
          host:
          nixpkgs.lib.nixosSystem {
            system = inv.hosts.${host}.system;
            modules = [
              nixosModules.${host}
              {
                networking.hostName = host;
                nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "nomad";
                tinytrader-deploy.nas = {
                  enable = true;
                  volumes.tank = "/tank/market";
                };
                boot.loader.grub.enable = false;
                fileSystems."/" = {
                  device = "none";
                  fsType = "tmpfs";
                };
                system.stateVersion = "26.05";
              }
            ];
          }
        );
      };

      forAllSystems = lib.genAttrs systems;
      backupFor = pkgs: import ../modules/backup.nix { inherit pkgs site; inherit (pkgs) lib; };

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          b = backupFor pkgs;
        in
        {
          # The console's topology file: the site's topology.json with the
          # placement map (each service's host), and the inventory under
          # `inventory`. scripts/deploy and local-up.sh write it for the console.
          topology = pkgs.writeText "topology.json" (
            builtins.toJSON (
              import ../deploy/local/topology.nix {
                inventory = inv;
                overlay = topology;
              }
            )
          );
          # Where each service is reached from each host (docs/decisions/0008):
          # endpoints.json (deploy/local/endpoints.nix's compose, native and
          # serve views), and <host>.env, the TT_ADDR_* and TT_URL_* compose.yaml
          # is interpolated with there (scripts/placement endpoints prints the
          # same for the machine it runs on).
          endpoints =
            let
              env = vars: lib.concatStrings (lib.mapAttrsToList (k: v: "${k}=${v}\n") vars);
            in
            pkgs.linkFarm "endpoints" (
              [
                {
                  name = "endpoints.json";
                  path = pkgs.writeText "endpoints.json" (
                    builtins.toJSON {
                      inherit (endpoints)
                        compose
                        native
                        serve
                        aclPorts
                        fqdn
                        ;
                    }
                  );
                }
              ]
              ++ lib.mapAttrsToList (host: vars: {
                name = "${host}.env";
                path = pkgs.writeText "${host}.env" (env vars);
              }) endpoints.compose
            );
          # The nightly backup and its restore (scripts/backup-state,
          # scripts/restore-state, with their tools; modules/backup.nix).
          backup-state = b.package;
          restore-state = b.restore;
          # The tailnet policy (tailscale/policy.nix); scripts/tailscale-policy
          # writes it to the site's tailscale/policy.hujson.
          tailscale-policy = pkgs.writeText "policy.hujson" (
            import ../tailscale/policy.nix { inventory = inv; }
          );
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # The nightly backup is a scheduled job (launchd, a systemd
          # timer), not a tinytrader service: each role's, by its option.
          backup = enable: {
            backup = {
              inherit enable;
              observe.port = null;
            };
          };
          # The batch scheduler's agent (modules/nomad.nix), not a tinytrader
          # service either.
          nomad =
            c:
            lib.optionalAttrs (c.tinytrader-deploy ? nomad) {
            nomad = {
              inherit (c.tinytrader-deploy.nomad) enable;
              observe.port = c.tinytrader-deploy.nomad.ports.http;
            };
          };
          runnerAttr = (inv.deployment.native.runner or { }).attr or name;
          roles =
            lib.mapAttrs (
              host: example:
              let
                c = example.config;
              in
              c.tinytrader.services
              # The CI runner is nix-darwin's github-runners, not a tinytrader service.
              // lib.optionalAttrs (c.services ? github-runners && c.services.github-runners ? ${runnerAttr}) {
                runner = {
                  inherit (c.services.github-runners.${runnerAttr}) enable;
                };
              }
              // backup c.tinytrader-deploy.backup.enable
              // nomad c
            ) examples.darwin
            // lib.mapAttrs (
              host: example:
              example.config.tinytrader.services
              // backup (example.config.systemd.timers ? tinytrader-backup)
              // nomad example.config
            ) examples.nixos;
        in
        # The placement map against compose.yaml, the role modules, the data
        # roots and the secrets (docs/decisions/0005).
        import ../checks/placement.nix {
          inherit
            pkgs
            compose
            endpoints
            roles
            ;
          inventory = inv;
        }
        # The backup covers every stateful mount compose.yaml makes, runs
        # where the containers do, and keeps its retention (checks/backup.nix).
        # No container mounts inside a data root it isn't granted
        # (checks/data-roots.nix).
        // import ../checks/data-roots.nix {
          inherit pkgs compose;
          inventory = inv;
        }
        // import ../checks/backup.nix {
          inherit pkgs compose;
          inventory = inv;
          backupState = packages.${system}.backup-state;
        }
        // {
          # compose.yaml's project is the deployment's name (inventory.nix
          # deployment.name): the monitor, the backup and scripts/deploy
          # find the containers by it.
          compose-name =
            pkgs.runCommand "compose-name" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
              got="$(yq -r '.name // ""' ${compose})"
              if [ "$got" != ${lib.escapeShellArg name} ]; then
                echo "compose-name: compose.yaml's name is '$got', the inventory's deployment.name '${name}': make them the same" >&2
                exit 1
              fi
              touch $out
            '';
          # Each Mac's auto-deploy agent is off unless asked for, and when on
          # runs scripts/auto-deploy from the stack's deploy checkout, never a
          # working copy (modules/auto-deploy-darwin.nix, docs/decisions/0012);
          # the backup copies the same checkouts.
          auto-deploy =
            let
              user = "example"; # the examples' primary user
              root = "/Users/${user}/.local/share/tinytrader/deploy";
              one =
                host: example:
                let
                  off = example.config.launchd.user.agents;
                  onConfig =
                    (example.extendModules {
                      modules = [ { tinytrader-deploy.autoDeploy.enable = true; } ];
                    }).config;
                  on = onConfig.launchd.user.agents;
                  agent = on.tinytrader-auto-deploy.serviceConfig;
                  args = agent.ProgramArguments;
                  backupEnv = onConfig.launchd.daemons.tinytrader-backup.serviceConfig.EnvironmentVariables;
                in
                assert lib.assertMsg (!(off ? tinytrader-auto-deploy)) "${host}: auto-deploy is on by default";
                assert onConfig.tinytrader-deploy.deployRoot == root;
                assert lib.last (lib.init args) == "${root}/tinytrader-deploy/scripts/auto-deploy";
                assert lib.last args == "--scheduled";
                assert agent.EnvironmentVariables.TINYTRADER_SRC == "${root}/tinytrader";
                assert agent.EnvironmentVariables.TINYTRADER_SITE == "${root}/${name}";
                assert agent.EnvironmentVariables.TINYTRADER_DEPLOY_ROOT == root;
                assert !onConfig.tinytrader-deploy.backup.enable || backupEnv.TINYTRADER_DEPLOY_ROOT == root;
                assert onConfig.environment.variables.TINYTRADER_DEPLOY_ROOT == root;
                true;
            in
            assert lib.all lib.id (lib.mapAttrsToList one examples.darwin);
            pkgs.runCommand "auto-deploy" { } "touch $out";
        }
        // lib.optionalAttrs (policy != null) {
          # The site's tailscale/policy.hujson is what tailscale/policy.nix
          # makes of the inventory (scripts/tailscale-policy rewrites it).
          tailscale-policy =
            pkgs.runCommand "tailscale-policy"
              {
                committed = policy;
                generated = packages.${system}.tailscale-policy;
              }
              ''
                if ! diff -u "$committed" "$generated" >&2; then
                  echo "tailscale/policy.hujson is out of date: run scripts/tailscale-policy" >&2
                  exit 1
                fi
                touch $out
              '';
        }
        // lib.optionalAttrs checkStack {
          # Nothing of this site in the stack it uses (a backstop for the
          # stack's own checks.generic, which can't know the site's names):
          # its tailnet domain, its deployment name, and the words it lists
          # as private (inventory.nix deployment.privateWords: user names,
          # machine names, account names). The stack's example/ is skipped.
          stack-generic =
            let
              words = lib.filter (w: w != "" && w != "tinytrader") (
                [
                  (inv.tailnet.domain or "")
                  name
                ]
                ++ (inv.deployment.privateWords or [ ])
              );
              stackSrc = lib.fileset.toSource {
                root = ../.;
                fileset = lib.fileset.difference ../. ../example;
              };
            in
            pkgs.runCommand "stack-generic" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
              cd ${stackSrc}
              status=0
              ${lib.concatMapStrings (w: ''
                if grep -rnIwF -- ${lib.escapeShellArg w} .; then
                  echo "stack-generic: tinytrader-deploy mentions this site's ${lib.escapeShellArg w}" >&2
                  status=1
                fi
              '') words}
              [ "$status" -eq 0 ] && touch $out
            '';
        }
        // lib.optionalAttrs (builtins.pathExists secrets) {
          # Every file under secrets/ (dotenv, or YAML like databento.yaml)
          # except READMEs and the *.example templates (placeholders, never
          # values) must be sops-encrypted.
          secrets-encrypted = pkgs.runCommand "secrets-encrypted" { } ''
            status=0
            for f in $(find ${secrets} -type f); do
              case "$f" in */README.md | *.example) continue ;; esac
              if ! grep -qE "^sops_version=|^sops:$" "$f"; then
                echo "not encrypted with sops: $(basename "$f")" >&2
                status=1
              fi
            done
            [ "$status" -eq 0 ] && touch $out
          '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              sops
              age
              jq
            ];
          };
        }
      );
    in
    {
      inventory = inv;
      inherit
        darwinModules
        nixosModules
        packages
        checks
        devShells
        examples
        ;
      lib = {
        inherit darwinRole nixosRole site;
      };
    };
}
