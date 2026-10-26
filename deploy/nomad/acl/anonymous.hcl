# What a request without a token may do (scripts/nomad-bootstrap applies it):
# read everything, logs and allocation files included, from the UI on any
# device on the tailnet. Submitting, dispatching, stopping and draining take
# the management token (the site's secrets/nomad.env; scripts/job uses it), because
# containers reach the agents' loopback too and raw_exec runs commands on
# the host.
namespace "*" {
  policy       = "read"
  capabilities = ["read-logs", "read-fs"]
}
node {
  policy = "read"
}
node_pool "*" {
  policy = "read"
}
agent {
  policy = "read"
}
operator {
  policy = "read"
}
plugin {
  policy = "read"
}
