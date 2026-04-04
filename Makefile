SHELL := /usr/bin/env bash

.DEFAULT_GOAL := help

LIVE_DIR ?= examples/live
ENV ?= dev
SUBENV ?= east
REGION ?= us-east-1
USERS_VARS ?= ansible/vars-schema.example.yml
ANSIBLE_LINT_PATHS ?= ansible/playbooks ansible/roles ansible/group_vars ansible/requirements.yml ansible/vars-schema.example.yml
YAMLLINT_PATHS ?= ansible/playbooks ansible/roles ansible/group_vars ansible/requirements.yml ansible/vars-schema.example.yml
TG_DOWNLOAD_DIR ?= $(abspath .cache/terragrunt)

.PHONY: help install-tools fmt fmt-check lint validate check shell-test policy-test contract-test ansible-test test plan-example apply-example apply-example-auto configure-example destroy-example destroy-example-auto

help:
	@echo "Targets:"
	@echo "  install-tools - Install required local toolchain dependencies"
	@echo "  fmt           - Apply formatting for terraform and terragrunt files"
	@echo "  fmt-check     - Check formatting for terraform and terragrunt files"
	@echo "  lint          - Run static linters and policy checks"
	@echo "  validate      - Run terraform, terragrunt, and ansible validation"
	@echo "  check         - Run fmt-check + lint + validate (+ optional preflight)"
	@echo "  shell-test    - Bats tests for scripts (requires bats-core on PATH)"
	@echo "  policy-test   - Validate IAM policy template invariants (jq)"
	@echo "  contract-test - Repo contract checks (log group naming, tool pins, deprecated vars)"
	@echo "  ansible-test  - Localhost Ansible smoke + negative test for user_accounts"
	@echo "  test          - policy-test + contract-test + shell-test + ansible-test"
	@echo "  plan-example  - Run orchestrator plan against example live config"
	@echo "  apply-example - Run orchestrator apply (interactive Terraform; confirm each apply)"
	@echo "  apply-example-auto - Same as apply-example with --auto-approve (CI/non-interactive)"
	@echo "  configure-example - Run Ansible-only host configuration against example live config"
	@echo "  destroy-example - Run orchestrator destroy (interactive Terraform)"
	@echo "  destroy-example-auto - Same as destroy-example with --auto-approve"

install-tools:
	@if command -v mise >/dev/null 2>&1; then \
		echo "Installing mise-managed tools from .tool-versions"; \
		mise install; \
	else \
		echo "mise not found; skipping .tool-versions installation"; \
	fi
	@py=python; command -v $$py >/dev/null 2>&1 || py=python3; \
	command -v $$py >/dev/null 2>&1 || { echo "python or python3 required for install-tools" >&2; exit 1; }; \
	PIP_BREAK_SYSTEM_PACKAGES=1 $$py -m pip install --upgrade pip; \
	PIP_BREAK_SYSTEM_PACKAGES=1 $$py -m pip install -r requirements-dev.txt
	@mkdir -p .ansible/tmp .ansible/home ansible/collections "$(TG_DOWNLOAD_DIR)"
	HOME="$(PWD)/.ansible/home" ANSIBLE_LOCAL_TEMP="$(PWD)/.ansible/tmp" ANSIBLE_CONFIG="$(PWD)/ansible.cfg" \
		ansible-galaxy collection install -r ansible/requirements.yml -p ansible/collections

fmt:
	terraform fmt -recursive modules examples
	terragrunt hcl format --working-dir terragrunt --exclude-dir .terragrunt-cache --exclude-dir .terraform
	terragrunt hcl format --working-dir examples/live --exclude-dir .terragrunt-cache --exclude-dir .terraform

fmt-check:
	terraform fmt -check -recursive modules examples
	terragrunt hcl format --check --working-dir terragrunt --exclude-dir .terragrunt-cache --exclude-dir .terraform
	terragrunt hcl format --check --working-dir examples/live --exclude-dir .terragrunt-cache --exclude-dir .terraform

lint: install-tools
	tflint --init
	@for module in modules/terraform/*; do \
		echo "tflint $$module"; \
		tflint --chdir "$$module"; \
	done
	tfsec modules/terraform
	checkov -d modules/terraform
	ansible-lint $(ANSIBLE_LINT_PATHS)
	yamllint $(YAMLLINT_PATHS)
	shellcheck scripts/*.sh

validate: install-tools
	@for module in modules/terraform/*; do \
		echo "terraform validate $$module"; \
		terraform -chdir="$$module" init -backend=false -input=false -no-color > /dev/null; \
		terraform -chdir="$$module" validate; \
	done
	@for stack in $$(find examples/live -type d -name .terragrunt-cache -prune -o -type d -name .terraform -prune -o -type f -name terragrunt.hcl -exec dirname {} \; | sort); do \
		echo "terragrunt hcl validate --inputs --working-dir $$stack"; \
		TG_DOWNLOAD_DIR="$(TG_DOWNLOAD_DIR)" terragrunt hcl validate --inputs --working-dir "$$stack"; \
	done
	ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/jump_hosts.yml --syntax-check
	ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/decommission.yml --syntax-check

check: install-tools fmt-check lint validate
	@if [[ "$${SKIP_PREFLIGHT:-false}" == "true" ]]; then \
		echo "Skipping AWS SSM preflight (SKIP_PREFLIGHT=true)."; \
	else \
		scripts/preflight_ssm_compliance.sh \
			--region "$${AWS_REGION:?AWS_REGION is required when SKIP_PREFLIGHT is false}" \
			--expected-log-group "$${EXPECTED_LOG_GROUP:?EXPECTED_LOG_GROUP is required when SKIP_PREFLIGHT is false}"; \
	fi

shell-test:
	@command -v bats >/dev/null 2>&1 || { echo "bats not found; install bats-core (e.g. apt install bats or brew install bats-core)" >&2; exit 1; }
	bats tests/shell/*.bats

policy-test:
	./tests/policy/validate_ssm_policy.sh policy-templates/ssm-access-example.json

contract-test:
	./tests/contracts/check_log_group.sh
	./tests/contracts/check_tool_pins.sh
	./tests/contracts/check_deprecated_vars.sh

ansible-test: install-tools
	@mkdir -p .ansible/tmp .ansible/home
	HOME="$(PWD)/.ansible/home" ANSIBLE_LOCAL_TEMP="$(PWD)/.ansible/tmp" ANSIBLE_CONFIG="$(PWD)/ansible.cfg" \
		ansible-playbook -i tests/ansible/inventory/localhost.yml tests/ansible/user_accounts_smoke.yml
	@set +e; \
	HOME="$(PWD)/.ansible/home" ANSIBLE_LOCAL_TEMP="$(PWD)/.ansible/tmp" ANSIBLE_CONFIG="$(PWD)/ansible.cfg" \
		ansible-playbook -i tests/ansible/inventory/localhost.yml tests/ansible/user_accounts_negative.yml; \
	neg=$$?; \
	set -e; \
	if [[ "$$neg" -eq 0 ]]; then echo "ansible-test: expected user_accounts_negative.yml to fail" >&2; exit 1; fi

test: policy-test contract-test shell-test ansible-test

plan-example:
	./scripts/orchestrate.sh plan --live-dir "$(LIVE_DIR)" --env "$(ENV)" --subenv "$(SUBENV)" --region "$(REGION)" --users-vars "$(USERS_VARS)"

apply-example:
	./scripts/orchestrate.sh apply --live-dir "$(LIVE_DIR)" --env "$(ENV)" --subenv "$(SUBENV)" --region "$(REGION)" --users-vars "$(USERS_VARS)"

apply-example-auto:
	./scripts/orchestrate.sh apply --live-dir "$(LIVE_DIR)" --env "$(ENV)" --subenv "$(SUBENV)" --region "$(REGION)" --users-vars "$(USERS_VARS)" --auto-approve

configure-example:
	./scripts/orchestrate.sh configure --live-dir "$(LIVE_DIR)" --env "$(ENV)" --subenv "$(SUBENV)" --region "$(REGION)" --users-vars "$(USERS_VARS)"

destroy-example:
	./scripts/orchestrate.sh destroy --live-dir "$(LIVE_DIR)" --env "$(ENV)" --subenv "$(SUBENV)" --region "$(REGION)" --users-vars "$(USERS_VARS)"

destroy-example-auto:
	./scripts/orchestrate.sh destroy --live-dir "$(LIVE_DIR)" --env "$(ENV)" --subenv "$(SUBENV)" --region "$(REGION)" --users-vars "$(USERS_VARS)" --auto-approve
