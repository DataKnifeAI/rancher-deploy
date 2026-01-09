#!/usr/bin/env bash
# Generate JWT for GitHub App using bash/openssl
# Based on: https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app

# Parameters - no defaults to prevent hardcoded secrets
CLIENT_ID="${1:-}"
PRIVATE_KEY_PATH="${2:-}"

if [[ -z "$CLIENT_ID" ]]; then
    echo "Error: Client ID is required" >&2
    echo "Usage: $0 <client_id> <private_key_path>" >&2
    exit 1
fi

if [[ -z "$PRIVATE_KEY_PATH" ]]; then
    echo "Error: Private key path is required" >&2
    echo "Usage: $0 <client_id> <private_key_path>" >&2
    exit 1
fi

if [[ ! -f "$PRIVATE_KEY_PATH" ]]; then
    echo "Error: Private key file not found: $PRIVATE_KEY_PATH" >&2
    exit 1
fi

# Base64 URL encoding function
b64enc() { openssl base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n'; }

# Current time
now=$(date +%s)
iat=$((${now} - 60))  # Issued 60 seconds in the past
exp=$((${now} + 600))  # Expires 10 minutes in the future

# Header
header_json='{
    "typ":"JWT",
    "alg":"RS256"
}'
header=$(echo -n "${header_json}" | b64enc)

# Payload
payload_json="{
    \"iat\":${iat},
    \"exp\":${exp},
    \"iss\":\"${CLIENT_ID}\"
}"
payload=$(echo -n "${payload_json}" | b64enc)

# Signature
header_payload="${header}.${payload}"
signature=$(echo -n "${header_payload}" | openssl dgst -sha256 -sign "${PRIVATE_KEY_PATH}" | b64enc)

# Create JWT
JWT="${header_payload}.${signature}"
echo "$JWT"
