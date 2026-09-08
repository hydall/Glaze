#!/bin/bash
# Reads .env and generates Runner/Configs/Env.xcconfig
# This script is called from the Xcode Run Script phase or manually.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../../.env"
XCCONFIG="$SCRIPT_DIR/Configs/Env.xcconfig"

DROPBOX_SCHEME="db-unknown"

if [ -f "$ENV_FILE" ]; then
  APP_KEY=$(grep '^DROPBOX_APP_KEY=' "$ENV_FILE" | head -1 | cut -d'=' -f2 | tr -d '[:space:]')
  if [ -n "$APP_KEY" ]; then
    DROPBOX_SCHEME="db-$APP_KEY"
  fi
fi

echo "DROPBOX_URL_SCHEME = $DROPBOX_SCHEME" > "$XCCONFIG"
