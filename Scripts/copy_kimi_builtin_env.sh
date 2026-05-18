#!/bin/sh
set -eu

ENV_FILE="${PROJECT_DIR}/.env"
OUTPUT_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
OUTPUT_FILE="${OUTPUT_DIR}/KimiBuiltin.env"

rm -f "$OUTPUT_FILE"

if [ ! -f "$ENV_FILE" ]; then
    exit 0
fi

KIMI_BUILTIN_API_KEY=""
while IFS='=' read -r key value || [ -n "$key" ]; do
    key="$(printf '%s' "$key" | tr -d '\r' | xargs)"
    value="$(printf '%s' "$value" | tr -d '\r' | xargs)"
    if [ "$key" = "KIMI_BUILTIN_API_KEY" ]; then
        KIMI_BUILTIN_API_KEY="$value"
        break
    fi
done < "$ENV_FILE"

if [ -z "$KIMI_BUILTIN_API_KEY" ]; then
    exit 0
fi

mkdir -p "$OUTPUT_DIR"
umask 077
printf 'KIMI_BUILTIN_API_KEY=%s\n' "$KIMI_BUILTIN_API_KEY" > "$OUTPUT_FILE"
chmod 600 "$OUTPUT_FILE"
