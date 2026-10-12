# The Makefile is this repo's interface: the README, CI and tests all go through it.
.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash
PYTHON ?= python3

# Pinned check tools, installed into .tools/ by `make iac-tools`.
TOOLS := $(CURDIR)/.tools
export TFLINT_PLUGIN_DIR := $(TOOLS)/tflint-plugins

.PHONY: help check test-hooks check-actions fmt-check validate test-tf \
	iac-tools tflint trivy checkov test-policies test-iac check-gitops

help: ## List the targets
	@grep -E '^[a-z0-9%-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

check: test-hooks check-actions test-iac check-gitops ## Run every static check the PR workflow runs

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

iac-tools: ## Install the pinned tflint, trivy, kubeconform, checkov and pytest into .tools/
	PYTHON=$(PYTHON) scripts/install-iac-tools.sh

tflint: iac-tools ## Lint every folder under iac/ with tflint and its AWS ruleset
	$(TOOLS)/bin/tflint --chdir iac --recursive --config "$(CURDIR)/.tflint.hcl"

trivy: iac-tools ## Scan iac/ for misconfigurations with trivy
	$(TOOLS)/bin/trivy config --quiet --exit-code 1 iac

checkov: iac-tools ## Scan iac/ for misconfigurations with checkov
	$(TOOLS)/venv/bin/checkov --directory iac --framework terraform --quiet --compact

test-policies: iac-tools ## Test every IAM policy JSON under iac/stage/iam/ with pytest
	$(TOOLS)/venv/bin/pytest iac/stage/iam

test-iac: fmt-check validate test-tf tflint trivy checkov test-policies ## Run every IaC check, with no cloud credentials

check-gitops: iac-tools ## Validate every manifest under gitops/ with kubeconform, CRD schemas included
	scripts/check-gitops.sh gitops tests/fixtures/gitops-invalid
