#!/usr/bin/env bash
# Auth helpers: save/restore AWS credentials and assume the secrets-account role.
# shellcheck disable=SC2034

set -euo pipefail

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
        log_error "Input 'account' is required (AWS account ID)."
        return 1
    fi

    printf '%s' "$account"
}

secrets_role_arn() {
    local account_number="$1"
    local role="${role_name:-}"

    if [ -z "$role" ]; then
        log_error "Input 'role_name' is required."
        return 1
    fi

    printf 'arn:aws:iam::%s:role/%s' "$account_number" "$role"
}

save_aws_credentials() {
    SAVED_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
    SAVED_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
    SAVED_AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"
    SAVED_AWS_REGION="${AWS_REGION:-}"
    SAVED_AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-}"
    HAD_AMBIENT_AWS_CREDS="false"
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
        return 1
    }

    export_temp_aws_credentials \
        "$(printf '%s' "$response" | jq -r '.Credentials.AccessKeyId')" \
        "$(printf '%s' "$response" | jq -r '.Credentials.SecretAccessKey')" \
        "$(printf '%s' "$response" | jq -r '.Credentials.SessionToken')"
}

fetch_bitrise_oidc_token() {
    local aud="$1"
    local url="${build_url:-${BITRISE_BUILD_URL:-}}"
    local token="${build_api_token:-${BITRISE_BUILD_API_TOKEN:-}}"
    local response

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

    printf '%s' "$response" | jq -r '.id_token'
}

assume_role_with_oidc() {
    local role_arn="$1"
    local aud="$2"
    local session="${session_name:-bitrise-${BITRISE_BUILD_NUMBER:-local}}"
    local identity_token
    local response

    identity_token=$(fetch_bitrise_oidc_token "$aud") || return 1
    if [ -z "$identity_token" ] || [ "$identity_token" = "null" ]; then
        log_error "OIDC identity token response was empty."
        return 1
    fi

    log_info "Assuming role via STS AssumeRoleWithWebIdentity: ${role_arn}"
    response=$(aws sts assume-role-with-web-identity \
        --role-arn "$role_arn" \
        --role-session-name "$session" \
        --web-identity-token "$identity_token" \
        --output json) || {
        log_error "Failed to assume role with web identity: ${role_arn}"
        return 1
    }

    export_temp_aws_credentials \
        "$(printf '%s' "$response" | jq -r '.Credentials.AccessKeyId')" \
        "$(printf '%s' "$response" | jq -r '.Credentials.SecretAccessKey')" \
        "$(printf '%s' "$response" | jq -r '.Credentials.SessionToken')"
}

authenticate_for_secrets() {
    local account_number role_arn

    account_number=$(resolve_account_number) || return 1
    role_arn=$(secrets_role_arn "$account_number")
    log_info "Secrets account=${account_number} role=${role_arn}"

    export AWS_REGION="${region:-us-east-1}"
    export AWS_DEFAULT_REGION="${region:-us-east-1}"

    if [ "${HAD_AMBIENT_AWS_CREDS}" = "true" ]; then
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

    log_error "No AWS credentials available."
    log_error "Provide ambient AWS_* (e.g. run authenticate-with-aws first), set audience for OIDC, or pass access_key_id/secret_access_key."
    return 1
}

# Restore prior AWS credentials for subsequent Steps via envman.
restore_aws_credentials() {
    if [ "${HAD_AMBIENT_AWS_CREDS}" = "true" ]; then
        log_info "Restoring prior AWS credentials for subsequent Steps"
        envman add --key AWS_ACCESS_KEY_ID --value "${SAVED_AWS_ACCESS_KEY_ID}" --sensitive
        envman add --key AWS_SECRET_ACCESS_KEY --value "${SAVED_AWS_SECRET_ACCESS_KEY}" --sensitive
        if [ -n "${SAVED_AWS_SESSION_TOKEN}" ]; then
            envman add --key AWS_SESSION_TOKEN --value "${SAVED_AWS_SESSION_TOKEN}" --sensitive
        else
            # Clear session token if prior creds had none (static keys).
            envman add --key AWS_SESSION_TOKEN --value ""
        fi
        if [ -n "${SAVED_AWS_REGION}" ]; then
            envman add --key AWS_REGION --value "${SAVED_AWS_REGION}"
        fi
        if [ -n "${SAVED_AWS_DEFAULT_REGION}" ]; then
            envman add --key AWS_DEFAULT_REGION --value "${SAVED_AWS_DEFAULT_REGION}"
        fi
    else
        log_info "No prior AWS credentials to restore; clearing temporary secrets-role credentials from envman"
        # Leave process-local exports; subsequent Steps won't inherit them unless envman set them.
        # Ensure we don't accidentally persist secrets-role creds if we exported via envman earlier (we don't).
        :
    fi
}
