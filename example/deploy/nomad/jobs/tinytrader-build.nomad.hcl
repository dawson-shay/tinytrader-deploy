# A release build of one tinytrader package, on the Mac itself (raw_exec, as
# the agent's user) in the node's tinytrader deploy checkout, never a
# working copy, under macOS background QoS (taskpolicy -b). By default after
# the close: no builds 09:25-16:20 New York time on trading days
# (CONTRIBUTING.md).
# Dispatched with scripts/job run tinytrader-build ...; registered by scripts/job register
# (auto-deploy does it when this folder changes). Never retried.
job "tinytrader-build" {
  type     = "batch"
  priority = 40

  parameterized {
    meta_required = ["package"]
    meta_optional = ["when", "not_before"]
  }
  # Defaults a dispatch may override: when (anytime, after-close,
  # background-may-run) and not_before (Unix seconds).
  meta {
    when       = "after-close"
    not_before = ""
  }
  # A node that builds (inventory.nix deployment.nomad.nodes.<host>.builds), on macOS
  # (taskpolicy).
  constraint {
    attribute = "${meta.tinytrader_src}"
    operator  = "is_set"
  }
  constraint {
    attribute = "${attr.kernel.name}"
    value     = "darwin"
  }

  group "run" {
    restart {
      attempts = 0
      mode     = "fail"
    }
    reschedule {
      attempts  = 0
      unlimited = false
    }
    # The gate (tinytrader-deploy's deploy/nomad/gate.sh): checks the parameters, then waits
    # for the job's start conditions; the work starts after it.
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
        GATE_CHECK      = "package=^[a-z][a-z0-9-]*$"
        GATE_WHEN       = "${NOMAD_META_when}"
        GATE_NOT_BEFORE = "${NOMAD_META_not_before}"
        GATE_CALENDAR   = "${meta.gate_calendar}"
        GATE_YIELD_TO   = "${meta.gate_yield_to}"
      }
      resources {
        cpu    = 20
        memory = 32
      }
    }

    task "cargo" {
      driver = "raw_exec"
      config {
        command = "/usr/sbin/taskpolicy"
        # In the checkout, with the deadline (90 min from the start).
        args = [
          "-b", "/bin/sh", "-c", "cd \"$1\" && shift && exec \"$@\"", "sh",
          "${meta.tinytrader_src}",
          "timeout", "5400", "cargo", "build", "-j", "2", "--release", "-p", "${NOMAD_META_package}",
        ]
      }
      resources {
        cpu    = 2000
        memory = 2048
      }
    }
  }
}
