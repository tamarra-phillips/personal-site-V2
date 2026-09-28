#!/usr/bin/env bash
# Create a Cloudflare R2 bucket through its S3-compatible API.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "Error: Bash 4.x or later is required. Found ${BASH_VERSION}." >&2
  exit 1
fi

DOMAIN="${DOMAIN:-}"
INDEX_FILE="${INDEX_FILE:-index.html}"
R2_BUCKET="${R2_BUCKET:-${DOMAIN//./-}}"
R2_ACCOUNT_ID="${R2_ACCOUNT_ID:-}"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-}"
CLOUDFLARE_ACCESS_POLICY_ID="${CLOUDFLARE_ACCESS_POLICY_ID:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain|-d) DOMAIN="$2"; shift 2 ;;
    --bucket|-b) R2_BUCKET="$2"; shift 2 ;;
    --account-id|-a) R2_ACCOUNT_ID="$2"; shift 2 ;;
    --api-token) CLOUDFLARE_API_TOKEN="$2"; shift 2 ;;
    --zone-id) CLOUDFLARE_ZONE_ID="$2"; shift 2 ;;
    --help|-h) echo "Usage: $0 [--domain <domain>] [--index-file <file>] [--bucket <bucket>] [--account-id <account-id>]"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$DOMAIN" ]]; then
  echo "Error: DOMAIN is required. Set DOMAIN or pass --domain <domain>." >&2
  exit 1
fi
if [[ -z "$R2_BUCKET" ]]; then R2_BUCKET="$DOMAIN"; fi
if [[ -z "$R2_ACCOUNT_ID" || -z "$CLOUDFLARE_API_TOKEN" || -z "$CLOUDFLARE_ZONE_ID" ]]; then
  echo "Error: R2_ACCOUNT_ID, CLOUDFLARE_API_TOKEN, and CLOUDFLARE_ZONE_ID are required." >&2
  exit 1
fi

if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "Error: DOMAIN must be a valid hostname." >&2
  exit 1
fi

if [[ -z "$CLOUDFLARE_ACCESS_POLICY_ID" ]]; then
  echo "Error: CLOUDFLARE_ACCESS_POLICY_ID is required." >&2
  exit 1
fi

for required_command in curl jq; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Error: $required_command is required to configure Cloudflare R2 and Access." >&2
    exit 1
  fi
done

curl_version=$(curl --version | awk 'NR == 1 { print $2 }')
jq_version=$(jq --version | sed 's/^jq-//')
curl_major=${curl_version%%.*}
jq_major=${jq_version%%.*}
jq_minor=${jq_version#*.}
jq_minor=${jq_minor%%.*}
if (( curl_major < 7 )); then
  echo "Error: curl 7.x or later is required. Found $curl_version." >&2
  exit 1
fi
if (( jq_major < 1 || (jq_major == 1 && jq_minor < 6) )); then
  echo "Error: jq 1.6.x or later is required. Found $jq_version." >&2
  exit 1
fi

cloudflare_request() {
  local response_file
  response_file=$(mktemp)
  if ! curl --fail-with-body -sS "$@" -o "$response_file"; then
    cat "$response_file" >&2
    rm -f "$response_file"
    return 1
  fi
  cat "$response_file"
  rm -f "$response_file"
}

cloudflare_status() {
  local response_file status
  response_file=$(mktemp)
  if ! status=$(curl -sS -o "$response_file" -w '%{http_code}' "$@"); then
    cat "$response_file" >&2
    rm -f "$response_file"
    printf '%s\n' '000'
    return 0
  fi
  if (( status >= 400 )); then
    cat "$response_file" >&2
  fi
  rm -f "$response_file"
  printf '%s\n' "$status"
}

BUCKET_ENDPOINT="https://api.cloudflare.com/client/v4/accounts/${R2_ACCOUNT_ID}/r2/buckets/${R2_BUCKET}"
BUCKET_COLLECTION="https://api.cloudflare.com/client/v4/accounts/${R2_ACCOUNT_ID}/r2/buckets"
CUSTOM_DOMAIN_ENDPOINT="https://api.cloudflare.com/client/v4/accounts/${R2_ACCOUNT_ID}/r2/buckets/${R2_BUCKET}/domains/custom/${DOMAIN}"
CUSTOM_DOMAIN_COLLECTION="https://api.cloudflare.com/client/v4/accounts/${R2_ACCOUNT_ID}/r2/buckets/${R2_BUCKET}/domains/custom"
TOKEN_VERIFY_ENDPOINT="https://api.cloudflare.com/client/v4/accounts/${R2_ACCOUNT_ID}/tokens/verify"
ACCESS_APPS_ENDPOINT="https://api.cloudflare.com/client/v4/accounts/${R2_ACCOUNT_ID}/access/apps"
TRANSFORM_RULES_COLLECTION_ENDPOINT="https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/rulesets"
TRANSFORM_RULES_ENDPOINT="https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/rulesets/phases/http_request_transform/entrypoint"

echo "==> Verifying Cloudflare API token..."
token_status=$(cloudflare_status \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "$TOKEN_VERIFY_ENDPOINT")
if [[ "$token_status" != "200" ]]; then
  echo "Error: Cloudflare API token verification failed with HTTP $token_status." >&2
  exit 1
fi
echo "  Cloudflare API token is active."

echo "==> Configuring R2 bucket: $R2_BUCKET..."
bucket_status=$(cloudflare_status \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "$BUCKET_ENDPOINT")
if [[ "$bucket_status" == "200" ]]; then
  echo "  Bucket '$R2_BUCKET' already exists."
elif [[ "$bucket_status" == "404" ]]; then
  echo "  Creating bucket '$R2_BUCKET'..."
  cloudflare_request -X POST \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"name\":\"$R2_BUCKET\"}" \
    "$BUCKET_COLLECTION" >/dev/null
else
  echo "Error: Cloudflare API token cannot access the R2 bucket (HTTP $bucket_status)." >&2
  exit 1
fi

echo "==> Configuring public custom domain: $DOMAIN..."
domain_status=$(cloudflare_status \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "$CUSTOM_DOMAIN_ENDPOINT")

if [[ "$domain_status" == "200" ]]; then
  cloudflare_request -X PUT \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data '{"enabled":true}' \
    "$CUSTOM_DOMAIN_ENDPOINT" >/dev/null
  echo "  Custom domain already exists; public access enabled."
elif [[ "$domain_status" == "404" ]]; then
  cloudflare_request -X POST \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"domain\":\"$DOMAIN\",\"enabled\":true,\"zoneId\":\"$CLOUDFLARE_ZONE_ID\"}" \
    "$CUSTOM_DOMAIN_COLLECTION" >/dev/null
  echo "  Custom domain attached and public access enabled."
else
  if [[ "$domain_status" == "401" || "$domain_status" == "403" ]]; then
    echo "Error: Cloudflare API token lacks permission to manage R2 custom domains (HTTP $domain_status)." >&2
  else
    echo "Error: Cloudflare custom-domain lookup failed with HTTP $domain_status." >&2
  fi
  exit 1
fi

echo "==> Configuring root URL rewrite for $DOMAIN..."
rewrite_expression="(http.host eq \"$DOMAIN\" and http.request.uri.path eq \"/\")"
index_path="/$INDEX_FILE"
rewrite_rule=$(jq -n \
  --arg expression "$rewrite_expression" \
  --arg index_path "$index_path" \
  --arg index_file "$INDEX_FILE" \
  '{action: "rewrite", action_parameters: {uri: {path: {value: $index_path}}}, expression: $expression, description: ("Serve " + $index_file + " at the domain root"), enabled: true}')
ruleset_response_file=$(mktemp)
ruleset_status=$(curl -sS -o "$ruleset_response_file" -w '%{http_code}' \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "$TRANSFORM_RULES_ENDPOINT")
if (( ruleset_status >= 400 )); then
  cat "$ruleset_response_file" >&2
fi

if [[ "$ruleset_status" == "200" ]]; then
  current_rules=$(jq '.result.rules // []' "$ruleset_response_file")
  rewrite_payload=$(jq -n \
    --argjson rules "$current_rules" \
    --argjson rewrite_rule "$rewrite_rule" \
    --arg expression "$rewrite_expression" \
    '{rules: (if any($rules[]; .expression == $expression) then $rules | map(if .expression == $expression then $rewrite_rule else . end) else $rules + [$rewrite_rule] end)}')
  cloudflare_request -X PUT \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$rewrite_payload" \
    "$TRANSFORM_RULES_ENDPOINT" >/dev/null
  echo "  Root URL rewrite configured for '$INDEX_FILE'."
elif [[ "$ruleset_status" == "400" || "$ruleset_status" == "404" ]] \
  && jq -e 'any(.errors[]?; .code == 10003)' "$ruleset_response_file" >/dev/null; then
  rewrite_payload=$(jq -n \
    --argjson rewrite_rule "$rewrite_rule" \
    '{name: "Orchestra Scheduler root rewrite", description: "Serve the index file at the domain root", kind: "zone", phase: "http_request_transform", rules: [$rewrite_rule]}')
  cloudflare_request -X POST \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$rewrite_payload" \
    "$TRANSFORM_RULES_COLLECTION_ENDPOINT" >/dev/null
  echo "  Root URL rewrite created."
else
  cat "$ruleset_response_file" >&2
  rm -f "$ruleset_response_file"
  echo "Error: Cloudflare transform-rule lookup failed with HTTP $ruleset_status." >&2
  exit 1
fi
rm -f "$ruleset_response_file"

echo "==> Configuring Cloudflare Access application for $DOMAIN..."
access_apps=$(cloudflare_request \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "$ACCESS_APPS_ENDPOINT")
access_app_id=$(printf '%s' "$access_apps" | jq -r --arg domain "$DOMAIN" \
  '.result[] | select(.domain == $domain) | .id' | head -n 1)

if [[ -n "$access_app_id" ]]; then
  echo "  Access application already exists; applying reusable policy '$CLOUDFLARE_ACCESS_POLICY_ID'."
  access_policy_payload=$(jq -n \
    --arg domain "$DOMAIN" \
    --arg policy_id "$CLOUDFLARE_ACCESS_POLICY_ID" \
    '{name: $domain, domain: $domain, type: "self_hosted", session_duration: "24h", auto_redirect_to_identity: false, policies: [$policy_id]}')
  cloudflare_request -X PUT \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$access_policy_payload" \
    "${ACCESS_APPS_ENDPOINT}/${access_app_id}" >/dev/null
else
  access_payload=$(jq -n \
    --arg domain "$DOMAIN" \
    --arg policy_id "$CLOUDFLARE_ACCESS_POLICY_ID" \
    '{name: $domain, domain: $domain, type: "self_hosted", session_duration: "24h", auto_redirect_to_identity: false, policies: [$policy_id]}')
  if ! cloudflare_request -X POST \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$access_payload" \
    "$ACCESS_APPS_ENDPOINT" >/dev/null; then
    exit 1
  fi
  echo "  Access application created with reusable policy '$CLOUDFLARE_ACCESS_POLICY_ID'."
fi

echo "  R2 bucket and custom domain setup complete."