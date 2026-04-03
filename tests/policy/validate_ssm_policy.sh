#!/usr/bin/env bash
set -euo pipefail

policy_file="${1:-}"
if [[ -z "$policy_file" || ! -f "$policy_file" ]]; then
  echo "usage: $0 <policy.json>" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

fail() {
  echo "policy validation failed: $*" >&2
  exit 1
}

jq -e . "$policy_file" >/dev/null || fail "invalid JSON"

ver="$(jq -r '.Version // empty' "$policy_file")"
[[ "$ver" == "2012-10-17" ]] || fail "expected Version 2012-10-17, got '$ver'"

# Exactly one StartSession statement with instance + managed-instance resources and StringEquals AccessProfile (no ForAnyValue on that key).
start_count="$(jq '[.Statement[] | select(.Action == "ssm:StartSession" or .Action == ["ssm:StartSession"])] | length' "$policy_file")"
[[ "$start_count" -eq 1 ]] || fail "expected exactly one StartSession statement, found $start_count"

has_for_any="$(jq '[.. | objects | select(has("ForAnyValue:StringEquals")) | .["ForAnyValue:StringEquals"] | keys[]?] | map(select(. == "ssm:resourceTag/AccessProfile")) | length' "$policy_file")"
[[ "$has_for_any" -eq 0 ]] || fail "ForAnyValue:StringEquals must not be used for ssm:resourceTag/AccessProfile"

access_cond="$(jq -r '.Statement[] | select(.Action == "ssm:StartSession") | .Condition.StringEquals["ssm:resourceTag/AccessProfile"] // empty' "$policy_file")"
[[ -n "$access_cond" ]] || fail "StartSession must use Condition.StringEquals ssm:resourceTag/AccessProfile"
[[ "$access_cond" == *'PrincipalTag/AccessProfile'* ]] || fail "AccessProfile condition should reference aws:PrincipalTag/AccessProfile"

resume_count="$(jq '[.Statement[] | select((.Action | type == "array") and ((.Action | index("ssm:ResumeSession")) != null))] | length' "$policy_file")"
[[ "$resume_count" -eq 1 ]] || fail "expected one ResumeSession/TerminateSession statement"

resume_on_session="$(jq -r '.Statement[] | select((.Action | type == "array") and ((.Action | index("ssm:ResumeSession")) != null)) | .Resource // empty' "$policy_file")"
jq -n --arg r "$resume_on_session" --arg n 'session/${aws:username}-' -e '($r | index($n) != null)' >/dev/null \
  || fail "Resume/Terminate should be scoped to session ARN pattern (got: $resume_on_session)"

echo "policy OK: $policy_file"
