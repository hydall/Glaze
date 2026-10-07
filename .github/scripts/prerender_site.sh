#!/usr/bin/env bash
# Makes the Russian page and bakes both pages' rendered markup before a Pages
# deploy.
#
# The site is drawn by app.js from data.js, so the shipped index.html has an
# empty <main>: a crawler that does not run JavaScript (and the first, HTML-only
# pass of one that does) sees no text and nothing to index. This opens each page
# in headless Chrome, takes the DOM once app.js has drawn it, and writes it back
# over the page's index.html. In the browser app.js still boots as before and
# redraws every section with innerHTML, so the baked markup is only what is seen
# before that.
#
# Each language has its own URL, so search engines can index both: English at
# the root, Russian at ru/. ru/index.html is not kept in the repo; it is made
# here from index.html, with its language and paths pointing one level up.
# app.js fills in the translated title and description, and the prerender bakes
# them into the head.
#
# Usage: prerender_site.sh [site_dir]
#
#   site_dir  directory with index.html (default: site)
#
# Environment:
#   CHROME  Chrome or Chromium binary (default: google-chrome)
#   PORT    port of the throwaway local server (default: 8765)

set -euo pipefail

site_dir="${1:-site}"
chrome="${CHROME:-google-chrome}"
port="${PORT:-8765}"
url="https://hydall.github.io/Glaze/"

mkdir -p "$site_dir/ru"
sed \
  -e 's|<html lang="en">|<html lang="ru" data-lang="ru" data-root="../">|' \
  -e 's#\(href\|src\)="assets/#\1="../assets/#g' \
  -e "s|<link rel=\"canonical\" href=\"$url\">|<link rel=\"canonical\" href=\"${url}ru/\">|" \
  -e "s|<meta property=\"og:url\" content=\"$url\">|<meta property=\"og:url\" content=\"${url}ru/\">|" \
  -e 's|<meta property="og:locale" content="en_US">|<meta property="og:locale" content="ru_RU">|' \
  -e 's|<meta property="og:locale:alternate" content="ru_RU">|<meta property="og:locale:alternate" content="en_US">|' \
  "$site_dir/index.html" > "$site_dir/ru/index.html"

grep -q 'data-lang="ru"' "$site_dir/ru/index.html" || {
  echo "prerender_site: could not make ru/index.html, the <html> tag has changed" >&2
  exit 1
}

python3 -m http.server "$port" --bind 127.0.0.1 --directory "$site_dir" >/dev/null 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT

for _ in $(seq 50); do
  curl -sf -o /dev/null "http://127.0.0.1:$port/" && break
  sleep 0.1
done

# prerender <page> <lang>
#   page  path of the page under the site, "" for the root or "ru/"
#   lang  language the page must come out in
prerender() {
  local page="$1" file="$site_dir/${1}index.html" dom
  # An English locale, so the root page does not send Chrome on to ru/.
  dom="$("$chrome" --headless=new --disable-gpu --no-sandbox --no-first-run \
    --lang=en-US --virtual-time-budget=15000 \
    --dump-dom "http://127.0.0.1:$port/$page")"

  # A broken app.js would otherwise ship an empty page without anyone noticing.
  if ! grep -q '<h1>Glaze</h1>' <<<"$dom" || ! grep -q "<html lang=\"$2\"" <<<"$dom"; then
    echo "prerender_site: /$page did not render" >&2
    exit 1
  fi

  grep -qi '^<!doctype' <<<"$dom" || dom="<!doctype html>"$'\n'"$dom"
  printf '%s\n' "$dom" > "$file"
  echo "prerender_site: wrote $file ($(wc -c < "$file") bytes)"
}

prerender "" en
prerender "ru/" ru
