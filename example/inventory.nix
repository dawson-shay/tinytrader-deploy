# An example site's inventory: the fleet as data (docs/site.md). Every name,
# address and key here is made up. Host configs, deploy targets and the
# console's topology graph all read from it, so they cannot drift apart.
#
# The example: two Macs and a NAS still to come.
#   desk   a Mac (Colima): the services' host. Every container, the Databento
#          key's holders, CI for the site, the nightly backup.
#   vault  a Mac with the store's drive attached: the store, alpaca-history
#          beside it, the research notebooks.
#   nas    planned (NixOS): the store and its disks, later.
{
  hosts = {
    desk = {
      system = "aarch64-darwin";
      os = "darwin";
      role = "The services' host: every container, the Databento key's holders, CI";
      tailnetName = "desk";
      runtime = "docker-compose"; # under Colima; the machine's config is your machines repository's
      status = "active";
      # What its monitor watches besides its services (`monitoring`).
      watch.disks = [ "/" ];
    };
    vault = {
      system = "aarch64-darwin";
      os = "darwin";
      role = "The store and its drive, research";
      tailnetName = "vault";
      runtime = "docker-compose";
      status = "active";
      # The internal disk and the store's drive (unplugged is an alert too).
      watch.disks = [
        "/"
        "/Volumes/market"
      ];
    };
    nas = {
      system = "x86_64-linux";
      os = "nixos";
      runtime = "systemd";
      role = "The store and its disks, background work";
      tailnetName = "nas";
      status = "planned";
      watch.disks = [ "/" ]; # and the store's volumes (modules/nas.nix)
    };
  };

  # Who can decrypt each file under secrets/ (docs/decisions/0004). The
  # operator and recovery keys decrypt everything but the `hostOnly` files;
  # a host decrypts only the files granted to it, for the services it runs.
  # Recipients are age public keys (placeholders here): `age-keygen` makes a
  # key, `ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub` a host's.
  # scripts/secrets-recipients writes .sops.yaml from this and re-encrypts
  # the files.
  secrets = {
    operator = "age1-your-operator-public-key";
    recovery = "age1-your-offline-recovery-public-key";
    hosts = {
      # desk's SSH host key, for the files only its own services may read
      # (hostOnly): sops-nix decrypts them there as root.
      desk = "age1-desk-ssh-host-key";
      nas = null;
    };
    # Machines you sit at, which decrypt with the operator key rather than a
    # host key of their own. A service placed on one may use any file but a
    # hostOnly one.
    operatorKeyHosts = [
      "desk"
      "vault"
    ];
    # Files only their hosts and the recovery key decrypt, never the operator
    # key; their services run natively, as a user of their own
    # (docs/decisions/0013). Changing one: scripts/databento-key.
    hostOnly = [ "databento.yaml" ];
    # File patterns (under secrets/) and the hosts that run their services.
    files = {
      "accounts/*.env" = [ "nas" ];
      "gateway.env" = [ "nas" ];
      "databento.yaml" = [
        "desk"
        "nas"
      ];
      "research.env" = [ "nas" ];
      "runner.env" = [ ];
      "notify.env" = [ "nas" ];
      "store.env" = [
        "nas"
        "desk"
      ];
      "console.env" = [ "nas" ];
    };
  };

  # Each host's monitor (tinytrader's `watch`, docs/decisions/0006).
  monitoring = {
    # Hosts that watch other disks too (a store's drives).
    disk = {
      warnPercent = 90;
      critPercent = 95;
      minFreeGiB = 10;
    };
    # Hosts that watch only "/" (the stack's defaults, docs/decisions/0016):
    # below 15% free a warning, below 20 GiB high priority.
    systemDisk = {
      warnPercent = 85;
      critPercent = 95;
      minFreeGiB = 20;
    };
    # The secrets file and its keys: the ntfy topic URL, and each host's
    # healthchecks.io ping URL.
    notify = {
      file = "notify.env";
      url = "NTFY_URL";
    };
    heartbeat = {
      desk = "HC_PING_DESK";
      vault = "HC_PING_VAULT";
      nas = "HC_PING_NAS";
    };
    # The order gateways' ports: the monitor never connects to them.
    gatewayPorts = [ 7701 ];
    backup.maxAgeHours = 30;
  };

  # The nightly backup of the services host's state (scripts/backup-state).
  backup = {
    at = {
      hour = 2;
      minute = 30;
    };
    keep = {
      daily = 14;
      weekly = 8;
    };
    # Where each host's off-host copy goes, and the account that receives it.
    offHost = {
      desk = "vault";
      vault = "desk";
    };
    accounts = {
      desk = "you";
      vault = "you";
    };
    # Each sending host's backup SSH key, the public half (ssh-keygen -t
    # ed25519 -f ~/.ssh/tinytrader-backup). null: no off-host copy yet.
    keys = {
      desk = null;
      vault = null;
    };
  };

  # Logical data roots. Services name these, never physical paths.
  dataRoots = {
    vault-market = {
      host = "vault";
      path = "/Volumes/market";
      purpose = "The store's volume `market`: market data by provider.";
    };
    tank = {
      host = "nas";
      path = "/tank/market";
      purpose = "The store's volume on the NAS, once it exists.";
    };
  };

  # The tailnet every host is on (docs/decisions/0008, 0010): a service on
  # another host is reached at <tailnetName>.<domain>:<port>. domain is the
  # tailnet's MagicDNS domain (the admin console's DNS page).
  tailnet = {
    domain = "your-tailnet.example";
    tag = "tag:tinytrader";
  };

  # What tinytrader-deploy needs beyond the placement map (docs/site.md).
  deployment = {
    # The Compose project (compose.yaml `name`), the state directory
    # (~/.local/state/my-site) and the deploy checkout's name.
    name = "my-site";
    # The capture hours, New York time: the relays capture then, and
    # background work yields.
    captureHours = "09:25-16:20";
    # What scripts/auto-deploy never deploys by itself.
    autoDeploy.never = [
      "order-gateway-*"
      "relay-*"
    ];
    hosts = {
      desk.dockerSocket = ".colima/default/docker.sock";
      vault = {
        dockerSocket = ".colima/default/docker.sock";
        # No deploy checkouts here (auto-deploy runs on desk): the site
        # checkout research jobs mount, relative to the home or absolute.
        siteCheckout = "src/my-site";
      };
    };
    # The batch scheduler's policy (deploy/nomad/node.nix): the server, each
    # node's budget and part, and what background work on a feed host
    # yields to. `scripts/job pool off <node>` takes a node out for a while.
    nomad = {
      server = "desk";
      nodes = {
        desk = {
          memoryMB = 4096;
          cpuMHz = 10000;
          feed = true;
          builds = true;
          # The disk-hygiene job's roots: agent worktrees and the shared
          # cargo targets (docs/operations.md, Agent hygiene).
          cleanRoots = [
            "repos"
            ".cache/cargo-target"
          ];
        };
        vault = {
          memoryMB = 3072;
          cpuMHz = 8000;
        };
        nas = {
          memoryMB = 8192;
          cpuMHz = 8000;
        };
      };
      yieldTo = [ "relay-opra-spy" ];
    };
    native = {
      store = {
        volumes = [
          {
            name = "market";
            root = "vault-market";
          }
        ];
        discover = "/Volumes";
      };
      alpaca-history = {
        keys = "accounts/paper.env";
        yieldTo = [ "relay-opra-spy" ];
      };
      relay-opra-spy.symbols = "SPY.OPT";
      queue-host-runner.enable = false;
      runner.url = "https://github.com/your-name/my-site";
    };
  };

  # What runs where (docs/decisions/0005). Each service:
  #   host          the inventory host that runs it
  #   runtime       "compose" (deploy/local/compose.yaml), "launchd" (a
  #                 nix-darwin role) or "systemd" (a NixOS role)
  #   ports         the ports it serves, by name: { http = 8080; }
  #   uses          the services it connects to, "name" (every port) or "name:port"
  #   localOnly     never reachable from another host
  #   https         published over HTTPS at its host's tailnet name by `tailscale serve`
  #   usesHttps     services it reaches at that HTTPS address instead of a port
  #   viaHost       containers on its host reach it through the host, not by name
  #   dataRoots     the data roots it reads or writes; each must be on its host
  #   colocateWith  services it must share a host with
  #   secrets       the secrets.files patterns it uses
  #   profile       its Compose profile, if not the default
  #   perHost       instead of host and runtime: a host agent, { <host> = <runtime>; }
  services =
    let
      desk =
        attrs:
        {
          host = "desk";
          runtime = "compose";
        }
        // attrs;
      keyHolder =
        attrs:
        {
          host = "desk";
          runtime = "launchd";
        }
        // attrs;
    in
    {
      # Databento's OPRA options feed for SPY: native, as its own user (it
      # holds the Databento key, decision 0013).
      relay-opra-spy = keyHolder {
        ports = {
          stream = 7600;
          observe = 9110;
        };
        uses = [ "accounts" ];
        secrets = [ "databento.yaml" ];
      };
      # Alpaca's IEX prices: a container.
      relay-iex = desk {
        ports = {
          stream = 7610;
          observe = 9114;
        };
        uses = [ "accounts" ];
        secrets = [ "accounts/*.env" ];
      };
      accounts = desk {
        ports.http = 9107;
        uses = [
          "relay-iex:stream"
          "relay-opra-spy:stream"
        ];
        secrets = [ "accounts/*.env" ];
      };
      alpaca-data = desk {
        ports.http = 9125;
        uses = [ "relay-opra-spy:observe" ];
        secrets = [ "accounts/*.env" ];
      };
      order-gateway-paper = desk {
        ports.orders = 7701;
        secrets = [
          "accounts/*.env"
          "gateway.env"
        ];
      };
      databento-jobs = keyHolder {
        ports.http = 9121;
        uses = [
          "store"
          "accounts"
          "relay-opra-spy:observe"
        ];
        secrets = [
          "databento.yaml"
          "store.env"
        ];
      };
      console = desk {
        ports.http = 8080;
        localOnly = true;
        https = true;
        uses = [
          "docker-proxy"
          "databento-jobs"
          "queue"
          "store"
          "order-gateway-paper"
          "research"
          "node-exporter"
        ];
        colocateWith = [
          "docker-proxy"
          "order-gateway-paper"
        ];
        secrets = [
          "gateway.env"
          "store.env"
          "console.env"
        ];
      };
      docker-proxy = desk {
        ports.http = 2375;
        localOnly = true;
      };
      queue = desk {
        ports.http = 9123;
        uses = [
          "queue-docker-proxy"
          "accounts"
          "console"
          "relay-opra-spy:observe"
        ];
        colocateWith = [ "queue-docker-proxy" ];
      };
      queue-docker-proxy = desk {
        ports.http = 2375;
        localOnly = true;
      };
      queue-host-runner = {
        host = "desk";
        runtime = "launchd";
        uses = [ "queue" ];
        colocateWith = [ "queue" ];
      };

      store = {
        host = "vault";
        runtime = "launchd";
        ports.http = 9120;
        dataRoots = [ "vault-market" ];
        secrets = [ "store.env" ];
      };
      research = {
        host = "vault";
        runtime = "compose";
        ports.http = 8888;
        uses = [ "store" ];
        usesHttps = [ "console" ];
        secrets = [ "research.env" ];
      };
      alpaca-history = {
        host = "vault";
        runtime = "launchd";
        ports.http = 9124;
        uses = [
          "store"
          "relay-opra-spy:observe"
        ];
        secrets = [
          "accounts/*.env"
          "store.env"
        ];
      };

      # Host agents.
      watch = {
        perHost = {
          desk = "launchd";
          vault = "launchd";
          nas = "systemd";
        };
        secrets = [ "notify.env" ];
      };
      backup.perHost.desk = "launchd";
      node-exporter = {
        perHost = {
          desk = "launchd";
          vault = "launchd";
        };
        ports.http = 9100;
      };
      runner = {
        perHost.desk = "launchd";
        secrets = [ "runner.env" ];
      };
      # The batch scheduler (docs/batch-jobs.md): a Nomad agent on each host
      # that runs jobs, the server among them deployment.nomad.server. Each
      # listens on loopback; its ports are forwarded from the tailnet.
      nomad = {
        perHost = {
          desk = "launchd";
          vault = "launchd";
          nas = "systemd";
        };
        ports = {
          http = 4646;
          rpc = 4647;
        };
      };
    };
}
