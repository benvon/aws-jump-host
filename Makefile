SHELL := /usr/bin/env bash

.DEFAULT_GOAL := help

.PHONY: help fmt lint validate check plan-example apply-example destroy-example

help:
	@echo "Targets:"
	@echo "  fmt            - Format terraform/terragrunt/yaml where tools are available"
	@echo "  lint           - Run static linters"
	@echo "  validate       - Run terraform/terragrunt/ansible validation"
	@echo "  check          - Run lint + validate + preflight checks"
	@echo "  plan-example   - Run orchestrator plan against examples/live"
	@echo "  apply-example  - Run orchestrator apply against examples/live"
	@echo "  destroy-example- Run orchestrator destroy against examples/live"

fmt:
	@echo "Formatting is scaffolded; full implementation added in later iteration."

lint:
	@echo "Linting is scaffolded; full implementation added in later iteration."

validate:
	@echo "Validation is scaffolded; full implementation added in later iteration."

check: lint validate
	@echo "Preflight checks are scaffolded; full implementation added in later iteration."

plan-example:
	@echo "Orchestration script not yet implemented in this iteration."

apply-example:
	@echo "Orchestration script not yet implemented in this iteration."

destroy-example:
	@echo "Orchestration script not yet implemented in this iteration."
