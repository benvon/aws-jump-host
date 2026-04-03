# Shared setup for Bats: repo root, fake terragrunt on PATH.
setup() {
  export REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "$REPO_ROOT" || exit 1
  export PATH="${BATS_TEST_DIRNAME}/bin:${PATH}"
  unset FAKE_TG_LOG || true
}
