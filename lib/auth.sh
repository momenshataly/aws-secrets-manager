#!/usr/bin/env bash
# Auth helpers: save/restore AWS credentials and optionally assume a role.
# shellcheck disable=SC2034

set -euo pipefail

# Declared up front so `set -u` cannot trip on it before a fetch runs.
BITRISE_OIDC_ID_TOKEN=""

log_info() { echo "ℹ️  $*"; }
log_error() { echo "❌ $*" >&2; }
log_debug() {
    if [ "${verbose:-false}" = "true" ]; then
        echo "🐛 $*"
    fi
}

resolve_account_number() {
    local account="${account:-}"

    if [ -z "$account" ]; then
        log_error "Input 'account' is required when assuming a role."
        return 1
    fi

    printf '%s' "$account"
}

secrets_role_arn() {
    local account_number="$1"
    local role="${role_name:-}"

    if [ -z "$role" ]; then
        log_error "Input 'role_name' is required when assuming a role."
        return 1
    fi

    printf 'arn:aws:iam::%s:role/%s' "$account_number" "$role"
}

# True when both account and role_name are set (AssumeRole / OIDC assume path).
should_assume_role() {
    [ -n "${account:-}" ] && [ -n "${role_name:-}" ]
}

apply_region() {
    # No fallback: an implicit region silently targets the wrong endpoint and
    # surfaces as AccessDenied when IAM policies are scoped per region.
    if [ -z "${region:-}" ]; then
        log_error "Input 'region' is required (e.g. eu-west-1)."
        log_error "authenticate-with-aws does not export AWS_REGION, so it must be set explicitly here."
        return 1
    fi

    export AWS_REGION="$region"
    export AWS_DEFAULT_REGION="$region"
    log_debug "AWS_REGION=${AWS_REGION} AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}"
}

save_aws_credentials() {
    SAVED_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
    SAVED_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
    SAVED_AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"
    SAVED_AWS_REGION="${AWS_REGION:-}"
    SAVED_AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-}"
    HAD_AMBIENT_AWS_CREDS="false"
    DID_ASSUME_ROLE="false"
    if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
        HAD_AMBIENT_AWS_CREDS="true"
    fi
    log_debug "Saved ambient AWS credentials (present=${HAD_AMBIENT_AWS_CREDS})"
}

# Export temporary credentials into the current process (not envman — restored later).
export_temp_aws_credentials() {
    local access_key_id="$1"
    local secret_access_key="$2"
    local session_token="${3:-}"

    export AWS_ACCESS_KEY_ID="$access_key_id"
    export AWS_SECRET_ACCESS_KEY="$secret_access_key"
    if [ -n "$session_token" ]; then
        export AWS_SESSION_TOKEN="$session_token"
    else
        unset AWS_SESSION_TOKEN || true
    fi
}

current_caller_arn() {
    aws sts get-caller-identity --query Arn --output text 2>/dev/null || true
}

# Ambient credentials already are the target role (e.g. authenticate-with-aws
# assumed it). A role cannot re-assume itself unless it is its own trusted
# principal, so AssumeRole would fail with AccessDenied.
already_assumed_target_role() {
    local role="$1"
    local caller
    caller=$(current_caller_arn)
    [ -n "$caller" ] || return 1
    log_debug "Caller identity: ${caller}"
    case "$caller" in
        *":assumed-role/${role}/"*) return 0 ;;
        *) return 1 ;;
    esac
}

assume_role_with_credentials() {
    local role_arn="$1"
    local session="${session_name:-bitrise-${BITRISE_BUILD_NUMBER:-local}}"
    local response

    log_info "Assuming role via STS AssumeRole: ${role_arn}"
    response=$(aws sts assume-role \
        --role-arn "$role_arn" \
        --role-session-name "$session" \
        --output json) || {
        log_error "Failed to assume role: ${role_arn}"
        log_error "The current identity ($(current_caller_arn)) must be a trusted principal of that role."
        return 1
    }

    DID_ASSUME_ROLE="true"
    export_temp_aws_credentials \
        "$(printf '%s' "$response" | jq -r '.Credentials.AccessKeyId')" \
        "$(printf '%s' "$response" | jq -r '.Credentials.SecretAccessKey')" \
        "$(printf '%s' "$response" | jq -r '.Credentials.SessionToken')"
}

looks_like_jwt() {
    [[ "$1" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]
}

# Result is published in BITRISE_OIDC_ID_TOKEN rather than written to stdout:
# the log helpers also write to stdout, so a caller using command substitution
# would capture log lines together with the token and send that to STS.
fetch_bitrise_oidc_token() {
    local aud="$1"
    local url="${build_url:-${BITRISE_BUILD_URL:-}}"
    local token="${build_api_token:-${BITRISE_BUILD_API_TOKEN:-}}"
    local response

    BITRISE_OIDC_ID_TOKEN=""

    if [ -z "$url" ] || [ -z "$token" ]; then
        log_error "OIDC auth requires build_url and build_api_token (Bitrise build context)."
        return 1
    fi

    log_info "Fetching Bitrise OIDC identity token (audience=${aud})"
    response=$(curl -fsS -X POST "${url}/id_token.json" \
        -H "Authorization: ${token}" \
        -H "BUILD_API_TOKEN: ${token}" \
        -H "Content-Type: application/json; charset=UTF-8" \
        -d "{\"aud\":\"${aud}\"}") || {
        log_error "Failed to fetch OIDC identity token from Bitrise."
        return 1
    }

    BITRISE_OIDC_ID_TOKEN=$(printf '%s' "$response" | jq -r '.id_token // empty')
}

assume_role_with_oidc() {
    local role_arn="$1"
    local aud="$2"
    local session="${session_name:-bitrise-${BITRISE_BUILD_NUMBER:-local}}"
    local response

    fetch_bitrise_oidc_token "$aud" || return 1
    if [ -z "${BITRISE_OIDC_ID_TOKEN}" ]; then
        log_error "Bitrise OIDC response contained no 'id_token'."
        return 1
    fi
    if ! looks_like_jwt "${BITRISE_OIDC_ID_TOKEN}"; then
        log_error "Fetched OIDC token is not a JWT (expected three dot-separated segments)."
        log_error "STS rejects this as InvalidIdentityToken. Enable verbose to inspect its shape."
        log_debug "Token length=${#BITRISE_OIDC_ID_TOKEN} first_chars=${BITRISE_OIDC_ID_TOKEN:0:8}"
        return 1
    fi

    log_info "Assuming role via STS AssumeRoleWithWebIdentity: ${role_arn}"
    response=$(aws sts assume-role-with-web-identity \
        --role-arn "$role_arn" \
        --role-session-name "$session" \
        --web-identity-token "${BITRISE_OIDC_ID_TOKEN}" \
        --output json) || {
        log_error "Failed to assume role with web identity: ${role_arn}"
        BITRISE_OIDC_ID_TOKEN=""
        return 1
    }
    BITRISE_OIDC_ID_TOKEN=""

    DID_ASSUME_ROLE="true"
    export_temp_aws_credentials \
        "$(printf '%s' "$response" | jq -r '.Credentials.AccessKeyId')" \
        "$(printf '%s' "$response" | jq -r '.Credentials.SecretAccessKey')" \
        "$(printf '%s' "$response" | jq -r '.Credentials.SessionToken')"
}

authenticate_for_secrets() {
    local account_number role_arn

    apply_region || return 1

    # Partial assume inputs are invalid — require both or neither.
    if { [ -n "${account:-}" ] && [ -z "${role_name:-}" ]; } || \
       { [ -z "${account:-}" ] && [ -n "${role_name:-}" ]; }; then
        log_error "To assume a role, pass both 'account' and 'role_name' (or omit both to use ambient AWS credentials)."
        return 1
    fi

    if should_assume_role; then
        account_number=$(resolve_account_number) || return 1
        role_arn=$(secrets_role_arn "$account_number")
        log_info "Will assume role account=${account_number} role=${role_arn}"

        if [ "${HAD_AMBIENT_AWS_CREDS}" = "true" ]; then
            if already_assumed_target_role "${role_name}"; then
                log_info "Ambient credentials already are ${role_name}; skipping AssumeRole"
                return 0
            fi
            assume_role_with_credentials "$role_arn" || return 1
            return 0
        fi

        if [ -n "${audience:-}" ]; then
            assume_role_with_oidc "$role_arn" "$audience" || return 1
            return 0
        fi

        if [ -n "${access_key_id:-}" ] && [ -n "${secret_access_key:-}" ]; then
            log_info "Using access key inputs, then assuming secrets role"
            export_temp_aws_credentials "$access_key_id" "$secret_access_key" ""
            assume_role_with_credentials "$role_arn" || return 1
            return 0
        fi

        log_error "account/role_name were set but no credentials are available to assume the role."
        log_error "Provide ambient AWS_* (e.g. authenticate-with-aws), audience for OIDC, or access_key_id/secret_access_key."
        return 1
    fi

    # No account/role_name → use ambient credentials (typical after authenticate-with-aws).
    if [ "${HAD_AMBIENT_AWS_CREDS}" = "true" ]; then
        log_info "Using ambient AWS credentials (account/role_name omitted; skipping AssumeRole)"
        return 0
    fi

    if [ -n "${access_key_id:-}" ] && [ -n "${secret_access_key:-}" ]; then
        log_info "Using access key inputs (no role assume)"
        export_temp_aws_credentials "$access_key_id" "$secret_access_key" ""
        return 0
    fi

    log_error "No AWS credentials available."
    log_error "Run authenticate-with-aws first (omit account/role_name here), or pass account+role_name with audience/access keys."
    return 1
}

# Restore prior AWS credentials for subsequent Steps via envman (only if we assumed).
restore_aws_credentials() {
    if [ "${DID_ASSUME_ROLE:-false}" != "true" ]; then
        log_info "No role assume performed; leaving AWS credentials unchanged for subsequent Steps"
        return 0
    fi

    if [ "${HAD_AMBIENT_AWS_CREDS}" = "true" ]; then
        log_info "Restoring prior AWS credentials for subsequent Steps"
        envman add --key AWS_ACCESS_KEY_ID --value "${SAVED_AWS_ACCESS_KEY_ID}" --sensitive
        envman add --key AWS_SECRET_ACCESS_KEY --value "${SAVED_AWS_SECRET_ACCESS_KEY}" --sensitive
        if [ -n "${SAVED_AWS_SESSION_TOKEN}" ]; then
            envman add --key AWS_SESSION_TOKEN --value "${SAVED_AWS_SESSION_TOKEN}" --sensitive
        else
            envman add --key AWS_SESSION_TOKEN --value ""
        fi
        if [ -n "${SAVED_AWS_REGION}" ]; then
            envman add --key AWS_REGION --value "${SAVED_AWS_REGION}"
        fi
        if [ -n "${SAVED_AWS_DEFAULT_REGION}" ]; then
            envman add --key AWS_DEFAULT_REGION --value "${SAVED_AWS_DEFAULT_REGION}"
        fi
    else
        log_info "No prior AWS credentials to restore after assume"
        :
    fi
}
