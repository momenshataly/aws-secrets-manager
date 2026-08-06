#!/usr/bin/env bash
# Parse secrets input: split lines into "no filter" (1-2 segments) vs "has filter" (3 segments).
# Lines with 3 segments (PREFIX,secret-id,key1|key2) go to selective path; 1-2 segments go to all-keys path.
# Reads SECRETS_INPUT from env.
# Writes:
#   $TMPDIR_STEP/aws-secrets-no-filter.txt
#   $TMPDIR_STEP/aws-secrets-filter.txt  (format: prefix|secret_id|key1|key2)
#   has_any_filter / has_any_no_filter as exported vars via stdout markers consumed by step.sh

set -euo pipefail

: "${TMPDIR_STEP:?TMPDIR_STEP must be set}"
: "${SECRETS_INPUT:=}"

no_filter_file="${TMPDIR_STEP}/aws-secrets-no-filter.txt"
filter_file="${TMPDIR_STEP}/aws-secrets-filter.txt"
: >"$no_filter_file"
: >"$filter_file"

while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$line" ] && continue

    IFS=',' read -r seg1 seg2 seg3 <<<"$line"
    if [ -n "${seg3:-}" ]; then
        # Key list present → selective keys (prefix|secret_id|key1|key2)
        printf '%s|%s|%s\n' "$seg1" "$seg2" "$seg3" >>"$filter_file"
    else
        # 1–2 segments → all-keys path
        printf '%s\n' "$line" >>"$no_filter_file"
    fi
done <<<"${SECRETS_INPUT}"

if [ -s "$filter_file" ]; then
    echo "has_any_filter=true"
else
    echo "has_any_filter=false"
fi

if [ -s "$no_filter_file" ]; then
    echo "has_any_no_filter=true"
else
    echo "has_any_no_filter=false"
fi
