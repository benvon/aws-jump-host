SHELL := /usr/bin/env bash

.DEFAULT_GOAL := help

LIVE_DIR ?= examples/live
ENV ?= dev
SUBENV ?= east
REGION ?= us-east-1
USERS_VARS ?= ansible/vars-schema.example.yml

.PHONY: help fmt fmt-check lint validate check plan-example apply-example destroy-example

help:
	@echo "Targets:"
	@echo "  fmt           - Apply formatting for terraform and terragrunt files"
	@echo "  fmt-check     - Check formatting for terraform and terragrunt files"
	@echo "  lint          - Run static linters and policy checks"
	@echo "  validate      - Run terraform, terragrunt, and ansible validation"
	@echo "  check         - Run fmt-check + lint + validate (+ optional preflight)"
	@echo "  plan-example  - Run orchestrator plan against example live config"
	@echo "  apply-example - Run orchestrator apply against example live config"
	@echo "  destroy-example - Run orchestrator destroy against example live config"

fmt:
	terraform fmt -recursive modules examples
	terragrunt hclfmt

fmt-check:
	terraform fmt -check -recursive modules examples
	terragrunt hclfmt --check

lint:
	@for module in modules/terraform/*; do \
		echo "tflint $$module"; \
		tflint --chdir "$$module"; \
	done
	tfsec modules/terraform
	checkov -d modules/terraform
	ansible-lint ansible
	yamllint .
	shellcheck scripts/*.sh

validate:
	@for module in modules/terraform/*; do \
		echo "terraform validate $$module"; \
		terraform -chdir="$$module" init -backend=false -input=false -no-color > /dev/null; \
		terraform -chdir="$$module" validate; \
	done
	@for stack in $$(find examples/live -type f -name terragrunt.hcl -exec dirname {} \; | sort); do \
		echo "terragrunt validate-inputs $$stack"; \
		terragrunt -chdir="$$stack" validate-inputs; \
	done
	ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/jump_hosts.yml --syntax-check
	ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/decommission.yml --syntax-check

check: fmt-check lint validate
	@if [[ "${SKIP_PREFLIGHT:-false}" == "true" ]]; then \
		echo "Skipping AWS SSM preflight (SKIP_PREFLIGHT=true)."; \
	else \
		scripts/preflight_ssm_compliance.sh \
			--region "$${AWS_REGION:?AWS_REGION is required when SKIP_PREFLIGHT is false}" \
			--expected-log-group "$${EXPECTED_LOG_GROUP:?EXPECTED_LOG_GROUP is required when SKIP_PREFLIGHT is false}"; \
	fi

plan-example:
	./scripts/orchestrate.sh plan --live-dir "$(LIVE_DIR)" --env "$(ENV)" --subenv "$(SUBENV)" --region "$(REGION)" --users-vars "$(USERS_VARS)"

apply-example:
	./scripts/orchestrate.sh apply --live-dir "$(LIVE_DIR)" --env "$(ENV)" --subenv "$(SUBENV)" --region "$(REGION)" --users-vars "$(USERS_VARS)"

destroy-example:
	./scripts/orchestrate.sh destroy --live-dir "$(LIVE_DIR)" --env "$(ENV)" --subenv "$(SUBENV)" --region "$(REGION)" --users-vars "$(USERS_VARS)"
