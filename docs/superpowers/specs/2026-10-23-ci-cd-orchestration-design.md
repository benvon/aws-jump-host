# CI and CD orchestration modes

Status: approved design (pending implementation).

## Problem

`scripts/orchestrate.sh` is the deployment entry point, and it is a poor fit for pipelines.

- `plan`, `apply`, and `configure` apply the observability stack during preflight. `plan` is therefore not a read-only validation.
- `apply` and `destroy` wait for a Terraform approval prompt unless `--auto-approve` is passed. A non-terminal run can hang.
- Account identity, SSM transfer-bucket access, and an empty host inventory continue after a warning when the check cannot be proven. STS and preflight failures hide AWS stderr with `2>/dev/null`.
- `make validate` runs Terraform, Terragrunt, and Ansible checks in shell loops that hide `terraform init` output and do not stop on the first tool failure.
- The `check` subcommand lints the repo and then applies stacks. `make check` is a different, offline-plus-optional-preflight target. The shared name is ambiguous.

## Goals

1. Offline CI runs one non-interactive command, `validate`, and sees each tool it runs.
2. Live CI runs `plan`, which only reads: account check, SSM preflight, `terragrunt plan`, Ansible `--check`.
3. CD runs `apply` or `configure` with `--non-interactive`. `destroy` uses the same flag when automation runs it.
4. An operator at a terminal still confirms `apply`, `configure`, and `destroy`.
5. `init`, `plan`, `apply`, `configure`, and `destroy` exit when an AWS guard cannot be proven, unless that guard is explicitly skipped.
6. Tool and subshell failures leave stderr visible. The orchestrator exits with the tool's status and adds an `Error:` line that names the command. Preflight is the exception: an AWS CLI failure there still shows stderr, then the non-compliant line, and exits 1.
7. Tests cover the pipeline modes, the fail-closed guards, and the preserved stderr.

## Non-goals

- Moving `make fmt-check` or `make lint` into `validate`.
- Refusing `SKIP_ACCOUNT_CHECK` or `SKIP_PREFLIGHT` during `--non-interactive` runs. Those variables remain explicit local and test opt-outs.
- Changing end-user Session Manager scripts (`scripts/end-user/`, `jump-host-aws-session.sh`).
- A transactional rollback of stacks already applied when a later step fails.
- Requiring a live AWS account in the default GitHub quality workflow.

## Decisions

| Topic | Choice |
| --- | --- |
| Shape | One orchestrator, plus `scripts/lib/run.sh` for tool execution |
| Offline CI | `orchestrate.sh validate` |
| Live CI | `orchestrate.sh plan` (read-only) |
| CD deploy | `apply` for full infrastructure and Ansible; `configure` for `log-transfer` and Ansible |
| CD teardown | `destroy` with `--non-interactive` |
| Human approval | Prompt when stdin is a terminal. `--non-interactive` or `--auto-approve` skips the prompt |
| Unproven AWS guards | Fail the run. Skip variables print an explicit line and continue |
| First live `plan` | Fails until observability, Session Manager preferences, and `log-transfer` outputs already exist |
| Retired command | `check` exits with a pointer to `validate` and `plan` |

## Commands

`validate` takes no environment arguments. Every other command still requires `--live-dir`, `--env`, `--subenv`, and `--region`.

| Command | Mode | Behavior |
| --- | --- | --- |
| `validate` | Offline CI | `terraform init -backend=false -input=false` and `terraform validate` for each module under `modules/terraform`. `terragrunt hcl validate --inputs` for each stack under `examples/live`. Ansible `--syntax-check` for `jump_hosts.yml` and `decommission.yml`. No AWS calls. |
| `plan` | Read-only live CI | Account check, read-only SSM preflight, `terragrunt plan -input=false` for each stack, then Ansible `--check`. Never applies. |
| `apply` | Full deploy | Apply observability, apply `ssm-self-management` when that flag is set, read-only preflight, then apply endpoints, jump hosts, and `log-transfer`, then Ansible. Observability is applied once. |
| `configure` | Host deploy | Read-only preflight, apply `log-transfer`, then Ansible. Other stacks are left alone. |
| `destroy` | Teardown | Decommission when `--users-vars` is set and at least one host exists, then destroy `log-transfer`, jump hosts, endpoints, and observability, in that order. |
| `init` | Setup | Account check, then `terragrunt init -input=false` for each stack. |
| `check` | Retired | Exit 1. Tell the operator to use `validate` for offline checks and `plan` for a read-only live run, and `make fmt-check` plus `make lint` for formatting and lint. |

`make validate` remains responsible for `install-tools`, then it calls `./scripts/orchestrate.sh validate`. `TG_DOWNLOAD_DIR` is still exported for Terragrunt. Formatting and lint stay on their existing Make targets. `make lint` also shellchecks `scripts/lib/*.sh`.

### Approval flags

`apply`, `configure`, and `destroy` prompt for Terraform approval when stdin is a terminal.

`--non-interactive` is the CD flag. It passes `-auto-approve` and `-input=false` and does not prompt. `--auto-approve` remains and does the same thing, so current automation keeps working. If neither flag is set and stdin is not a terminal, those three commands exit 1 before Terraform starts. The error names `--non-interactive`.

`plan`, `init`, `apply`, `configure`, and `destroy` always pass `-input=false`. `validate` passes `-input=false` on `terraform init`. The Terraform approval prompt is the only prompt, and only `--non-interactive` or `--auto-approve` suppresses it.

`--non-interactive` on `validate`, `plan`, or `init` is accepted. Those commands already do not prompt. The startup banner reports it.

### `--ssm-self-management`

On `plan`, the flag adds a read-only `terragrunt plan` of the `ssm-self-management` stack. It does not create Session Manager preferences.

On `apply` and `init`, the flag includes that stack in the real run. `apply` applies it after observability and before read-only preflight. Those commands require the `ssm-self-management` directory under the selected region, as they do today.

`validate`, `configure`, and `destroy` reject the flag and exit 1. The error names `init`, `plan`, and `apply` as the commands that accept it. `configure` does not remediate Session Manager preferences, so a silent ignore would be an ambiguous run.

## Fail-closed guards

### Account identity

`init`, `plan`, `apply`, `configure`, and `destroy` prove the AWS account before they plan or change anything.

`SKIP_ACCOUNT_CHECK=true` prints `Skipping account identity check (SKIP_ACCOUNT_CHECK=true).` and continues.

Otherwise the script exits 1 when:

- `aws` is missing
- `<live-dir>/<env>/account.hcl` is missing
- `account_id` cannot be parsed as a 12-digit account id
- `aws sts get-caller-identity` fails
- the caller account differs from `account_id`

A match prints the confirmed account id. STS stderr stays on the terminal. The script does not redirect it to `/dev/null`.

`validate` does not perform this check.

Argument parsing, the required-directory check, and users-file validation happen before the account check. An invalid users file still fails before any AWS or Terragrunt command. The startup banner is printed after the users file is accepted and before the account check.

### SSM preflight

`plan`, `apply`, and `configure` run `scripts/preflight_ssm_compliance.sh`. `destroy` and `init` do not.

`SKIP_PREFLIGHT=true` prints `Skipping SSM preflight checks (SKIP_PREFLIGHT=true).` and continues.

Otherwise preflight only reads. AWS stderr stays visible. The existing non-compliant messages still exit 1. An AWS CLI failure inside preflight shows that stderr, then the non-compliant line, and exits 1.

`plan` and `configure` do not create the CloudWatch log group or Session Manager preferences. On a new account they fail until those already exist.

`apply` creates them first. It applies observability, applies `ssm-self-management` when requested, runs read-only preflight, and only then applies the remaining stacks and Ansible. If preflight fails, the script names the stacks already applied and exits before endpoints, jump hosts, `log-transfer`, and Ansible. That partial apply is left in place.

Before preflight, `plan` and `configure` print that this command will not create the log group or Session Manager preferences. `apply` prints which of those stacks were applied and that the remaining work runs only after preflight passes.

### log-transfer outputs

`plan`, `apply`, and `configure` exit 1 when the `log-transfer` bucket or region output is missing, empty, or not a safe bucket name or region id. Ansible does not run in that case.

`plan` reads the outputs after `terragrunt plan` and before Ansible `--check`. The plans are already on the terminal when the output lookup fails.

`apply` and `configure` read the outputs after the `log-transfer` apply and before Ansible.

### Inventory and the SSM transfer bucket

An empty jump-host inventory exits `plan`, `apply`, and `configure` with the existing guidance: Terraform has not produced a non-empty `hosts` output for the jump-hosts stack.

`destroy` with `--users-vars` and one or more hosts runs decommission, then Terragrunt destroy. `destroy` with `--users-vars` and zero hosts prints that decommission is skipped, then continues with Terragrunt destroy. `destroy` without `--users-vars` prints that decommission is skipped because no users file was provided, then continues. Teardown of an already-empty environment still removes remaining stacks.

When Ansible will contact hosts, a missing `aws` CLI or a failed `s3api head-bucket` exits 1. The bucket-check stderr stays visible.

### Users file

Omitting `--users-vars` remains an explicit empty user list for Ansible and for the bucket policy. A missing, unreadable, or schema-invalid users file still fails before Terragrunt runs.

## Documented limitation

The orchestrator help text, `README.md`, and `docs/consumer-guide.md` state this limitation:

`plan` and `configure` require an already-applied observability stack, compliant Session Manager preferences, the expected CloudWatch log group, and existing `log-transfer` outputs. A new account uses `apply` first. Use `apply --ssm-self-management` when this account must create the Session Manager preferences. `--ssm-self-management` on `plan` only adds a read-only plan of that stack.

## Tool execution

`scripts/lib/run.sh` is the only way `orchestrate.sh` and `preflight_ssm_compliance.sh` run an external tool. It is bash 3.2 compatible. Both scripts keep `set -euo pipefail` and source the library.

Each orchestrator run starts with a banner: command name, live directory, environment, subenvironment, region, users file, whether approval is non-interactive, and whether the account check and preflight are required or explicitly skipped. `validate` prints the repository checks it is about to run and omits the live-target fields. Before each tool, the runner prints the argv it is about to execute.

The library provides:

- `run_logged` leaves stdout and stderr on the terminal. On a non-zero status it prints `Error: command failed (exit N):` plus the argv, then exits with that same status.
- `capture_stdout` stores stdout in a variable named by a string argument, using `printf -v` so the helper stays bash 3.2 compatible. Stderr stays on the terminal. It records status with `cmd && status=0 || status=$?`, so `set -e` cannot skip the error report. Failure prints the same `Error: command failed` line and exits with the tool status.
- `capture_stdout_status` is the same capture without exiting. `preflight_ssm_compliance.sh` uses it so an AWS failure can print the existing non-compliant line and then exit 1. AWS stderr has already been written to the terminal. Orchestrator callers use `capture_stdout`, which exits with the tool status.

Script-detected problems exit 1 with their own `Error:` line. That covers a missing `account.hcl`, an unreadable account id, an empty inventory on `plan` / `apply` / `configure`, a missing terminal, an unsafe `log-transfer` output, and the retired `check` command. Tool failures keep the tool's status.

`account.hcl` is parsed with a `sed` expression that prints the first match and quits. The script does not pipe that `sed` to `head`, which would raise SIGPIPE under `pipefail`.

Tool calls in these two scripts do not use `2>/dev/null`, `|| true`, or a failure branch that continues the run. `SKIP_ACCOUNT_CHECK` and `SKIP_PREFLIGHT` are the only continuations, and each one prints its skip line first.

## Tests

Bats stays on the existing fake `terragrunt` and fake `ansible-playbook` in `tests/shell/bin`. The fake `terragrunt` also accepts `hcl validate` and logs it. A fake `aws` is prepended to `PATH` only inside the tests that need one. Successful `plan`, `apply`, and `configure` cases that have hosts stub `s3api head-bucket`, because a real AWS CLI would be asked about the example state bucket.

### Existing cases that change

- `plan` with a failed `log-transfer` output lookup exits non-zero, does not invoke Ansible, and shows the fake stderr plus `Error: command failed`.
- `plan` and `configure` cases that succeed with an empty inventory move to `hosts_ok` plus the bucket stub.
- `configure` cases that currently omit `--auto-approve` pass `--non-interactive`, so they still reach the output check. Bats has no terminal, and the fake Terragrunt never prompts.

### New orchestrator cases

- `validate` runs Terraform validate, Terragrunt HCL validate, and both Ansible syntax-checks, and prints each command. A failing fake Terraform exits with that tool's status, its stderr is still in the output, and later tools do not run.
- `plan` logs `plan` and never logs `apply`, including with `--ssm-self-management`.
- `apply --non-interactive` applies observability before the other stacks and passes `-auto-approve` and `-input=false`.
- `configure --non-interactive` applies `log-transfer` and does not apply observability.
- No terminal and no `--non-interactive` or `--auto-approve` exits `apply` and `destroy` before Terragrunt. The error names `--non-interactive`.
- Account guard: missing `account.hcl`, unreadable `account_id`, STS failure with stderr preserved, account mismatch, and a confirmed match. `SKIP_ACCOUNT_CHECK=true` prints the skip line and continues.
- `SKIP_PREFLIGHT=true` prints the skip line. With preflight enabled, a failing fake `aws` stops `plan` before `terragrunt plan`, and the output says `plan` will not create the log group.
- Empty inventory exits `plan`, `apply`, and `configure`.
- `destroy` with zero hosts logs that decommission is skipped and still destroys stacks.
- `check` exits non-zero and names `validate` and `plan`.

### Preflight and docs

`tests/shell/preflight_ssm_compliance.bats` covers a document lookup failure: AWS stderr and the non-compliant line are both present, and the status is non-zero. A matching fixture prints that preflight passed.

A contract check locks the limitation text. The orchestrator help text, `README.md`, and `docs/consumer-guide.md` all say that `plan` and `configure` require an existing observability stack, compliant Session Manager preferences, and existing `log-transfer` outputs, and that a new account uses `apply` first.

## Documentation

Update the usage text in `scripts/orchestrate.sh`, the example section of `README.md`, and the orchestration section of `docs/consumer-guide.md` with the command table, the `--non-interactive` flag, and the first-run limitation above. Mention that `make validate` calls the orchestrator.
