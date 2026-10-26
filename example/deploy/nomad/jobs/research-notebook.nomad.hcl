# A research notebook (research/*.ipynb), run top to bottom in the research
# image with its outputs saved in place.
# Dispatched with scripts/job run research-notebook ...; registered by scripts/job register
# (auto-deploy does it when this folder changes). Never retried.
job "research-notebook" {
  type     = "batch"
  priority = 30

  parameterized {
    meta_required = ["notebook"]
    meta_optional = ["when", "not_before"]
  }
  # Defaults a dispatch may override: when (anytime, after-close,
  # background-may-run) and not_before (Unix seconds).
  meta {
    when       = "background-may-run"
    not_before = ""
  }
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
        GATE_CHECK      = "notebook=^[a-z0-9-]+\\.ipynb$"
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

    task "notebook" {
      driver = "docker"
      config {
        image        = "my-site/research:local"
        network_mode = "${meta.docker_network}"
        work_dir     = "/work"
        # The deadline: 2 h from the start.
        command = "timeout"
        args    = ["7200", "jupyter", "nbconvert", "--to", "notebook", "--execute", "--inplace", "${NOMAD_META_notebook}"]
        volumes = ["${meta.site_checkout}/research:/work"]
      }
      env {
        TT_CONSOLE = "${meta.tt_console}"
      }
      resources {
        cpu    = 128
        memory = 2048
      }
    }
  }
}
