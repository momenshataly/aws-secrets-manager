#!/usr/bin/env bash
# Bitrise step: fetch AWS Secrets Manager secrets into env vars (GHA parity).
set -euo pipefail

THIS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Prefer BITRISE_STEP_SOURCE_DIR when running as a Bitrise step.
STEP_DIR="${BITRISE_STEP_SOURCE_DIR:-$THIS_SCRIPT_DIR}"

# shellcheck source=lib/auth.sh
source "${STEP_DIR}/lib/auth.sh"
# shellcheck source=lib/inject-secrets.sh
source "${STEP_DIR}/lib/inject-secrets.sh"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "Required command not found: $1"
        exit 1
    fi
}

main() {
    require_cmd aws
    require_cmd jq
    require_cmd curl
    require_cmd envman

    if [ -z "${secrets:-}" ]; then
        log_error "Input 'secrets' is required."
        exit 1
    fi
    if [ -z "${account:-}" ]; then
        log_error "Input 'account' is required."
        exit 1
    fi
    if [ -z "${role_name:-}" ]; then
        log_error "Input 'role_name' is required."
        exit 1
    fi

    TMPDIR_STEP=$(mktemp -d)
    trap 'rm -rf "$TMPDIR_STEP"' EXIT
    export TMPDIR_STEP

    log_info "Parsing secrets input"
    export SECRETS_INPUT="${secrets}"
    parse_output=$(bash "${STEP_DIR}/lib/parse-secrets.sh")
    has_any_filter=$(printf '%s\n' "$parse_output" | sed -n 's/^has_any_filter=//p')
    has_any_no_filter=$(printf '%s\n' "$parse_output" | sed -n 's/^has_any_no_filter=//p')
    log_debug "has_any_filter=${has_any_filter} has_any_no_filter=${has_any_no_filter}"

    if [ "$has_any_filter" != "true" ] && [ "$has_any_no_filter" != "true" ]; then
        log_error "No secret lines found in 'secrets' input."
        exit 1
    fi

    save_aws_credentials
    authenticate_for_secrets

    log_info "Injecting secrets into Environment Variables"
    inject_all_secrets

    restore_aws_credentials
    log_info "Done"
}

main "$@"
