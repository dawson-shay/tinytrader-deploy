# Daily disk hygiene on every Mac (tinytrader-deploy's deploy/nomad/disk-hygiene.sh,
# docs/decisions/0016), natively (raw_exec, as the agent's user) under macOS
# background QoS (taskpolicy -b): idle Rust target/ folders under the node's
# cleanRoots (inventory.nix deployment.nomad.nodes.<host>), then
# nix-collect-garbage --delete-older-than 14d, then docker system prune -f
# where an engine answers (volumes kept). After the close: never 09:25-16:20
# New York time on trading days (CONTRIBUTING.md).
# A sysbatch job: each run puts one allocation on every eligible node.
# Registered by scripts/job register; `nomad job periodic force disk-hygiene`
# runs it now (the gate still waits for the close). dry_run = "1" below
# logs what it would remove and removes nothing. Never retried.
job "disk-hygiene" {
  type     = "sysbatch"
  priority = 20

  periodic {
    crons            = ["30 18 * * *"]
    time_zone        = "America/New_York"
    prohibit_overlap = true
  }
  meta {
    dry_run = "0"
  }
  # Every Mac (taskpolicy, /Volumes).
  constraint {
    attribute = "${attr.kernel.name}"
    value     = "darwin"
  }

  group "run" {
    restart {
      attempts = 0
      mode     = "fail"
    }
    # The gate (tinytrader-deploy's deploy/nomad/gate.sh): waits for the close.
    task "gate" {
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }
      driver = "raw_exec"
      config {
        command = "/bin/sh"
        args    = ["local/gate.sh"]
      }
      template {
        data            = file("deploy/nomad/gate.sh")
        destination     = "local/gate.sh"
        perms           = "0755"
        left_delimiter  = "[[gate:"
        right_delimiter = ":gate]]"
      }
      env {
        GATE_WHEN     = "after-close"
        GATE_CALENDAR = "${meta.gate_calendar}"
      }
      resources {
        cpu    = 20
        memory = 32
      }
    }

    task "clean" {
      driver = "raw_exec"
      config {
        command = "/usr/sbin/taskpolicy"
        # With the deadline (1 h from the start).
        args = ["-b", "timeout", "3600", "/bin/sh", "local/disk-hygiene.sh"]
      }
      template {
        data            = file("deploy/nomad/disk-hygiene.sh")
        destination     = "local/disk-hygiene.sh"
        perms           = "0755"
        left_delimiter  = "[[disk:"
        right_delimiter = ":disk]]"
      }
      env {
        DISK_HYGIENE_ROOTS   = "${meta.disk_hygiene_roots}"
        DISK_HYGIENE_DRY_RUN = "${NOMAD_META_dry_run}"
      }
      resources {
        cpu    = 500
        memory = 256
      }
    }
  }
}
