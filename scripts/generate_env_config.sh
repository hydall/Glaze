#!/bin/bash
# Generates platform-specific config from .env
# Run before: flutter build ios / flutter build apk
#
# Android: reads .env at Gradle time (no manual step needed)
# iOS: generates ios/Runner/Configs/Env.xcconfig

set -e

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"

# --- iOS ---
IOS_CONFIG_DIR="$ROOT_DIR/ios/Runner/Configs"
mkdir -p "$IOS_CONFIG_DIR"

DROPBOX_SCHEME="db-unknown"
if [ -f "$ENV_FILE" ]; then
  APP_KEY=$(grep '^DROPBOX_APP_KEY=' "$ENV_FILE" | head -1 | cut -d'=' -f2 | tr -d '[:space:]')
  if [ -n "$APP_KEY" ]; then
    DROPBOX_SCHEME="db-$APP_KEY"
  fi
fi

echo "DROPBOX_URL_SCHEME = $DROPBOX_SCHEME" > "$IOS_CONFIG_DIR/Env.xcconfig"
echo "Generated ios/Runner/Configs/Env.xcconfig (DROPBOX_URL_SCHEME=$DROPBOX_SCHEME)"
