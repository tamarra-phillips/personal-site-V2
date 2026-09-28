#!/usr/bin/env bash
# Deploy static site to Cloudflare R2.
set -euo pipefail

DOMAIN="${DOMAIN:-}"
R2_BUCKET="${R2_BUCKET:-${DOMAIN//./-}}"
R2_ACCOUNT_ID="${R2_ACCOUNT_ID:-}"
CLOUDFLARE_R2_ACCESS_KEY_ID="${CLOUDFLARE_R2_ACCESS_KEY_ID:-}"
CLOUDFLARE_R2_SECRET_ACCESS_KEY="${CLOUDFLARE_R2_SECRET_ACCESS_KEY:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain|-d) DOMAIN="$2"; shift 2 ;;
    --bucket|-b) R2_BUCKET="$2"; shift 2 ;;
    --account-id|-a) R2_ACCOUNT_ID="$2"; shift 2 ;;
    --help|-h) echo "Usage: $0 [--domain <domain>] [--bucket <bucket>] [--account-id <account-id>]"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$DOMAIN" ]]; then
  echo "Error: DOMAIN is required. Set DOMAIN or pass --domain <domain>." >&2
  exit 1
fi

if [[ -z "$R2_BUCKET" ]]; then
  R2_BUCKET="${DOMAIN//./-}"
fi

if [[ -z "$R2_ACCOUNT_ID" ]]; then
  echo "Error: R2_ACCOUNT_ID is required. Set it or pass --account-id <account-id>." >&2
  exit 1
fi
if [[ -z "$CLOUDFLARE_R2_ACCESS_KEY_ID" || -z "$CLOUDFLARE_R2_SECRET_ACCESS_KEY" ]]; then
  echo "Error: Cloudflare R2 access-key environment variables are required." >&2
  exit 1
fi

R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

echo "==> Uploading dist/ to Cloudflare R2 bucket '$R2_BUCKET'..."
if [[ ! -f "dist/index.html" ]]; then
  echo "Error: dist/index.html not found. Run 'task build' first." >&2
  exit 1
fi

env \
  AWS_ACCESS_KEY_ID="$CLOUDFLARE_R2_ACCESS_KEY_ID" \
  AWS_SECRET_ACCESS_KEY="$CLOUDFLARE_R2_SECRET_ACCESS_KEY" \
  aws s3 sync dist/ "s3://$R2_BUCKET/" \
  --delete \
  --region auto \
  --endpoint-url "$R2_ENDPOINT" \
  --cache-control "public, max-age=300"

echo "==> Deployment complete!"
echo "  Cloudflare R2 custom domain '$DOMAIN' is configured to serve the bucket."