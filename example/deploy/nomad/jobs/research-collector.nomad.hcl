# A research collector (research/collect_*.py) in the research image,
# research/ mounted read-write (collectors write their outputs there). No
# Databento key (decision 0013): data comes from the store.
# Dispatched with scripts/job run research-collector ...; registered by scripts/job register
# (auto-deploy does it when this folder changes). Never retried.
job "research-collector" {
  type     = "batch"
  priority = 30

  parameterized {
    meta_required = ["script"]
    meta_optional = ["when", "not_before"]
  }
  # Defaults a dispatch may override: when (anytime, after-close,
  # background-may-run) and not_before (Unix seconds).
  meta {
    when       = "background-may-run"
    not_before = ""
  }
  # A node with this repository checked out (research/ is mounted from it).
  constraint {
    attribute = "${meta.site_checkout}"
    operator  = "is_set"
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
        GATE_CHECK      = "script=^collect_[a-z0-9_]+\\.py$"
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

    task "collect" {
      driver = "docker"
      config {
        image        = "my-site/research:local"
        network_mode = "${meta.docker_network}"
        work_dir     = "/work"
        # The deadline: 4 h from the start (not from the dispatch).
        command = "timeout"
        args    = ["14400", "python", "${NOMAD_META_script}"]
        volumes = ["${meta.site_checkout}/research:/work"]
      }
      env {
        TT_CONSOLE = "${meta.tt_console}"
      }
      # cpu: Docker's CPU shares (a low 128: background work); memory: the
      # limit, and what the job takes of its node's budget.
      resources {
        cpu    = 128
        memory = 1024
      }
    }
  }
}
