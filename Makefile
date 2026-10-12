# The Makefile is this repo's interface: the README, CI and tests all go through it.
.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash
PYTHON ?= python3

# Pinned check tools, installed into .tools/ by `make iac-tools`.
TOOLS := $(CURDIR)/.tools
export TFLINT_PLUGIN_DIR := $(TOOLS)/tflint-plugins
RENDERED := build/guardrails.json

.PHONY: help check test-hooks check-actions fmt-check validate test-tf \
	iac-tools tflint trivy checkov render-policies test-policies test-iac simulate-policies \
	check-gitops helm-template up down waves check-waves parity cutover rollback

help: ## List the targets
	@grep -E '^[a-z0-9%-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

up: ## Bring up the old and new kind clusters, Argo CD and app01-app06 on old (needs Docker; see README)
	scripts/local-up.sh

down: ## Remove every kind cluster and container `make up` created
	scripts/local-down.sh

wave-%: ## Bring wave N (wave-1, wave-2, ...) up on new through Argo CD; earlier waves must be healthy first
	scripts/wave.sh $*

WAVE ?= 1
parity: ## Compare old and new for the apps in waves 1..WAVE (default 1): status, chosen headers, JSON shape
	$(PYTHON) scripts/parity.py $(WAVE)

cutover: ## Print the plan to switch wave WAVE's routing to new and scale old to 0; CONFIRM=1 applies it
	$(PYTHON) scripts/cutover.py cutover $(WAVE) $(if $(filter 1,$(CONFIRM)),--confirm)

rollback: ## Print the plan to restore wave WAVE's replicas and routing on old; CONFIRM=1 applies it
	$(PYTHON) scripts/cutover.py rollback $(WAVE) $(if $(filter 1,$(CONFIRM)),--confirm)

waves: ## Regenerate gitops/apps/ and gitops/waves/ from gitops/waves.toml
	$(PYTHON) scripts/generate-waves.py

check-waves: waves ## Fail if the committed gitops/apps/ and gitops/waves/ differ from what the generator writes
	@git diff --exit-code -- gitops/apps gitops/waves || { echo "Generated GitOps files drifted: run make waves and commit the result." >&2; exit 1; }
	@untracked="$$(git ls-files --others --exclude-standard -- gitops/apps gitops/waves)"; \
	  if [ -n "$$untracked" ]; then echo "Generated files not committed: $$untracked" >&2; exit 1; fi

check: test-hooks check-actions check-waves test-iac check-gitops helm-template ## Run every static check the PR workflow runs

test-hooks: ## Test the agent guard hooks and repo scripts
	$(PYTHON) -m unittest discover -s tests -t . -v

check-actions: ## Fail if any GitHub Action is not pinned to a commit SHA
	$(PYTHON) scripts/check_pinned_actions.py .github/workflows

fmt-check: ## Check Terraform formatting under iac/
	terraform fmt -check -recursive -diff iac

validate: ## Run terraform validate on every folder under iac/
	scripts/terraform-validate.sh iac

test-tf: ## Run terraform test (mock providers, no credentials) under iac/
	scripts/terraform-test.sh iac

iac-tools: ## Install the pinned tflint, trivy, kubeconform, helm, checkov and pytest into .tools/
	PYTHON=$(PYTHON) scripts/install-iac-tools.sh

tflint: iac-tools ## Lint every folder under iac/ with tflint and its AWS ruleset
	$(TOOLS)/bin/tflint --chdir iac --recursive --config "$(CURDIR)/.tflint.hcl"

trivy: iac-tools ## Scan iac/ for misconfigurations with trivy
	$(TOOLS)/bin/trivy config --quiet --exit-code 1 iac

checkov: iac-tools ## Scan iac/ for misconfigurations with checkov
	$(TOOLS)/venv/bin/checkov --directory iac --framework terraform --quiet --compact

test-policies: iac-tools ## Test the IAM policy JSON under iac/stage/iam with pytest
	$(TOOLS)/venv/bin/pytest iac/stage/iam

test-iac: fmt-check validate test-tf tflint trivy checkov test-policies ## Run every IaC check, with no cloud credentials

check-gitops: iac-tools ## Validate every manifest under gitops/ with kubeconform, CRD schemas included
	scripts/check-gitops.sh gitops tests/fixtures/gitops-invalid

helm-template: iac-tools ## Render the Argo CD Helm values for both clusters and validate the output
	scripts/helm-template.sh iac/local/argocd build/helm
