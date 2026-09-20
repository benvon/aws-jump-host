# End-User Credentials Docs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand `docs/jump-host-end-user-guide.md` so less CLI-savvy operators understand SSO profiles, laptop vs host AWS config, and that all on-host AWS work uses their SSO role—never the EC2 instance role.

**Architecture:** Single-file Approach A from the spec: front-load mental model → setup → typical workflow, keep a short “Already set up?” command box, then retain/tighten connect helpers and troubleshooting. Admin docs get one-line cross-links only.

**Tech Stack:** Markdown documentation only (no code, Ansible, or Terraform changes).

**Spec:** `docs/superpowers/specs/2026-09-18-end-user-credentials-docs-design.md`

## Global Constraints

- Primary deliverable: restructure and expand `docs/jump-host-end-user-guide.md` only as the end-user teaching surface.
- Emphasize repeatedly: **any and all** AWS-backed activity on the jump host uses the operator’s **SSO / IAM role**, **explicitly not** the EC2 instance role.
- Do **not** discuss IMDS / metadata disable in the main end-user narrative; troubleshooting may say the instance role cannot perform the action.
- Do **not** become a general AWS CLI manual; link out for CLI v2 and Session Manager plugin install only.
- Do **not** change `awslogin`, Ansible, Terraform, or other runtime behavior.
- Do **not** create new end-user primer files.
- Admin docs get short cross-links only—no duplicated teaching material.
- Placeholder SSO profile blocks must use clearly fake values (`https://example.awsapps.com/start`, `123456789012`, `YourPermissionSet`, `your-sso-profile`).

---

## File structure

| Path | Responsibility |
| --- | --- |
| `docs/jump-host-end-user-guide.md` | Primary end-user guide (full rewrite/restructure per outline). |
| `docs/consumer-guide.md` | One-line pointer to end-user guide for operator SSO/profile/privilege model. |
| `docs/access-model.md` | One-line pointer under instance-role section. |
| `docs/architecture.md` | One-line pointer near SSM-only instance IAM bullet. |
| `docs/security-user-prerequisites.md` | One-line pointer that operators should read the end-user guide. |

---

### Task 1: Front-load privilege model, two configs, and Linux user

**Files:**
- Modify: `docs/jump-host-end-user-guide.md` (replace the current short intro through the start of “Quick start”; keep the Quick start and later sections for now—they are rewritten in later tasks)

**Interfaces:**
- Consumes: Spec sections Privilege model, Two AWS configs, Linux user table
- Produces: New top of guide through section 4 of the outline (audience + Already set up + privileges + two configs + Linux user)

- [ ] **Step 1: Replace the opening of the guide**

Replace from the `# Jump host end-user guide` heading through the paragraph that currently ends with “Run `awslogin` if your session credentials have expired.” (lines 1–13 today), and insert the new front matter **before** the existing `## Quick start (recommended): helper script` heading. Leave the Quick start heading and everything below it untouched in this task.

New content to write (adapt wording for clarity; keep meaning exact):

```markdown
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
export AWS_PROFILE=your-sso-profile-name
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

Connecting with Session Manager only proves you may **open a shell**. It does **not** give you the EC2 instance’s AWS API powers.

The jump-host **EC2 instance role is SSM-only by design** (agent + interactive sessions). While you are logged in, **any and all** AWS-backed activity uses **your SSO / IAM role**—**not** the instance role. That includes `aws`, `awslogin`, `kubelogin`, `log-transfer`, kubectl talking to EKS, and similar tools.

Unlearn the habit “I’m on the box, so the instance role will just work.” Here it will not.

Practical check after connect: if AWS calls fail with credential or AccessDenied errors, run `awslogin`, then `aws sts get-caller-identity`, and confirm the account/role you expect (not an instance-role ARN).

## Two places for AWS config

Your **laptop** and the **jump host** each have their own AWS CLI configuration. Fixing one does **not** change the other.

| Step | Which machine | Which config | Purpose |
|------|---------------|--------------|---------|
| `aws sso login` / `jump-host-ssm.sh` / console Session Manager | Your laptop | Laptop `~/.aws/config` (and cached SSO tokens) | Authenticate to **start** the session |
| `awslogin`, `kubelogin`, `log-transfer`, ad-hoc `aws` | Jump host | That Linux user’s `~/.aws/config` on the host | Authenticate to **call AWS from inside** the session |

After the host has been configured at least once, home directories live on a persistent `/home` volume, so that Linux user’s `~/.aws` on the host usually survives instance replacement. Admins may pre-seed a profile and set `AWS_PROFILE` via login env. If the profile is missing on the host, paste the same kind of SSO block your admin gave you (or ask them to seed it).

## Which Linux user you land as

Session Manager may land you as **your own Linux user** or as shared **`ec2-user`**, depending on how this environment’s IaC / Session Manager preferences are set. Your host `~/.aws` follows **that** Linux home—not your laptop.

| | Per-user Run As | Shared `ec2-user` |
|--|-----------------|-------------------|
| How to tell | `whoami` is your Linux username | `whoami` is `ec2-user` |
| Home / `~/.aws` | Under `/home/<you>/` | Under `/home/ec2-user/` |
| Who maintains host profile | Usually you (or admin seeds your home) | Shared; coordinate with teammates/admin |
| What “my config” means | Not the laptop’s; **this** host home | Not the laptop’s; the **shared** host home |

Ask your admin which model this environment uses. How Run As is chosen (`SSMSessionRunAs` / account defaults) is covered briefly later and in `docs/security-user-prerequisites.md` / `docs/access-model.md` for admins.
```

- [ ] **Step 2: Spec coverage check for Task 1**

Confirm the new front matter includes: bring-your-own privileges (all activity / never instance role); laptop vs host table; per-user vs `ec2-user` table; Already set up box; admin may pre-seed; no IMDS narrative.

- [ ] **Step 3: Commit**

```bash
git add docs/jump-host-end-user-guide.md
git commit -m "$(cat <<'EOF'
docs: front-load jump-host privilege model and dual AWS configs

Teach operators that on-host AWS work uses their SSO role, that laptop and host configs differ, and how per-user vs ec2-user homes work.
EOF
)"
```

---

### Task 2: Profiles, setup, and typical first-session workflow

**Files:**
- Modify: `docs/jump-host-end-user-guide.md` (insert after the Linux user section from Task 1, still before `## Quick start`)

**Interfaces:**
- Consumes: Outline items 5–7; Setup and Typical workflow from the spec
- Produces: Profile mental model, setup steps, first-session workflow sections

- [ ] **Step 1: Insert profile / SSO, setup, and workflow sections**

Insert immediately before `## Quick start (recommended): helper script`:

```markdown
## What an AWS CLI profile and SSO session are

A **profile** is a named block in `~/.aws/config`. For Identity Center it usually points at a start URL, account, and permission set (role).

**`AWS_PROFILE`** tells the AWS CLI which named block to use. On the jump host it is often set for you by login defaults; you still need a matching profile in **that Linux user’s** `~/.aws/config` on the host.

**`aws sso login`** (on your laptop) and **`awslogin`** (on the jump host) refresh a time-limited SSO session for that profile. On the host, `awslogin` uses a device-code flow because Session Manager has no browser. When the session expires you will see token-expired or “unable to locate credentials” errors—run login again on the machine where you are working.

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

Ensure AWS CLI v2 is installed ([Installing the AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)). If your admin has not already created the profile, add a block like this to **your laptop’s** `~/.aws/config` (replace placeholders with values they give you):

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
6. If AWS calls fail later in the session, re-run `awslogin`—do not assume “the box lost its instance role.”
```

- [ ] **Step 2: Verify nested fences**

Open the file and confirm Markdown fences for bash/ini inside the new sections are balanced (no broken outer fences). Fix if the “Already set up?” or setup examples broke nesting—prefer separate fenced blocks over nested fences if the renderer is picky.

- [ ] **Step 3: Commit**

```bash
git add docs/jump-host-end-user-guide.md
git commit -m "$(cat <<'EOF'
docs: add SSO profile setup and first-session jump-host workflow

Walk operators through laptop vs host profile setup and the happy-path awslogin verification flow.
EOF
)"
```

---

### Task 3: Tighten Quick start, on-host tools, Run As, and troubleshooting

**Files:**
- Modify: `docs/jump-host-end-user-guide.md` (from `## Quick start` through Troubleshooting / Related documentation)

**Interfaces:**
- Consumes: Existing helper-script, tool, Run As, troubleshooting content; spec “Existing sections to keep or rewrite”
- Produces: Consistent privilege language; shortened Run As; expanded credential troubleshooting; no IMDS in `log-transfer` narrative

- [ ] **Step 1: Rewrite on-host tool openings**

Update the `awslogin` / `kubelogin` section intro so it states these tools use the **host** profile / `AWS_PROFILE` and the operator’s SSO role (never the instance role). Keep the existing command examples and `kubelogin` cluster-file behavior.

Update the `log-transfer` paragraph to:

- Keep usage, console URL, `iam_role_arns`, expiry, disk space
- State clearly it uses operator credentials from the **host** (`AWS_PROFILE` / `awslogin`)
- State the instance role cannot upload
- **Remove** the sentence about disabling the instance metadata service

Example replacement for the explanatory paragraph (keep the `log-transfer …` code fence above it):

```markdown
The command prints a short `log-transfer s3:` line with the transfer settings it will use, then an S3 console URL. Open the URL, sign in with SSO if prompted, and download the object. You need an IAM role listed in this environment’s `users.yaml` `iam_role_arns` (that role is allowed to upload and to download). `log-transfer` uses **your** operator credentials on the jump host (`AWS_PROFILE` from login env / `awslogin`, or keys you export)—**not** the EC2 instance role. If you have not logged in on the host, or your role is not in the bucket policy, the upload fails. Archives expire after two years. You need free space on `/home` roughly equal to the zip size while it is being built.
```

- [ ] **Step 2: Shorten the Run As deep dive**

Replace the long “Choosing the Linux (OS) user for the session” section with a short pointer: the practical table above is what operators need; Run As is chosen by IAM tag `SSMSessionRunAs` (or IdP session tags) or the account default in Session Manager preferences—not a free-form CLI flag on the standard shell document. Keep the optional `--document-name` note if still accurate. Move or drop the long `InvalidDocumentContent` / placeholder explanation into one short sentence linking to `docs/access-model.md` / `docs/security-user-prerequisites.md`.

- [ ] **Step 3: Expand troubleshooting**

Add or replace rows so the table includes at least:

| Symptom | What to check |
|--------|----------------|
| Token expired / unable to locate credentials **on the host** | Run `awslogin` on the host; confirm `AWS_PROFILE` and that **this** `$HOME/.aws/config` has that profile (laptop config does not apply). |
| `sts get-caller-identity` shows an instance-role ARN | You are not using your SSO profile. Check `echo $AWS_PROFILE`, host `~/.aws/config`, and re-run `awslogin`. |
| Fixed laptop `~/.aws` but host tools still fail | Laptop and host configs are separate; configure or seed the profile under the host Linux user’s home. |
| Unexpected `whoami` / `$HOME` | This environment may use shared `ec2-user` vs per-user Run As; your host `~/.aws` follows that home. Ask your admin which model is in use. |
| `log-transfer` AccessDenied / unable to locate credentials | Instance role cannot upload. Run `awslogin`, confirm `AWS_PROFILE`, and ensure your role is in `users.yaml` `iam_role_arns`. |

Keep useful existing rows (`aws` not found, plugin missing, `start-session` AccessDenied, script lists no hosts, shellProfile hang). Soften or remove any IMDS-specific wording.

- [ ] **Step 4: Related documentation blurb**

Ensure Related documentation points operators at this guide’s privilege/config sections as the primary story, and lists admin docs without duplicating teaching:

```markdown
## Related documentation

- IAM / Session Manager requirements for security teams: `docs/security-user-prerequisites.md`
- Architecture (SSM-only instance role): `docs/architecture.md`
- Access model and Run As ownership: `docs/access-model.md`
- How admins configure login env and helpers: `docs/consumer-guide.md`
```

- [ ] **Step 5: Full-guide read-through against success criteria**

Read the whole file and confirm an operator can answer:

1. Why the instance role is not their AWS power
2. Laptop vs host config, and which step uses which
3. How to tell per-user vs `ec2-user`
4. Laptop → connect → `awslogin` → verify → tool

Also confirm: no IMDS in main narrative; Already set up box still near top; Quick start still works for power users.

- [ ] **Step 6: Commit**

```bash
git add docs/jump-host-end-user-guide.md
git commit -m "$(cat <<'EOF'
docs: align on-host tools and troubleshooting with SSO privilege model

Rewrite tool intros, shorten Run As for operators, and expand credential-confusion troubleshooting without IMDS jargon.
EOF
)"
```

---

### Task 4: Admin doc cross-links

**Files:**
- Modify: `docs/consumer-guide.md`
- Modify: `docs/access-model.md`
- Modify: `docs/architecture.md`
- Modify: `docs/security-user-prerequisites.md`

**Interfaces:**
- Consumes: Spec Cross-links section
- Produces: One-line pointers to `docs/jump-host-end-user-guide.md` without duplicating teaching

- [ ] **Step 1: Add cross-links**

In `docs/consumer-guide.md`, near the existing operator-credentials / instance-role paragraph (~line 11), add:

```markdown
Operators who need SSO profiles, laptop vs host config, and `awslogin` should start with `docs/jump-host-end-user-guide.md`.
```

In `docs/access-model.md`, at the end of the “Jump-host instance role” section (~after line 31), add:

```markdown
Operator-facing explanation (profiles, dual config, privilege model): `docs/jump-host-end-user-guide.md`.
```

In `docs/architecture.md`, immediately after the “Jump-host instance IAM is SSM-only by design.” bullet, add a sentence or sub-bullet:

```markdown
  Operator guide: `docs/jump-host-end-user-guide.md`.
```

In `docs/security-user-prerequisites.md`, after the paragraph that says the instance role is without significant privileges (~line 20), add:

```markdown
For operators learning SSO login, profiles, and why the instance role is not used on the host, see `docs/jump-host-end-user-guide.md`.
```

Do not paste the mental-model tables into these admin docs.

- [ ] **Step 2: Grep for accidental IMDS in the end-user guide narrative**

```bash
rg -n 'IMDS|metadata service|AWS_EC2_METADATA' docs/jump-host-end-user-guide.md
```

Expected: no matches in the main guide (architecture may still mention IMDS; that file is fine). If the end-user guide still mentions IMDS outside a deliberate absence, remove it.

- [ ] **Step 3: Commit**

```bash
git add docs/consumer-guide.md docs/access-model.md docs/architecture.md docs/security-user-prerequisites.md
git commit -m "$(cat <<'EOF'
docs: point admin guides at expanded end-user credentials guide

Add short cross-links so operators are sent to the privilege and dual-config explanation.
EOF
)"
```

---

## Spec coverage checklist (plan self-review)

| Spec requirement | Task |
| --- | --- |
| Expand single end-user guide (Approach A) | 1–3 |
| Already set up command box | 1 |
| Privilege model: all activity = SSO role, never instance role | 1, 3 |
| No IMDS in end-user narrative | 1, 3, 4 |
| Laptop vs host config table + pre-seed note | 1, 2 |
| Per-user vs `ec2-user` practical table | 1 |
| Profile / SSO mental model | 2 |
| Setup with placeholder profile block | 2 |
| Typical first-session workflow | 2 |
| Keep/tighten Quick start and tools | 3 |
| Rewrite tool openings; remove log-transfer IMDS sentence | 3 |
| Shorten Run As deep dive | 3 |
| Expand credential troubleshooting | 3 |
| Admin cross-links only | 4 |
| Success criteria read-through | 3 Step 5 |
| No runtime/code changes | All tasks (docs only) |

## Placeholder scan

Plan contains full Markdown to insert (no TBD/TODO). Fake SSO placeholders are explicit. Commits and verification commands are concrete.
