# Namespace for provisioner-class workloads — Jobs / null_resources that
# configure other systems (in-cluster or out) at deploy time.
#
# Currently empty of k8s objects: the only inhabitant
# (provisioner-headscale-otel.tf) is a null_resource SSH provisioner that
# reaches the Headscale EC2 host directly, with no k8s side. If you want
# the openobserve-bootstrap / openobserve-provisioner Jobs (which ARE
# k8s provisioner-class) folded in here too, that's a separate move —
# they currently live in the `openobserve` namespace alongside the
# server they configure.
resource "kubernetes_namespace" "provisioner" {
  metadata {
    name = "provisioner"
  }
}
