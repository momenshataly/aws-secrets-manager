#!/usr/bin/env bash
# Unit-style tests for auth.sh (no AWS required; aws/curl are stubbed).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

# shellcheck source=../lib/auth.sh
source "${ROOT}/lib/auth.sh"

JWT='eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJiaXRyaXNlIn0.c2lnbmF0dXJl'

# --- region -----------------------------------------------------------------

unset region AWS_REGION AWS_DEFAULT_REGION
! apply_region 2>/dev/null || fail "apply_region accepted a missing region"
pass "region is required"

export AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1
unset region
! apply_region 2>/dev/null || fail "apply_region fell back to ambient region"
pass "region has no ambient fallback"

region=eu-west-1
apply_region >/dev/null
[ "$AWS_REGION" = "eu-west-1" ] || fail "AWS_REGION=$AWS_REGION"
[ "$AWS_DEFAULT_REGION" = "eu-west-1" ] || fail "AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION"
pass "explicit region is exported"

# --- JWT shape --------------------------------------------------------------

looks_like_jwt "$JWT" || fail "rejected a valid JWT"
! looks_like_jwt "not-a-jwt" || fail "accepted a non-JWT"
! looks_like_jwt "$(printf 'log line\n%s' "$JWT")" || fail "accepted a log-polluted JWT"
pass "JWT shape check"

# --- OIDC token must not travel over stdout ---------------------------------
# Regression: log_info writes to stdout, so returning the token via stdout made
# command substitution capture the log line too, and STS saw an invalid JWT.

curl() { printf '{"id_token":"%s"}' "$JWT"; }

build_url="https://app.bitrise.io/build/deadbeef"
build_api_token="fake-token"

# Capture stdout via a file, not command substitution: a subshell would hide
# the variable assignment being asserted here.
stdout_file=$(mktemp)
trap 'rm -f "$stdout_file"' EXIT

fetch_bitrise_oidc_token sts.amazonaws.com >"$stdout_file"
[ "$BITRISE_OIDC_ID_TOKEN" = "$JWT" ] || fail "token not published in BITRISE_OIDC_ID_TOKEN"
pass "token published in a variable"

grep -q "$JWT" "$stdout_file" && fail "token leaked onto stdout"
pass "token never written to stdout"

grep -q "Fetching Bitrise OIDC identity token" "$stdout_file" || fail "expected the log line on stdout"
pass "log line still reaches the build log"

looks_like_jwt "$BITRISE_OIDC_ID_TOKEN" || fail "fetched token is not a clean JWT"
pass "fetched token is a clean JWT"

# Missing id_token in the response must be reported, not passed to STS.
curl() { printf '{"error":"unauthorized"}'; }
fetch_bitrise_oidc_token sts.amazonaws.com >/dev/null
[ -z "$BITRISE_OIDC_ID_TOKEN" ] || fail "expected empty token, got '$BITRISE_OIDC_ID_TOKEN'"
pass "absent id_token yields empty token"

unset -f curl

# --- self-assume detection --------------------------------------------------

aws() { echo "arn:aws:sts::111122223333:assumed-role/ios-bitrise/bitrise-248041"; }

already_assumed_target_role ios-bitrise || fail "did not detect self-assume"
pass "self-assume detected"

! already_assumed_target_role other-role || fail "false positive on a different role"
pass "different role still assumed"

unset -f aws

echo "All auth tests passed."
