# End-user credentials and privilege-model documentation

Status: approved design (pending implementation).

## Problem

Operators who are less familiar with the AWS CLI struggle with jump-host access. Feedback shows gaps around:

- How IAM Identity Center (SSO) login and named CLI profiles work
- That laptop `~/.aws` configuration is separate from configuration on the jump host
- That this platform’s privilege model differs from older “use the EC2 instance role while on the box” habits

Existing guidance in `docs/jump-host-end-user-guide.md` mentions SSM-only instance IAM and `awslogin`, but the mental model is easy to miss, and SSO/profile setup is thin.

## Goals

1. Make **bring-your-own privileges** obvious before command recipes: while logged into the jump host, **all** AWS-backed activity uses the operator’s SSO / IAM role privileges, **never** the EC2 instance role.
2. Teach that **laptop and jump-host AWS CLI configs are different**, and which one each step uses.
3. Explain **per-user Session Manager Run As vs shared `ec2-user`** with a practical comparison (whose home / `~/.aws`).
4. Structure the guide as **mental model → setup → typical workflow**, then retain connect/helpers/troubleshooting content edited for consistency.
5. Stay accessible without becoming a general AWS CLI manual (link out for CLI / Session Manager plugin install only).

## Non-goals

- New separate end-user primer files or a docs-site information-architecture overhaul
- Documenting AWS CLI itself beyond what is required to use this platform
- Changing `awslogin`, Ansible, Terraform, or other runtime behavior
- Admin how-tos for seeding profiles or choosing Run As models (point to consumer / access docs)
- Explaining IMDS / metadata-disable implementation details in the end-user narrative

## Audience

Jump-host **operators** (people who connect and work on the host), not platform admins. Assume they can run shell commands but may not know SSO profiles, `AWS_PROFILE`, or why instance-role habits fail here.

## Approach

**Approach A (approved):** Expand and restructure the single primary end-user doc `docs/jump-host-end-user-guide.md`. Front-load teaching material; keep a short “Already set up?” command box near the top for experienced users. Admin docs (`docs/consumer-guide.md`, `docs/access-model.md`, `docs/architecture.md`, `docs/security-user-prerequisites.md`) get short cross-links only—no parallel end-user rewrite.

## Document outline

Proposed top-level structure of `docs/jump-host-end-user-guide.md`:

1. Who this is for + short “Already set up?” command box
2. How privileges work on this jump host (vs old instance-role habits)
3. Two places for AWS config (laptop vs host)
4. Which Linux user you land as (per-user vs `ec2-user` table)
5. What an AWS CLI profile / SSO session is (plain language)
6. Setup: laptop profile + host profile (placeholders; admin may pre-seed)
7. Typical first-session workflow
8. Quick start helper script (existing, tightened)
9. On-host tools: `awslogin`, `kubelogin`, `log-transfer`
10. Persistent `/home`, tags, manual procedure, troubleshooting (existing; credential rows expanded)
11. Related documentation

## Content requirements

### Privilege model

- Opening a Session Manager session only proves the operator may open a shell. It does **not** grant the host’s AWS API powers.
- The EC2 instance role is **SSM-only by design**.
- Emphasize repeatedly: **any and all** AWS-backed activity on the jump host (`aws`, `awslogin`, `kubelogin`, `log-transfer`, kubectl talking to EKS, and similar) uses the operator’s **SSO / IAM role**, **explicitly not** the instance role.
- Practical check: after connect, if AWS calls fail with credential or AccessDenied errors, run `awslogin`, then `aws sts get-caller-identity`, and confirm the expected account/role (not an instance-role ARN).
- Do **not** discuss IMDS / metadata disable in the main narrative. Troubleshooting may say the instance role cannot perform the action and to use `awslogin` / the operator role.

### Two AWS configs (sticky spot)

| Step | Which machine | Which config | Purpose |
|------|---------------|--------------|---------|
| `aws sso login` / `jump-host-ssm.sh` / console Session Manager | Operator laptop | Laptop `~/.aws/config` (and cached SSO tokens) | Authenticate to **start** the session |
| `awslogin`, `kubelogin`, `log-transfer`, ad-hoc `aws` | Jump host | That Linux user’s `~/.aws/config` on the host | Authenticate to **call AWS from inside** the session |

Must state clearly:

- Fixing or copying a profile on the laptop does **not** change the host.
- Host home directories live on the persistent `/home` volume after first successful configure, so host `~/.aws` usually survives instance replacement **for that Linux user**.
- Admins may pre-seed a host profile and set `AWS_PROFILE` via login env; if the profile is missing, operators paste the same kind of SSO block their admin provided (or ask the admin).

### Linux user (Run As) — practical table only

| | Per-user Run As | Shared `ec2-user` |
|--|-----------------|-------------------|
| How to tell | `whoami` is the operator’s Linux username | `whoami` is `ec2-user` |
| Home / `~/.aws` | Under `/home/<you>/` | Under `/home/ec2-user/` |
| Who maintains host profile | Usually the operator (or admin seeds that home) | Shared; coordinate with teammates / admin |
| What “my config” means | Not the laptop’s; **this** host home | Not the laptop’s; the **shared** host home |

Deep Run As mechanics (`SSMSessionRunAs`, account defaults, document constraints) stay brief and point to admin/security docs; end users primarily need to know **which home they are in**.

### Profiles / SSO mental model

- A **profile** is a named block in `~/.aws/config` pointing at an Identity Center start URL, account, and permission set / role.
- **`AWS_PROFILE`** selects that block. On the host it is often set by login env; a matching profile must still exist in that Linux user’s `~/.aws/config`.
- **`aws sso login` (laptop)** and **`awslogin` (host)** refresh a time-limited SSO session. Host uses device-code flow because Session Manager has no browser.
- Verify with `aws sts get-caller-identity` on the machine where the work runs.

### Setup

1. From admin: profile name, region, and whether the environment uses per-user Run As or shared `ec2-user`.
2. **Laptop:** ensure SSO profile exists (placeholder `[profile …]` block if needed); `aws sso login --profile …`; `sts get-caller-identity`; then connect.
3. **Jump host:** `whoami` / `echo $HOME` / `echo $AWS_PROFILE`; ensure host `~/.aws/config` has the profile (or ask admin); `awslogin`; verify identity **on the host**.

### Typical first-session workflow

One happy path: laptop SSO login → connect → check Linux user / home → `awslogin` → verify identity on host → optional `kubelogin` / `log-transfer` → later AWS failures usually mean re-run `awslogin`, not “the box lost its role.”

### Existing sections to keep or rewrite

- **Keep:** helper-script quick start, connect filters, on-host tool recipes, persistent `/home`, tag table, manual procedure.
- **Rewrite openings** of `awslogin` / `kubelogin` / `log-transfer` so they reinforce SSO role (never instance role) and host config.
- **Expand troubleshooting** for credential confusion: wrong machine’s config fixed; unexpected `whoami` / `$HOME`; unset or mismatched `AWS_PROFILE`; expired SSO on host; AccessDenied that looks like “host broken.”
- Shorten the long Run As essay in favor of the practical table; keep a brief pointer for admins / advanced readers.

### Cross-links

Add or tighten one-line pointers from admin-oriented docs to the expanded end-user guide for the SSO / profile / privilege model. Do not duplicate the teaching material there.

## Success criteria

A less CLI-savvy operator can explain from the guide alone:

1. Why the instance role is not their AWS power on the jump host
2. That laptop and host AWS configs differ, and which one each step uses
3. How to tell per-user Run As vs shared `ec2-user` (`whoami` / `$HOME`)
4. How to complete laptop → connect → `awslogin` → verify → use an on-host tool

Experienced users still find a short command box near the top.

## Implementation notes

- Deliverable is documentation only (primarily `docs/jump-host-end-user-guide.md` plus light cross-link edits).
- After this spec is approved for implementation, write an implementation plan (writing-plans) before editing the guide.
