#!/usr/bin/env bash
# Re-captures the hope-tv conformance fixtures from staging (TV App Contract
# integration, Phase 3). Bodies are published content; the ClientToken is a
# request header only and is never written here.
#
# Every body lands in a temporary directory first and is redacted there. Only a
# clean, redacted set is moved into this folder, so a failed request or a crash
# in the middle can never leave raw credentials in the tracked path.
#
# Usage: CLIENT_TOKEN=<any enabled staging ClientToken> ./capture.sh
set -euo pipefail
: "${CLIENT_TOKEN:?}"
BASE="https://frontend-staging-api.hopeplatform.org/v1/app/hope-tv"
ENTITY="602bd46f36432128d40d5e81"
DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --fail turns an error status into a non-zero exit, so `set -e` stops the run
# before an HTML error page is ever redacted and moved in.
req() {
  curl -sS --fail -o "$WORK/$2" -w "%{http_code} $1\n" \
    -H "ClientToken: $CLIENT_TOKEN" -H "X-AWE-App-Contract: 1" -H "X-AWE-Entity: $ENTITY" \
    "$BASE$1"
}
req "/manifest?lang=en" manifest.json
req "/screens/6aa952fbc445860ea24e1bc1?lang=en" home.json
req "/screens/6aa952fcc445860ea24e1bcc?lang=en" browse.json
req "/screens/6aa952fcc445860ea24e1bd7?lang=en" live.json
req "/screens/6aa952fbc445860ea24e1bb6?lang=en&param=61975e24d9c698836400305c" show.json
# Episode Template Screen (awe#4950). The param is a Jetstream episode on the Home
# `latest` shelf, so the capture carries a source tvOS can play natively.
req "/screens/6ab3c22ade87f6e74b7dc8f7?lang=en&param=629ecd4ce1e081635d11107e" episode.json

# Redact deny-by-default: the string value of ANY key that reads like a credential
# goes, not only the ones seen so far. The `channel` resource serves Vimeo
# credentials today (Frontend API `resources/channel.js` uses an exclusion
# projection — awe#4663), and the next resource to leak one must not need a script
# change to stay out of git.
node "$DIR/redact.mjs" "$WORK"

mv "$WORK"/manifest.json "$WORK"/home.json "$WORK"/browse.json "$WORK"/live.json "$WORK"/show.json "$WORK"/episode.json "$DIR/"
