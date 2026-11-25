#!/usr/bin/env bash
# Posts a release to the Telegram channel and the Discord channel:
#
#   **Glaze** `26.11.1`
#
#   СКАЧАТЬ                     (link: the site's download page)
#
#   СТАТЬЯ С ОПИСАНИЕМ РЕЛИЗА   (link: the release article, whose card shows)
#
#   Релиз был сделан автоматически на основе ветки main с GitHub
#   (за исключением изменений за последние 24 часа)        — only when AUTO=true
#
# Used by .github/workflows/release-article.yml once the article is deployed.
#
# Environment:
#   VERSION          release version, e.g. 26.11.1 (required)
#   AUTO             "true" for a release made by auto-release.yml
#   TG_BOT_TOKEN     Telegram bot token
#   TG_CHAT          Telegram channel: @username or numeric -100… id
#   TG_TOPIC         message thread id, only for a forum group
#   DISCORD_WEBHOOK  Discord channel webhook URL
#   SITE_URL         default https://hydall.github.io/Glaze
#
# A target with no credentials is skipped with a warning; a target that rejects
# the post fails the script, after the other one has been tried.
set -euo pipefail

: "${VERSION:?VERSION is required}"
SITE_URL="${SITE_URL:-https://hydall.github.io/Glaze}"
# The root page sends Russian readers on to ru/, keeping the #anchor.
DOWNLOAD_URL="$SITE_URL/#download"
# The article's static page: it carries the preview card (title, cover).
ARTICLE_URL="$SITE_URL/articles/$VERSION/"
AUTO_LINE="Релиз был сделан автоматически на основе ветки main с GitHub (за исключением изменений за последние 24 часа)"

failed=0

# ── Telegram ─────────────────────────────────────────────────────────────────
if [ -z "${TG_BOT_TOKEN:-}" ] || [ -z "${TG_CHAT:-}" ]; then
  echo "::warning::TG_BOT_TOKEN / TG_RELEASE_CHAT_ID are not set, Telegram skipped."
else
  text="<b>Glaze</b> <code>$VERSION</code>"$'\n\n'"<a href=\"$DOWNLOAD_URL\">СКАЧАТЬ</a>"$'\n\n'"<a href=\"$ARTICLE_URL\">СТАТЬЯ С ОПИСАНИЕМ РЕЛИЗА</a>"
  [ "${AUTO:-false}" = "true" ] && text="$text"$'\n\n'"$AUTO_LINE"
  payload=$(jq -n --arg cid "$TG_CHAT" --arg tid "${TG_TOPIC:-}" --arg text "$text" --arg url "$ARTICLE_URL" \
    '{chat_id: $cid, text: $text, parse_mode: "HTML",
      link_preview_options: {url: $url, prefer_large_media: true}}
     + (if $tid == "" then {} else {message_thread_id: ($tid | tonumber)} end)')
  res=$(curl -sS -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -H 'Content-Type: application/json' -d "$payload")
  if [ "$(jq -r '.ok' <<<"$res")" = "true" ]; then
    echo "Posted to Telegram."
  else
    echo "::error::Telegram: $(jq -r '.description // "unknown error"' <<<"$res")"
    failed=1
  fi
fi

# ── Discord ──────────────────────────────────────────────────────────────────
if [ -z "${DISCORD_WEBHOOK:-}" ]; then
  echo "::warning::DISCORD_RELEASE_WEBHOOK is not set, Discord skipped."
else
  # <…> keeps the download link from drawing a card of its own: only the
  # article's card shows.
  content="**Glaze** \`$VERSION\`"$'\n\n'"[СКАЧАТЬ](<$DOWNLOAD_URL>)"$'\n\n'"[СТАТЬЯ С ОПИСАНИЕМ РЕЛИЗА]($ARTICLE_URL)"
  [ "${AUTO:-false}" = "true" ] && content="$content"$'\n\n'"$AUTO_LINE"
  payload=$(jq -n --arg c "$content" '{content: $c, username: "Glaze", allowed_mentions: {parse: []}}')
  out=$(mktemp)
  code=$(curl -sS -o "$out" -w '%{http_code}' -X POST "$DISCORD_WEBHOOK?wait=true" \
    -H 'Content-Type: application/json' -d "$payload")
  if [ "${code:0:1}" = "2" ]; then
    echo "Posted to Discord."
  else
    echo "::error::Discord answered $code: $(cat "$out")"
    failed=1
  fi
fi

exit "$failed"
