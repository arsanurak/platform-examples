# Plan-level tests for argocd.tf: Argo CD, and the root app that hands the
# rest of the cluster to gitops/platform.

mock_provider "aws" {
  override_during = plan
}

mock_provider "helm" {}

run "argo_cd_charts_are_pinned" {
  command = plan

  assert {
    condition = (
      helm_release.argocd.repository == "https://argoproj.github.io/argo-helm" &&
      helm_release.argocd.chart == "argo-cd" && helm_release.argocd.version == "10.9.6" &&
      helm_release.root_app.chart == "argocd-apps" && helm_release.root_app.version == "2.0.6"
    )
    error_message = "Argo CD and the root app come from argo-helm at exact versions."
  }
}

run "the_root_app_syncs_gitops_platform" {
  command = plan

  assert {
    condition     = yamldecode(helm_release.root_app.values[0]).applications.platform.source.path == "gitops/platform"
    error_message = "The root app must point at gitops/platform, where the ApplicationSet and AppProject live."
  }

  assert {
    condition     = yamldecode(helm_release.root_app.values[0]).applications.platform.source.repoURL == "https://github.com/arsanurak/platform-examples.git"
    error_message = "The root app must sync from this repository."
  }

  assert {
    condition     = yamldecode(helm_release.root_app.values[0]).applications.platform.source.targetRevision == "main"
    error_message = "The root app must follow main."
  }
}

run "argo_cd_is_not_exposed_and_has_no_local_admin" {
  command = plan

  assert {
    condition     = yamldecode(helm_release.argocd.values[0]).server.ingress.enabled == false
    error_message = "The Argo CD UI is reached through a port-forward, not a public Ingress."
  }

  assert {
    condition     = yamldecode(helm_release.argocd.values[0]).configs.cm["admin.enabled"] == false
    error_message = "The built-in admin account must be off; people sign in through SSO."
  }
}
