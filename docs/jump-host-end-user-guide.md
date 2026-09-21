# Jump host end-user guide

This guide is for people who connect to private jump hosts over **AWS Systems Manager Session Manager** (a shell in the browser or terminal, without SSH bastions).

Your organization should give you:

- An **AWS IAM Identity Center (SSO)** permission set or role to use in the jump-host account
- A named **AWS CLI profile** (or the values to put in `~/.aws/config`)
- Which **AWS Region** the host runs in (for example `us-west-2`)
- Whether this environment uses **per-user** Session Manager Run As or a **shared `ec2-user`** session

If `aws ssm start-session` fails with permission errors, your security team can use `docs/security-user-prerequisites.md` as the IAM checklist.

### Already set up?

```bash
# On your laptop
export AWS_PROFILE=your-sso-profile
export AWS_REGION=us-west-2
aws sso login --profile "$AWS_PROFILE"
jump-host-ssm.sh doctor
jump-host-ssm.sh connect --tag Environment=stage --name-contains core

# After you are on the jump host
whoami; echo "$HOME"; echo "$AWS_PROFILE"
awslogin
aws sts get-caller-identity
```

If those steps fail or the concepts are new, read the sections below before retrying.

## How privileges work on this jump host

Connecting with Session Manager only proves you may **open a shell**. It does **not** give you useful AWS API powers for environment work.

The jump-host **EC2 instance role is SSM-only by design** (agent + interactive sessions). For environment work—`kubelogin`, `log-transfer`, EKS/kubectl, S3, and similar—you must use **your SSO / IAM role** via `AWS_PROFILE` / `awslogin` (or keys you export). Do **not** plan on the instance role as a shared credential.

Unlearn the habit "I'm on the box, so the instance role will just work" for real work. Prefer tools and habits that keep you on your operator profile.

**Caveat:** The AWS credential chain can still fall back to the limited instance role via instance metadata if you have no usable operator credentials (missing or expired SSO, unset `AWS_PROFILE`, and so on). Some helpers (for example `log-transfer`) deliberately block that fallback; a raw `aws` command may not. Always confirm identity with `aws sts get-caller-identity` and expect your SSO role ARN—not an instance-role ARN—before doing environment work.

Practical check after connect: run `awslogin` if needed, then `aws sts get-caller-identity`, and confirm the account/role you expect.

## Two places for AWS config

Your **laptop** and the **jump host** each have their own AWS CLI configuration. Fixing one does **not** change the other. Starting a session from the **AWS Console** is a third path: it uses your browser console login, not laptop `~/.aws`.

| Step | Which machine | Which config | Purpose |
|------|---------------|--------------|---------|
| `aws sso login` / `jump-host-ssm.sh` / `aws ssm start-session` | Your laptop | Laptop `~/.aws/config` (and cached CLI SSO tokens) | Authenticate with the **CLI** to **start** the session |
| AWS Console → EC2 → Connect → Session Manager | Your browser | Console / Identity Center browser session (not laptop `~/.aws`) | Authenticate in the **console** to **start** the session |
| `awslogin`, `kubelogin`, `log-transfer`, ad-hoc `aws` | Jump host | That Linux user's `~/.aws/config` on the host | Authenticate to **call AWS from inside** the session |

Console-only operators do **not** need a working laptop CLI profile just to open the browser Session Manager shell. Once on the host, environment work still needs the **host** profile and `awslogin` (or equivalent), same as CLI-connected operators.

After the host has been configured at least once, home directories live on a persistent `/home` volume, so that Linux user's `~/.aws` on the host usually survives instance replacement. Admins may pre-seed a profile and set `AWS_PROFILE` via login env. If the profile is missing on the host, paste the same kind of SSO block your admin gave you (or ask them to seed it).

## Which Linux user you land as

Session Manager may land you as **your own Linux user** or as shared **`ec2-user`**, depending on how this environment's IaC / Session Manager preferences are set. Your host `~/.aws` follows **that** Linux home—not your laptop.

| | Per-user Run As | Shared `ec2-user` |
|--|-----------------|-------------------|
| How to tell | `whoami` is your Linux username | `whoami` is `ec2-user` |
| Home / `~/.aws` | Under `/home/<you>/` | Under `/home/ec2-user/` |
| Who maintains host profile | Usually you (or admin seeds your home) | Shared config under one home |
| What "my config" means | Not the laptop's; **this** host home | Not the laptop's; the **shared** host home |
| SSO token cache | Private to your Linux home | **Session-isolated** under `~/.cache/jump-host-aws/` per shell (see below) |

**Shared `ec2-user` and `awslogin`:** On hosts configured for shared Run As, each interactive `ec2-user` shell gets its own AWS home under `~/.cache/jump-host-aws/<session-id>/` (via `/etc/profile.d/jump-host-aws-session.sh`). `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE` point at that session tree—not the shared durable `~/.aws`. When you run `awslogin`, SSO login and token caching happen under the session home, then short-lived keys are exported into the session credentials file. Leaving the shell runs a best-effort cleanup that removes that session directory. This reduces **accidental** SSO token reuse across shells on the same Linux user; it is **not** a hard security boundary against a malicious peer who shares the same UID (they can still read world-accessible process env or other same-UID paths). **Prefer per-user Run As** for on-host SSO when your org can set it up; separate Linux homes remain the stronger model.

Ask your admin which model this environment uses. How Run As is chosen (`SSMSessionRunAs` / account defaults) is covered briefly later and in `docs/security-user-prerequisites.md` / `docs/access-model.md` for admins.

## What an AWS CLI profile and SSO session are

A **profile** is a named block in `~/.aws/config`. For Identity Center it usually points at a start URL, account, and permission set (role).

**`AWS_PROFILE`** tells the AWS CLI which named block to use. On the jump host it is often set for you by login defaults; you still need a matching profile in **that Linux user's** `~/.aws/config` on the host.

**`aws sso login`** (on your laptop) and **`awslogin`** (on the jump host) refresh a time-limited SSO session for that profile. On the host, `awslogin` uses a device-code flow because Session Manager has no browser. When the session expires you will see token-expired or "unable to locate credentials" errors—run login again on the machine where you are working.

Verify on the machine where the work runs:

```bash
aws sts get-caller-identity
```

You should see the account and role you expect—not an instance-role ARN.

## Setup

### 1. Gather what your admin should give you

- Profile name (example: `your-sso-profile`)
- AWS Region (example: `us-west-2`)
- Whether sessions use per-user Run As or shared `ec2-user`
- The SSO values for `~/.aws/config` if they have not already created the profile for you

### 2. Configure and sign in on your laptop

Ensure AWS CLI v2 is installed ([Installing the AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)). If your admin has not already created the profile, add a block like this to **your laptop's** `~/.aws/config` (replace placeholders with values they give you):

```ini
[profile your-sso-profile]
sso_start_url = https://example.awsapps.com/start
sso_region = us-west-2
sso_account_id = 123456789012
sso_role_name = YourPermissionSet
region = us-west-2
```

Then:

```bash
export AWS_PROFILE=your-sso-profile
export AWS_REGION=us-west-2
aws sso login --profile "$AWS_PROFILE"
aws sts get-caller-identity
```

Install the Session Manager plugin if you will connect from the CLI ([Install the Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)).

### 3. Configure the same kind of profile on the jump host

After you connect (Quick start below):

```bash
whoami
echo "$HOME"
echo "$AWS_PROFILE"
```

If `~/.aws/config` on **this** home already has the profile (admin may have pre-seeded it), you only need `awslogin`. Otherwise create `~/.aws/config` under **this** `$HOME` with the same kind of `[profile …]` block (values from your admin—often the same as the laptop, but it is still a separate file on a separate machine).

```bash
awslogin
aws sts get-caller-identity
```

## Typical first-session workflow

1. On your **laptop**: `aws sso login` for your profile; confirm with `aws sts get-caller-identity`.
2. Connect to the jump host (helper script or console Session Manager).
3. On the **host**: check `whoami`, `$HOME`, and `$AWS_PROFILE`.
4. On the **host**: `awslogin`, then `aws sts get-caller-identity` again.
5. Use on-host tools as needed (`kubelogin`, `log-transfer`, `aws`, …). They use **your** SSO role.
6. If AWS calls fail later in the session, re-run `awslogin`—do not assume "the box lost its instance role."

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

The script is Bash (not POSIX `sh`). It works with macOS `/bin/bash` 3.2 and with Bash 4+ on Linux and WSL. Run it directly or with `bash jump-host-ssm.sh`, not `sh`.

### 3. Configure your profile and region

Set the profile and region your admin told you to use:

```bash
export AWS_PROFILE=your-sso-profile
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

### On the jump host: `awslogin` and `kubelogin`

After you are on the host, two helpers are on `PATH` (`/usr/local/bin`). They use the **host** profile from **`AWS_PROFILE`** and your SSO role—**not** the EC2 instance role:

```bash
awslogin    # aws sso login --profile "$AWS_PROFILE" --no-browser --use-device-code
kubelogin   # aws eks update-kubeconfig for this environment's cluster, then kubectl config use-context
```

Both read **`AWS_PROFILE`** and **`AWS_REGION`** from the environment (usually set by login defaults on the host). `awslogin` uses the device-code flow because Session Manager has no browser.

`kubelogin` reads the cluster name from **`/etc/jump-host-eks-cluster`** and uses it as `--name`, `--alias`, and the kubectl context. If that file is missing or empty, `kubelogin` exits with an error; `awslogin` still works. Admins set the cluster name with `jump_host_eks_cluster_name` (see `docs/consumer-guide.md`).

### On the jump host: `log-transfer`

Package local files or directories and upload them for browser download via the AWS console:

```bash
log-transfer /path/to/file.log ./coredump.dir
```

The command prints a short `log-transfer s3:` line with the transfer settings it will use, then an S3 console URL. Open the URL, sign in with SSO if prompted, and download the object. You need an IAM role listed in this environment’s `users.yaml` `iam_role_arns` (that role is allowed to upload and to download). `log-transfer` uses **your** operator credentials on the jump host (`AWS_PROFILE` from login env / `awslogin`, or keys you export)—**not** the EC2 instance role. If you have not logged in on the host, or your role is not in the bucket policy, the upload fails. Archives expire after two years. You need free space on `/home` roughly equal to the zip size while it is being built.

### Choosing the Linux (OS) user for the session

The [**Which Linux user you land as**](#which-linux-user-you-land-as) table earlier in this guide is what operators need day to day. Session Manager **Run As** is chosen by IAM tag **`SSMSessionRunAs`** on your role (or IdP session tags) or by the account default in Session Manager preferences—not a free-form CLI flag on the standard shell document. Optional: `jump-host-ssm.sh connect --document-name <name>` if your org uses a different Session document. For `InvalidDocumentContent` pitfalls with placeholder Run As values, see `docs/access-model.md`.

### Shell startup, working directory, and prompt

The Session Manager preferences document sets a **short** `inputs.shellProfile.linux` that **sources** **`/etc/profile.d/jump-host-login-env.sh`** and **`/etc/profile.d/jump-host-path.sh`** when present (managed defaults such as **`AWS_PROFILE`** and **`~/bin` prepended on `PATH`**) for every Run As user, including **`ec2-user`**—before **`cd`** to your home directory and **`exec` interactive bash** (`bash -i`). That matches how Amazon Linux 2023 loads **`/etc/bashrc`**, which in turn sources **`/etc/profile.d/*.sh`**—including the managed environment segment for **`PS1`** in **`/etc/profile.d/zzz-jump-host-prompt.sh`** (installed by Ansible; the `zzz-` prefix makes it run after other `profile.d` snippets that set `PS1`). Your client may print that profile line once when the session starts; that is normal. The prompt label is resolved in order: **`JUMP_HOST_ENVIRONMENT`** if you set it, then **`/etc/jump-host-environment`** (written at configure time from **`--env`** / **`JUMP_HOST_ENVIRONMENT`**, or from the instance’s **`Environment` EC2 tag** when those were not passed), then the instance’s **`Environment` EC2 tag** when your admin has enabled instance tags in metadata. Settings in your own **`~/.bashrc`** or **`~/.bash_profile`** run later and **override** `PS1` if you customize it. To turn off the managed segment without changing your dotfiles, use either of the following:

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
   aws sso login --profile your-sso-profile
   ```

   A browser window opens; complete authentication with your org’s IdP.

3. Confirm you are using the expected account and role:

   ```bash
   aws sts get-caller-identity --profile your-sso-profile
   ```

If `aws sso login` is not applicable (long-lived keys or another credential flow), use the method your organization documents instead; you still need permission for `ssm:StartSession` on tagged jump hosts.

### Install the Session Manager plugin

Follow [Install the Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html). Without the plugin, `aws ssm start-session` cannot attach your terminal to the session.

### Start a session to the jump host

You need the **instance ID** (`i-...`) in the correct **region**.

**Option A — AWS Console:** EC2 → Instances → filter for your jump host → select the instance → **Connect** → **Session Manager**.

**Option B — AWS CLI:** after SSO (or other credentials) and plugin install:

```bash
export AWS_PROFILE=your-sso-profile
export AWS_REGION=us-west-2
aws ssm start-session --target i-0123456789abcdef0
```

**Option C — discover instance ID with the CLI** (requires `ec2:DescribeInstances`):

```bash
aws ec2 describe-instances \
  --filters "Name=tag:JumpHost,Values=true" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`]|[0].Value]' \
  --output table \
  --profile your-sso-profile \
  --region us-west-2
```

Use the instance id in the first column with `aws ssm start-session --target`. (Prefer a list `[...]` in `--query` with `--output text` if you script it: object keys are sorted alphabetically in text output, which scrambles column order.)

---

## Troubleshooting

| Symptom | What to check |
|--------|----------------|
| `aws: command not found` | Install AWS CLI v2 and ensure it is on `PATH`. |
| `Session Manager plugin not found` | Install the plugin; restart the terminal. |
| Token expired / SSO errors **on your laptop** | Run `aws sso login --profile ...` again. |
| Token expired / unable to locate credentials **on the host** | Run `awslogin` on the host; confirm `AWS_PROFILE` and that **this** `$HOME/.aws/config` has that profile (laptop config does not apply). |
| `sts get-caller-identity` shows an instance-role ARN | Operator credentials are missing or unused, so the AWS credential chain fell back to the limited instance role via instance metadata. Check `echo $AWS_PROFILE`, host `~/.aws/config`, and re-run `awslogin`. |
| Fixed laptop `~/.aws` but host tools still fail | Laptop and host configs are separate; configure or seed the profile under the host Linux user’s home. |
| Unexpected `whoami` / `$HOME` | This environment may use shared `ec2-user` vs per-user Run As; your host `~/.aws` follows that home. Ask your admin which model is in use. |
| Shared `ec2-user` and SSO token reuse concerns | Prefer per-user Run As. Under shared `ec2-user`, each shell uses a separate AWS home under `~/.cache/jump-host-aws/` so operators do not accidentally reuse another shell's SSO cache; this is not a hard boundary against a same-UID peer. If you still see another operator's role, confirm `echo "$JUMP_HOST_AWS_HOME"` is set and re-run `awslogin`. Hard session kills may leave stale dirs under `.cache/jump-host-aws/`; admins can prune them. |
| `AccessDeniedException` on `start-session` | IAM: role needs SSM permissions and ABAC/tag conditions must match the instance (`JumpHost`, `AccessProfile`). See `docs/security-user-prerequisites.md`. |
| `log-transfer` fails with AccessDenied or “Unable to locate credentials” | Instance role cannot upload. Run `awslogin`, confirm `AWS_PROFILE`, and ensure your role is in this environment’s `users.yaml` `iam_role_arns`. |
| Script lists no hosts | Wrong account, region, or tags; confirm `JumpHost=true` and instance is **running**. |
| SSM or **Ansible** (`aws_ssm`) sessions drop or hang after editing `shellProfile.linux` | `terraform apply` the `ssm-self-management` stack to restore the repo default (`. /etc/profile.d/jump-host-login-env.sh 2>/dev/null || true; . /etc/profile.d/jump-host-path.sh 2>/dev/null || true; cd $HOME; exec bash -i`), or set `linux_shell_profile = ""` in that stack for stock `/bin/sh` while troubleshooting. |

---

## Related documentation

- IAM / Session Manager requirements for security teams: `docs/security-user-prerequisites.md`
- Architecture (SSM-only instance role): `docs/architecture.md`
- Access model and Run As ownership: `docs/access-model.md`
- How admins configure login env and helpers: `docs/consumer-guide.md`
- Shared-user `awslogin` session credential isolation: [Which Linux user you land as](#which-linux-user-you-land-as)
