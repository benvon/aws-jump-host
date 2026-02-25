# Architecture

## Overview

This project composes Terraform, Terragrunt, Ansible, and shell automation to deliver private AWS jump hosts.

## Primary Components

- Terraform modules in `modules/terraform/*`
- Terragrunt orchestration in `terragrunt/` and `examples/live/`
- Ansible roles and playbooks in `ansible/`
- Operational scripts in `scripts/`

## Design Priorities

- Security-first defaults (private access, IMDSv2-only, least privilege)
- Declarative infrastructure and configuration management
- Modular boundaries that allow externalized environment inputs
