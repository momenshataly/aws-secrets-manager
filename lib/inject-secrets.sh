#!/usr/bin/env bash
# Fetch secrets from AWS Secrets Manager and export as env vars via envman.
# Supports all-keys lines and selective key-filter lines (GHA parity).

set -euo pipefail

log_info() { echo "ℹ️  $*"; }
log_error() { echo "❌ $*" >&2; }

# Build env var name like the official AWS action / HF GHA:
# PREFIX_KEY (optional name transformation, safe chars only).
to_env_name() {
    local prefix="$1"
    local key="$2"
    local safe_name final_name
    local transform="${name_transformation:-uppercase}"

    safe_name=${key//[^A-Za-z0-9_]/_}
    # Env vars must not start with a digit.
    if [[ "$safe_name" =~ ^[0-9] ]]; then
        safe_name="_${safe_name}"
    fi

    case "$transform" in
    uppercase) final_name=$(printf '%s' "$safe_name" | tr '[:lower:]' '[:upper:]') ;;
    lowercase) final_name=$(printf '%s' "$safe_name" | tr '[:upper:]' '[:lower:]') ;;
    none) final_name="$safe_name" ;;
    *)
        log_error "Unsupported name_transformation: ${transform}"
        return 1
        ;;
    esac

    if [ -n "$prefix" ]; then
        printf '%s_%s' "$prefix" "$final_name"
    else
        printf '%s' "$final_name"
    fi
}

export_secret_env() {
    local env_name="$1"
    local value="$2"
    local value_file

    if [ -z "$env_name" ]; then
        log_error "Refusing to export empty environment variable name"
        return 1
    fi

    value_file=$(mktemp)
    printf '%s' "$value" >"$value_file"
    envman add --key "$env_name" --valuefile "$value_file" --sensitive
    rm -f "$value_file"
    log_info "Exported ${env_name}"
}

fetch_secret_string() {
    local secret_id="$1"
    local err
    err=$(mktemp)

    if ! aws secretsmanager get-secret-value \
        --secret-id "$secret_id" \
        --query SecretString \
        --output text 2>"$err"; then
        log_error "Failed to get secret: ${secret_id}"
        if [ -s "$err" ]; then
            log_error "$(cat "$err")"
        fi
        rm -f "$err"
        return 1
    fi
    rm -f "$err"
}

is_json_object() {
    local value="$1"
    printf '%s' "$value" | jq -e 'type == "object"' >/dev/null 2>&1
}

# Transform a secret id / name into a safe env prefix when no alias is given.
secret_id_to_name() {
    local secret_id="$1"
    local name

    # Strip ARN suffix noise: arn:aws:secretsmanager:region:acct:secret:name-xxxxxx
    if [[ "$secret_id" == arn:aws:secretsmanager:* ]]; then
        name="${secret_id##*:secret:}"
        # AWS appends a random 6-char suffix after the last hyphen for ARNs.
        name="${name%-??????}"
    else
        name="$secret_id"
    fi

    to_env_name "" "$name"
}

export_parsed_json_keys() {
    local prefix="$1"
    local secret_json="$2"
    local key env_name value

    while IFS= read -r key; do
        [ -z "$key" ] && continue
        value=$(printf '%s' "$secret_json" | jq -r --arg k "$key" '.[$k] | if type == "string" then . else tojson end')
        env_name=$(to_env_name "$prefix" "$key")
        export_secret_env "$env_name" "$value"
    done < <(printf '%s' "$secret_json" | jq -r 'keys[]')
}

# Process one all-keys line: `PREFIX,secret-id` or `secret-id` or `,secret-id`
process_no_filter_line() {
    local line="$1"
    local prefix="" secret_id="" secret_json env_name

    if [[ "$line" == *,* ]]; then
        prefix="${line%%,*}"
        secret_id="${line#*,}"
        # Trim whitespace around secret id
        secret_id=$(printf '%s' "$secret_id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    else
        secret_id="$line"
        prefix=""
    fi

    log_info "Fetching secret (all keys): ${secret_id}"
    secret_json=$(fetch_secret_string "$secret_id") || return 1

    if [ "${parse_json_secrets:-true}" = "true" ] && is_json_object "$secret_json"; then
        # Blank alias (,secret-id) → keys only; no alias (secret-id) → SECRETNAME_KEY
        if [[ "$line" != *,* ]]; then
            prefix=$(secret_id_to_name "$secret_id")
        fi
        export_parsed_json_keys "$prefix" "$secret_json"
    else
        if [ -n "$prefix" ]; then
            env_name="$prefix"
        elif [[ "$line" == *,* ]]; then
            # Blank alias with non-JSON → fall back to transformed secret name
            env_name=$(secret_id_to_name "$secret_id")
        else
            env_name=$(secret_id_to_name "$secret_id")
        fi
        export_secret_env "$env_name" "$secret_json"
    fi
}

inject_no_filter_secrets() {
    local file="${TMPDIR_STEP}/aws-secrets-no-filter.txt"
    local line

    [ -f "$file" ] || return 0
    [ -s "$file" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        process_no_filter_line "$line" || return 1
    done <"$file"
}

inject_selective_secrets() {
    local filter_file="${TMPDIR_STEP}/aws-secrets-filter.txt"
    local line prefix rest secret_id keys_str key secret_json value env_name

    [ -f "$filter_file" ] || return 0
    [ -s "$filter_file" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue

        prefix="${line%%|*}"
        rest="${line#*|}"
        secret_id="${rest%%|*}"
        keys_str="${rest#*|}"

        log_info "Fetching secret (selective keys): ${secret_id}"
        secret_json=$(fetch_secret_string "$secret_id") || return 1

        IFS='|' read -ra keys <<<"$keys_str"
        for key in "${keys[@]}"; do
            key=$(printf '%s' "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$key" ] && continue

            if ! printf '%s' "$secret_json" | jq -e --arg k "$key" 'has($k)' >/dev/null 2>&1; then
                log_error "Key '${key}' not found in secret: ${secret_id}"
                return 1
            fi

            value=$(printf '%s' "$secret_json" | jq -r --arg k "$key" '.[$k] // empty')
            env_name=$(to_env_name "$prefix" "$key")
            export_secret_env "$env_name" "$value"
        done
    done <"$filter_file"
}

inject_all_secrets() {
    inject_no_filter_secrets || return 1
    inject_selective_secrets || return 1
}
