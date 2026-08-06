#!/usr/bin/env bash
# Unit-style tests for parse-secrets.sh (no AWS required).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_STEP=$(mktemp -d)
trap 'rm -rf "$TMPDIR_STEP"' EXIT
export TMPDIR_STEP

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

# Mixed: all-keys + selective
export SECRETS_INPUT=$'APP,my-app/config\n,my-app/config,API_TOKEN\nOTHER,other-app/settings,API_TOKEN|DB_PASSWORD\n'
out=$(bash "${ROOT}/lib/parse-secrets.sh")
echo "$out" | grep -q 'has_any_filter=true' || fail "expected has_any_filter=true"
echo "$out" | grep -q 'has_any_no_filter=true' || fail "expected has_any_no_filter=true"

grep -qx 'APP,my-app/config' "${TMPDIR_STEP}/aws-secrets-no-filter.txt" || fail "missing no-filter line"
grep -qx '|my-app/config|API_TOKEN' "${TMPDIR_STEP}/aws-secrets-filter.txt" || fail "missing selective blank-prefix line"
grep -qx 'OTHER|other-app/settings|API_TOKEN|DB_PASSWORD' "${TMPDIR_STEP}/aws-secrets-filter.txt" || fail "missing selective multi-key line"
pass "mixed parse"

# Only selective
export SECRETS_INPUT=$'APP,my-app/config,API_TOKEN\n'
out=$(bash "${ROOT}/lib/parse-secrets.sh")
echo "$out" | grep -q 'has_any_filter=true' || fail "selective-only filter"
echo "$out" | grep -q 'has_any_no_filter=false' || fail "selective-only no-filter false"
[ ! -s "${TMPDIR_STEP}/aws-secrets-no-filter.txt" ] || fail "no-filter should be empty"
pass "selective only"

# Only all-keys + blank lines / whitespace
export SECRETS_INPUT=$'\n  APP,my-app/config  \n\nsecret-only\n'
out=$(bash "${ROOT}/lib/parse-secrets.sh")
echo "$out" | grep -q 'has_any_filter=false' || fail "all-keys filter false"
echo "$out" | grep -q 'has_any_no_filter=true' || fail "all-keys no-filter true"
grep -qx 'APP,my-app/config' "${TMPDIR_STEP}/aws-secrets-no-filter.txt" || fail "trimmed line"
grep -qx 'secret-only' "${TMPDIR_STEP}/aws-secrets-no-filter.txt" || fail "secret-only line"
pass "all-keys only"

# Env name helper (source inject helpers)
# shellcheck source=../lib/inject-secrets.sh
name_transformation=uppercase
source "${ROOT}/lib/inject-secrets.sh"
[ "$(to_env_name APP api_token)" = "APP_API_TOKEN" ] || fail "uppercase prefix"
name_transformation=lowercase
[ "$(to_env_name lc Api_Token)" = "lc_api_token" ] || fail "lowercase prefix"
name_transformation=none
[ "$(to_env_name APP DB_PASSWORD)" = "APP_DB_PASSWORD" ] || fail "none keeps case after safe chars"
name_transformation=uppercase
[ "$(to_env_name "" '0/test/secret')" = "_0_TEST_SECRET" ] || fail "leading digit"
pass "to_env_name"

echo "All parse tests passed."
