# Same for_each pattern as terraform/namespaces.tf.
resource "kubernetes_namespace" "this" {
  for_each = toset(["violetboard", "echoo", "monitoring"])

  metadata {
    name = each.value
  }

  # Wait for k3s to actually be reachable (kubeconfig fetched) before
  # trying to talk to it - same idea as depends_on = [null_resource.k3d_cluster]
  # in the local terraform/ setup, just pointed at the GCP equivalent.
  depends_on = [null_resource.fetch_kubeconfig]
}