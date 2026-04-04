# IAM policy templates

## `ssm-access-example.json`

- **AccessProfile:** Use `StringEquals` (not `ForAnyValue:StringEquals`) so the principal’s `AccessProfile` tag must match the instance tag as a single value. Principals should carry **exactly one** `AccessProfile` tag value; multi-value tag sets in some federation setups can unintentionally broaden access with `ForAnyValue`.
- **StartSession** is allowed only on EC2 and managed-instance ARNs with `JumpHost` and `AccessProfile` tag conditions.
- **ResumeSession** and **TerminateSession** are allowed only on session ARNs matching `arn:aws:ssm:*:*:session/${aws:username}-*`. Session resources do not use the same `ssm:resourceTag/*` condition keys as instances; gating for new sessions remains on **StartSession**.

Validate changes in the IAM policy simulator for your identity type (IAM user vs assumed role vs SAML/OIDC).
