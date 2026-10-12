# Argo CD, and one root app that syncs gitops/platform. That folder holds the
# AppProject and the ApplicationSet that turns every
# gitops/<domain>/<service>/ folder into an Application, so after this apply
# Argo CD does the rest from git.

locals {
  argo_helm_repository = "https://argoproj.github.io/argo-helm"
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = local.argo_helm_repository
  chart            = "argo-cd"
  version          = "10.9.6"
  wait             = true
  timeout          = 600

  values = [yamlencode({
    global = { domain = "argocd.${var.dns_zone}" }
    configs = {
      cm = {
        # No shared local password: people reach Argo CD with their own
        # cluster access (`argocd --core`) or through the organization's SSO.
        "admin.enabled" = false
      }
      params = { "server.insecure" = false }
    }
    # The UI stays inside the cluster; reach it with a port-forward.
    server = { ingress = { enabled = false } }
    dex    = { enabled = false }
  })]

  depends_on = [aws_eks_node_group.this, aws_eks_addon.core]
}

resource "helm_release" "root_app" {
  name       = "root-app"
  namespace  = "argocd"
  repository = local.argo_helm_repository
  chart      = "argocd-apps"
  version    = "2.0.6"

  values = [yamlencode({
    applications = {
      platform = {
        namespace = "argocd"
        project   = "default"
        source = {
          repoURL        = var.gitops_repo_url
          targetRevision = "main"
          path           = "gitops/platform"
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "argocd"
        }
        syncPolicy = {
          automated = { prune = true, selfHeal = true }
        }
      }
    }
  })]

  # The Application CRD ships with the argo-cd chart.
  depends_on = [helm_release.argocd]
}
