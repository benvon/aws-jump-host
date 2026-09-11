#!/usr/bin/env bats
# Tests for session_comfort login helpers (awslogin / kubelogin).

setup() {
  local repo_root
  repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "$repo_root" || exit 1
  AWSLOGIN="$repo_root/ansible/roles/session_comfort/files/awslogin"
  KUBELOGIN="$repo_root/ansible/roles/session_comfort/files/kubelogin"
  FAKE_BIN="$(mktemp -d)"
  CLUSTER_FILE="$(mktemp)"
  AWS_LOG="$(mktemp)"
  KUBE_LOG="$(mktemp)"
  export AWS_LOG KUBE_LOG
  export JUMP_HOST_EKS_CLUSTER_FILE="$CLUSTER_FILE"
  export PATH="${FAKE_BIN}:${PATH}"
  unset AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION || true

  cat >"$FAKE_BIN/aws" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >>"${AWS_LOG}"
printf '\n' >>"${AWS_LOG}"
exit 0
EOF
  cat >"$FAKE_BIN/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >>"${KUBE_LOG}"
printf '\n' >>"${KUBE_LOG}"
exit 0
EOF
  chmod +x "$FAKE_BIN/aws" "$FAKE_BIN/kubectl"
}

teardown() {
  rm -rf "${FAKE_BIN:-}" "${CLUSTER_FILE:-}" "${AWS_LOG:-}" "${KUBE_LOG:-}"
}

@test "awslogin fails when AWS_PROFILE is unset" {
  run "$AWSLOGIN"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"AWS_PROFILE"* ]]
}

@test "awslogin runs device-code SSO login for AWS_PROFILE" {
  export AWS_PROFILE=jump-sso
  run "$AWSLOGIN"
  [[ "$status" -eq 0 ]]
  grep -q -- '--profile jump-sso' "$AWS_LOG"
  grep -q -- '--no-browser' "$AWS_LOG"
  grep -q -- '--use-device-code' "$AWS_LOG"
  grep -q -- 'sso login' "$AWS_LOG"
}

@test "kubelogin fails when AWS_PROFILE is unset" {
  export AWS_REGION=us-west-2
  printf 'stage-eks\n' >"$CLUSTER_FILE"
  run "$KUBELOGIN"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"AWS_PROFILE"* ]]
}

@test "kubelogin fails when AWS_REGION is unset" {
  export AWS_PROFILE=jump-sso
  printf 'stage-eks\n' >"$CLUSTER_FILE"
  run "$KUBELOGIN"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"AWS_REGION"* ]]
}

@test "kubelogin fails when cluster name is not configured" {
  export AWS_PROFILE=jump-sso AWS_REGION=us-west-2
  : >"$CLUSTER_FILE"
  run "$KUBELOGIN"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"cluster"* ]]
}

@test "kubelogin updates kubeconfig and selects the cluster context" {
  export AWS_PROFILE=jump-sso AWS_REGION=us-west-2
  printf 'stage-eks\n' >"$CLUSTER_FILE"
  run "$KUBELOGIN"
  echo "status=$status output=$output aws=$(cat "$AWS_LOG") kube=$(cat "$KUBE_LOG")"
  [[ "$status" -eq 0 ]]
  grep -q -- 'eks update-kubeconfig' "$AWS_LOG"
  grep -q -- '--name stage-eks' "$AWS_LOG"
  grep -q -- '--alias stage-eks' "$AWS_LOG"
  grep -q -- '--region us-west-2' "$AWS_LOG"
  grep -q -- '--profile jump-sso' "$AWS_LOG"
  grep -q -- 'config use-context stage-eks' "$KUBE_LOG"
}
