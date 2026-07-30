#!/usr/bin/env bash
# Posts one build announcement plus its artifacts to a single Telegram chat.
#
# Used by both build workflows for the public group post and for the developer
# DMs, so the topic handling, the upload size limit and the API error reporting
# live in one place.
#
# Usage: telegram_post.sh <chat_id> [topic_id]
#
#   chat_id   numeric id or @username of the target chat.
#   topic_id  message thread id of a forum topic. Optional: a plain (non-forum)
#             chat rejects the field, so it is only sent when non-empty.
#
# Environment:
#   TG_BOT_TOKEN  bot token (required)
#   TEXT          announcement text, HTML parse mode (required)
#   FILES_DIR     directory whose files are uploaded as replies (default: artifacts)
#   PIN           "true" to pin the announcement (default: false)
#   RUN_URL       workflow run URL, referenced when a file is too large to upload
#
# Exits non-zero when the Telegram API rejects a call. A file that exceeds the
# Bot API upload limit is not an API failure: it is announced in the chat as a
# reply pointing at the workflow run, and the script keeps going.
set -euo pipefail

CHAT_ID="${1:?chat id required}"
TOPIC_ID="${2:-}"

: "${TG_BOT_TOKEN:?TG_BOT_TOKEN is required}"
: "${TEXT:?TEXT is required}"
FILES_DIR="${FILES_DIR:-artifacts}"
PIN="${PIN:-false}"
RUN_URL="${RUN_URL:-}"

API="https://api.telegram.org/bot${TG_BOT_TOKEN}"
# The Bot API caps a sendDocument upload at 50 MB.
MAX_BYTES=$((50 * 1024 * 1024))

FAILED=0

html_escape() {
  printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

# Base payload every call shares: the chat and, in a forum, the topic to post in.
target_json() {
  jq -n --arg cid "$CHAT_ID" --arg tid "$TOPIC_ID" \
    '{chat_id: $cid}
     + (if $tid == "" then {} else {message_thread_id: ($tid | tonumber)} end)'
}

api_failed() { # $1 = method, $2 = response body
  echo "::warning::$1 to chat $CHAT_ID failed: $(jq -r '.description // "unknown error"' <<<"$2")"
}

# $1 = HTML text, $2 = optional message id to reply to. Prints the new message id.
send_message() {
  local payload response
  payload=$(target_json | jq --arg text "$1" --arg reply "${2:-}" \
    '. + {text: $text, parse_mode: "HTML"}
       + (if $reply == "" then {} else {reply_to_message_id: ($reply | tonumber)} end)')

  response=$(curl -sS -X POST "$API/sendMessage" \
    -H 'Content-Type: application/json' -d "$payload")

  if [ "$(jq -r '.ok' <<<"$response")" != "true" ]; then
    api_failed sendMessage "$response"
    return 1
  fi
  jq -r '.result.message_id' <<<"$response"
}

# ── announcement ───────────────────────────────────────────────────────────────
if ! MSG_ID=$(send_message "$TEXT"); then
  echo "::error::Could not post the build announcement to chat $CHAT_ID."
  exit 1
fi
echo "Announcement posted to chat $CHAT_ID${TOPIC_ID:+ (topic $TOPIC_ID)} as message $MSG_ID."

# A pin needs can_pin_messages, which the bot only has in a group it administers.
# Losing the pin must not fail the build, so this one is a warning.
if [ "$PIN" = "true" ]; then
  PIN_RESPONSE=$(curl -sS -X POST "$API/pinChatMessage" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg cid "$CHAT_ID" --arg mid "$MSG_ID" \
      '{chat_id: $cid, message_id: ($mid | tonumber), disable_notification: true}')")
  if [ "$(jq -r '.ok' <<<"$PIN_RESPONSE")" != "true" ]; then
    api_failed pinChatMessage "$PIN_RESPONSE"
  fi
fi

# ── artifacts ──────────────────────────────────────────────────────────────────
shopt -s nullglob
FILES=("$FILES_DIR"/*)

if [ ${#FILES[@]} -eq 0 ]; then
  echo "::warning::No files found in $FILES_DIR — only the announcement was posted."
fi

for FILE in "${FILES[@]}"; do
  [ -f "$FILE" ] || continue
  NAME=$(basename "$FILE")
  SIZE=$(stat -c%s "$FILE")

  if [ "$SIZE" -gt "$MAX_BYTES" ]; then
    MB=$((SIZE / 1024 / 1024))
    echo "::warning::$NAME is ${MB} MB, over the 50 MB Telegram upload limit — posting a link instead."
    NOTE="⚠️ $(html_escape "$NAME") — ${MB} МБ, больше лимита Telegram (50 МБ)."
    if [ -n "$RUN_URL" ]; then
      NOTE="$NOTE"$'\n'"Скачать: $(html_escape "$RUN_URL")"
    fi
    send_message "$NOTE" "$MSG_ID" >/dev/null || FAILED=1
    continue
  fi

  ARGS=(-F "chat_id=$CHAT_ID" -F "reply_to_message_id=$MSG_ID" -F "document=@$FILE")
  [ -n "$TOPIC_ID" ] && ARGS+=(-F "message_thread_id=$TOPIC_ID")

  RESPONSE=$(curl -sS -X POST "$API/sendDocument" "${ARGS[@]}")
  if [ "$(jq -r '.ok' <<<"$RESPONSE")" != "true" ]; then
    api_failed sendDocument "$RESPONSE"
    FAILED=1
  else
    echo "Uploaded $NAME ($((SIZE / 1024 / 1024)) MB)."
  fi
done

exit "$FAILED"
