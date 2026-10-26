# A Nomad agent: the batch scheduler (docs/batch-jobs.md). The options and
# the agent configuration they make, shared by the darwin (launchd) and
# NixOS (services.nomad) modules beside it. Generic: nothing here names a
# host, a layout or a workload. Which machine is the server, each node's
# pool, budget and metadata are the site's (inventory.nix deployment.nomad,
# through deploy/nomad/node.nix).
#
# Everything listens on loopback. A host reaches another's agent through
# `tailscale serve` there (inventory.nix's `nomad` ports, scripts/tailnet-serve),
# so the addresses an agent advertises are its tailnet address.
#
# ACLs are on: containers reach the host's loopback (host.docker.internal),
# and raw_exec runs commands on the host as the agent's user, so an
# anonymous API would let any container do that. The anonymous policy is
# read-only (deploy/nomad/acl/anonymous.hcl, or the site's own, applied by
# scripts/nomad-bootstrap with the management token it stores in
# the site's secrets/nomad.env).
{ config, lib, ... }:
let
  inherit (lib) mkOption mkEnableOption types optionalAttrs;
  cfg = config.tinytrader-deploy.nomad;
  addr = port: "${cfg.advertise}:${toString port}";
in
{
  options.tinytrader-deploy.nomad = {
    enable = mkEnableOption "a Nomad agent (server, client, or both)";

    package = mkOption {
      type = types.package;
      description = "Nomad. nixpkgs marks it unfree (BSL): the machine allows it by name.";
    };

    datacenter = mkOption {
      type = types.str;
      default = "dc1";
    };

    server = {
      enable = mkEnableOption "the server (the scheduler and its state)";
      bootstrapExpect = mkOption {
        type = types.ints.positive;
        default = 1;
      };
    };

    servers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "server.example.net:4647" ];
      description = "The servers' RPC addresses (host:port), for a client that isn't one.";
    };

    dataDir = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "The agent's state. null: the platform module's default.";
    };

    ports = {
      http = mkOption {
        type = types.port;
        default = 4646;
      };
      rpc = mkOption {
        type = types.port;
        default = 4647;
      };
      serf = mkOption {
        type = types.port;
        default = 4648;
      };
    };

    bind = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Where the agent listens. Other hosts reach it through a forward (tailscale serve).";
    };

    advertise = mkOption {
      type = types.str;
      # The first address in Tailscale's range (100.64.0.0/10), whatever
      # the interface is called; a go-sockaddr template, read at start.
      default = ''{{ GetAllInterfaces | include "network" "100.64.0.0/10" | attr "address" }}'';
      description = "The address other agents and the CLI are told to use (an IP, or a go-sockaddr template).";
    };

    acl = mkOption {
      type = types.bool;
      default = true;
    };

    client = {
      enable = mkEnableOption "the client (runs work)";
      nodePool = mkOption {
        type = types.str;
        default = "default";
      };
      meta = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Node metadata: what jobs constrain on and read (\${meta.<key>}).";
      };
      memoryMB = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = "The memory jobs may reserve here, in MiB: the node's budget, not its RAM. null: all of it.";
      };
      cpuMHz = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = "Total CPU in MHz. Needed on Apple Silicon, whose clock Nomad can't read (cores x 1000 is fine).";
      };
      allocDir = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Where allocations live. Under $HOME on a Mac with Colima, which shares only $HOME with its VM.";
      };
      dockerSocket = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "The Docker engine's socket. null: no docker driver.";
      };
      rawExec = mkOption {
        type = types.bool;
        default = true;
        description = "Commands on the host itself, as the agent's user (host builds, the jobs' gate).";
      };
    };

    extraSettings = mkOption {
      type = types.attrs;
      default = { };
      description = "Merged over the generated configuration.";
    };

    settings = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "The agent configuration (JSON), from the options above.";
    };
  };

  config.tinytrader-deploy.nomad.settings = lib.recursiveUpdate (
    {
      inherit (cfg) datacenter;
      bind_addr = cfg.bind;
      ports = cfg.ports;
      advertise = {
        http = addr cfg.ports.http;
        rpc = addr cfg.ports.rpc;
        serf = addr cfg.ports.serf;
      };
      acl.enabled = cfg.acl;
      # Nomad's anonymous usage reports and update checks: off.
      disable_update_check = true;
      telemetry.disable_hostname = true;
    }
    // optionalAttrs (cfg.dataDir != null) { data_dir = cfg.dataDir; }
    // optionalAttrs cfg.server.enable {
      server = {
        enabled = true;
        bootstrap_expect = cfg.server.bootstrapExpect;
        # Preemption (open source since Nomad 0.12, off by default): a job
        # that can't be placed evicts lower-priority work, by 10 or more.
        default_scheduler_config.preemption_config = {
          batch_scheduler_enabled = true;
          service_scheduler_enabled = true;
          sysbatch_scheduler_enabled = true;
          system_scheduler_enabled = true;
        };
      };
    }
    // optionalAttrs cfg.client.enable {
      client = {
        enabled = true;
        node_pool = cfg.client.nodePool;
        inherit (cfg.client) meta;
      }
      // optionalAttrs (!cfg.server.enable) { inherit (cfg) servers; }
      // optionalAttrs (cfg.client.memoryMB != null) { memory_total_mb = cfg.client.memoryMB; }
      // optionalAttrs (cfg.client.cpuMHz != null) { cpu_total_compute = cfg.client.cpuMHz; }
      // optionalAttrs (cfg.client.allocDir != null) { alloc_dir = cfg.client.allocDir; };
      plugin =
        optionalAttrs cfg.client.rawExec { raw_exec.config.enabled = true; }
        // optionalAttrs (cfg.client.dockerSocket != null) {
          docker.config = {
            endpoint = "unix://${cfg.client.dockerSocket}";
            # Host paths into containers (a job's working folder).
            volumes.enabled = true;
            allow_privileged = false;
            # Keep images: some are built here and can't be pulled back.
            gc.image = false;
          };
        };
    }
  ) cfg.extraSettings;
}
