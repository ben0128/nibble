#!/bin/bash
# Deploy site/ to Cloudflare Pages via a clean staging copy, so wrangler's
# cache (.wrangler/ — it contains the account id) can never end up in the upload.
set -euo pipefail
cd "$(dirname "$0")"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
rsync -a --exclude='.wrangler' site/ "$STAGE"/
wrangler pages deploy "$STAGE" --project-name nibble --branch main --commit-dirty=true
