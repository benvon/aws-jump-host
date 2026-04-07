# Jump host end-user guide

This guide is for people who connect to private jump hosts over **AWS Systems Manager Session Manager** (a shell in the browser or terminal, without SSH bastions).

Your organization should give you:

- An **AWS IAM Identity Center (SSO)** permission set or role to use in the jump-host account
- A named **AWS CLI profile** (or the values to put in `~/.aws/config`)
- Which **AWS Region** the host runs in (for example `us-west-2`)

If `aws ssm start-session` fails with permission errors, your security team can use `docs/security-user-prerequisites.md` as the IAM checklist.

---

## Quick start (recommended): helper script

This repository includes `scripts/end-user/jump-host-ssm.sh`, which:

- Checks that the **AWS CLI** and **Session Manager plugin** are installed
- Confirms your **AWS credentials** work (`sts get-caller-identity`)
- Runs **`aws sso login`** for SSO-named profiles
- Finds running instances tagged **`JumpHost=true`** (optional extra tags or name substring)
- Starts **`aws ssm start-session`** to the chosen instance

### 1. Install prerequisites

- **AWS CLI v2**: [Installing or updating the latest version of the AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- **Session Manager plugin for the AWS CLI**: [Install the Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)

### 2. Copy the script

Copy `scripts/end-user/jump-host-ssm.sh` to your machine (for example `~/bin/jump-host-ssm.sh`), then:

```bash
chmod +x ~/bin/jump-host-ssm.sh
```

Ensure the directory is on your `PATH`, or invoke it with a full path.

### 3. Configure your profile and region

Set the profile and region your admin told you to use:

```bash
export AWS_PROFILE=your-sso-profile-name
export AWS_REGION=us-west-2
```

Alternatively pass `--profile` and `--region` on each command.

### 4. Log in (SSO) and verify

```bash
jump-host-ssm.sh login    # SSO browser login; requires AWS_PROFILE to be an SSO profile
jump-host-ssm.sh doctor  # Confirms CLI, plugin, and credentials
```

### 5. List or connect

List running jump hosts (tag `JumpHost=true`):

```bash
jump-host-ssm.sh list
```

Narrow by tags (AND logic) or by the EC2 **Name** tag substring:

```bash
jump-host-ssm.sh list --tag Environment=stage --name-contains core
```

Open a session when exactly one instance matches; otherwise narrow filters or pass an instance ID:

```bash
jump-host-ssm.sh connect --tag Environment=stage --name-contains core
jump-host-ssm.sh connect --instance-id i-0123456789abcdef0
```

If several instances match, the script prints the candidates and exits; use `--tag`, `--name-contains`, or `--instance-id` until the match is unique.

### Choosing the Linux (OS) user for the session

Session Manager **Run As** is how AWS picks the account on the instance (instead of the default `ssm-user`). In most organizations the OS user is **not** a free-form CLI choice. AWS resolves it in this order (see [Turn on Run As support for Linux and macOS managed nodes](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-preferences-run-as.html)):

1. **IAM principal tag** `SSMSessionRunAs` on the user or role you use to start the session (recommended for per-person mapping).
2. Otherwise the **default OS user** in the account’s Session Manager preferences document (for example `run_as_default_user` in this repo’s Terraform-managed document).

So for many jump-host deployments you **do not** pass a Linux user on the command line: your SSO role (or IdP session tags) should already carry `SSMSessionRunAs`, or everyone shares the configured default.

**Why not `aws ssm start-session --parameters` for the OS user?**

For the standard **Standard_Stream** shell Session document, AWS validates `inputs.runAsDefaultUser` as a **literal** username. Placeholder values (for example `{{runAsDefaultUser}}`) are rejected with `InvalidDocumentContent`, and `StartSession` cannot override Run As the way some older examples suggest. Use **`SSMSessionRunAs`** (or your org’s IdP → session tag mapping) instead of trying to pass the Linux user from the CLI.

Optional: `jump-host-ssm.sh connect --document-name <name>` if you use a **different** Session document type (not for arbitrary Run As on the default shell document).

### Shell startup, working directory, and prompt

The Session Manager preferences document sets a **short** `inputs.shellProfile.linux` that **`cd`s to your home directory** and **`exec`s interactive bash** (`bash -i`). That matches how Amazon Linux 2023 loads **`/etc/bashrc`**, which in turn sources **`/etc/profile.d/*.sh`**—including the managed environment segment for **`PS1`** in **`/etc/profile.d/zzz-jump-host-prompt.sh`** (installed by Ansible; the `zzz-` prefix makes it run after other `profile.d` snippets that set `PS1`). Your client may print that profile line once when the session starts; that is normal. The prompt label is resolved in order: **`JUMP_HOST_ENVIRONMENT`** if you set it, then **`/etc/jump-host-environment`** (written at configure time from **`--env`** / **`JUMP_HOST_ENVIRONMENT`**, or from the instance’s **`Environment` EC2 tag** when those were not passed), then the **IMDS** tag path when instance metadata tags are enabled on the instance. Settings in your own **`~/.bashrc`** or **`~/.bash_profile`** run later and **override** `PS1` if you customize it. To turn off the managed segment without changing your dotfiles, use either of the following:

- Create an empty file `~/.jump-host-disable-prompt`, or
- Set `export JUMP_HOST_DISABLE_PROMPT=1` before the prompt snippet runs (for example early in `~/.bash_profile`).

### Persistent home directories

Each jump host uses a **dedicated EBS volume** mounted at **`/home`**. After the host has been configured with Ansible at least once, user home directories under `/home/...` live on that volume, so they **survive instance replacement** as long as the same Terraform-managed volume is reattached. **Before** the first successful configure/apply, `/home` may still be on the instance root disk—avoid relying on persistence until provisioning has completed.

### Tags you can rely on

Jump hosts from this platform are tagged consistently:

| Tag             | Purpose |
|-----------------|--------|
| `JumpHost`      | Always `true` on jump host instances (used by the script and IAM examples). |
| `Name`          | Human-readable name, typically `<name_prefix>-<host_key>` from Terragrunt/Terraform. |
| `AccessProfile` | Used with IAM ABAC so your role only starts sessions on matching hosts. |
| `Project`, `Environment`, `SubEnvironment`, `Region`, `ManagedBy` | Baseline tags from Terragrunt (`terragrunt/root.hcl`); your org may add more via `extra_tags`. |

Per-host tags from your live config (for example `Role=jump-host`) are merged in as well—use them with `--tag Key=Value` if your admin documents them.

---

## Manual procedure (no script)

### Sign in with AWS IAM Identity Center (SSO)

1. Ensure **AWS CLI v2** is installed and your admin has given you a **profile** in `~/.aws/config` that uses SSO (`sso_start_url`, `sso_region`, `sso_account_id`, `sso_role_name`, and usually `region`).
2. Sign in:

   ```bash
   aws sso login --profile your-sso-profile-name
   ```

   A browser window opens; complete authentication with your org’s IdP.

3. Confirm you are using the expected account and role:

   ```bash
   aws sts get-caller-identity --profile your-sso-profile-name
   ```

If `aws sso login` is not applicable (long-lived keys or another credential flow), use the method your organization documents instead; you still need permission for `ssm:StartSession` on tagged jump hosts.

### Install the Session Manager plugin

Follow [Install the Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html). Without the plugin, `aws ssm start-session` cannot attach your terminal to the session.

### Start a session to the jump host

You need the **instance ID** (`i-...`) in the correct **region**.

**Option A — AWS Console:** EC2 → Instances → filter for your jump host → select the instance → **Connect** → **Session Manager**.

**Option B — AWS CLI:** after SSO (or other credentials) and plugin install:

```bash
export AWS_PROFILE=your-sso-profile-name
export AWS_REGION=us-west-2
aws ssm start-session --target i-0123456789abcdef0
```

**Option C — discover instance ID with the CLI** (requires `ec2:DescribeInstances`):

```bash
aws ec2 describe-instances \
  --filters "Name=tag:JumpHost,Values=true" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`]|[0].Value]' \
  --output table \
  --profile your-sso-profile-name \
  --region us-west-2
```

Use the instance id in the first column with `aws ssm start-session --target`. (Prefer a list `[...]` in `--query` with `--output text` if you script it: object keys are sorted alphabetically in text output, which scrambles column order.)

---

## Troubleshooting

| Symptom | What to check |
|--------|----------------|
| `aws: command not found` | Install AWS CLI v2 and ensure it is on `PATH`. |
| `Session Manager plugin not found` | Install the plugin; restart the terminal. |
| `Token has expired` / SSO errors | Run `aws sso login --profile ...` again. |
| `AccessDeniedException` on `start-session` | IAM: role needs SSM permissions and ABAC/tag conditions must match the instance (`JumpHost`, `AccessProfile`). See `docs/security-user-prerequisites.md`. |
| SSM connects but wrong Linux user | Run As is set by IAM tag `SSMSessionRunAs` (or IdP session tags) or the account default in Session Manager preferences—not via a CLI flag on the standard shell document. |
| Script lists no hosts | Wrong account, region, or tags; confirm `JumpHost=true` and instance is **running**. |
| SSM or **Ansible** (`aws_ssm`) sessions drop or hang after editing `shellProfile.linux` | `terraform apply` the `ssm-self-management` stack to restore the repo default (`cd $HOME; exec bash -i`), or set `linux_shell_profile = ""` in that stack for stock `/bin/sh` while troubleshooting. |

---

## Related documentation

- IAM / Session Manager requirements for security teams: `docs/security-user-prerequisites.md`
- How this repo applies baseline AWS tags: `docs/consumer-guide.md` (Global AWS tags)
