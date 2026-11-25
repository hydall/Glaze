#!/usr/bin/env python3
"""Writes the site's changelog article for a published release.

Run by .github/workflows/release-article.yml after a release from `main`. It

1. collects the PRs that went into the release (git log between the previous
   release tag and this one, plus each PR's description from GitHub),
2. asks an OpenAI-compatible model (DeepSeek, as the bug-triage bot) for the
   article in Russian and English, in the style of the previous one,
3. writes site/articles/<version>.{ru,en}.md, the link-preview page
   site/articles/<version>/index.html and its cover og.png,
4. adds the article and the roadmap entry to site/assets/data.js and points the
   download fallback at the new release,
5. writes the announcement texts to --announce-out for the posting step.

Standard library only, so the workflow needs no pip install. Nothing is written
unless the model's answer passes validation.

Usage:
  release_article.py --version 26.11.1 --tag v26.11.1 --prev-tag v0.10.0 \
      --date 2026-11-25 --assets assets.json --announce-out announce.json

Environment:
  DEEPSEEK_API_KEY   required unless --llm-response is given
  DEEPSEEK_BASE_URL  default https://api.deepseek.com
  DEEPSEEK_MODEL     default deepseek-chat
  CHROME             Chrome/Chromium binary for the cover (default google-chrome)
  GH_TOKEN           for `gh pr view` (PR descriptions); without it only the
                     commit subjects are used
"""

from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

SITE_URL = "https://hydall.github.io/Glaze"
SCRIPTS = Path(__file__).resolve().parent

# Commits that never carry anything for users. Everything else goes to the
# model, which drops what users cannot notice: a `ci:` or `refactor:` PR can
# still bring a visible change (its description says so).
SKIP_SUBJECT = re.compile(
    r"^(docs|chore|test|tests|style)(\([^)]*\))?!?:"
    r"|^[a-z]+\((site|ci)\)"
    r"|^Merge ",
    re.IGNORECASE,
)
PR_NUMBER = re.compile(r"\(#(\d+)\)")
PR_BODY_CAP = 1500


# ── changes ──────────────────────────────────────────────────────────────────

def collect_changes(prev_tag: str | None, tag: str) -> list[dict]:
    rng = f"{prev_tag}..{tag}" if prev_tag else tag
    log = subprocess.run(
        ["git", "log", "--no-merges", "--format=%s", rng],
        check=True, capture_output=True, text=True,
    ).stdout.splitlines()
    changes, seen = [], set()
    for subject in log:
        subject = subject.strip()
        if not subject or SKIP_SUBJECT.search(subject) or subject in seen:
            continue
        seen.add(subject)
        entry = {"title": subject}
        numbers = PR_NUMBER.findall(subject)
        if numbers:
            body = pr_body(numbers[-1])
            if body:
                entry["description"] = body
        changes.append(entry)
    return changes


def pr_body(number: str) -> str:
    if not os.environ.get("GH_TOKEN"):
        return ""
    res = subprocess.run(
        ["gh", "pr", "view", number, "--json", "body", "--jq", ".body"],
        capture_output=True, text=True,
    )
    if res.returncode != 0:
        return ""
    body = res.stdout.strip()
    # The PR template's verification section and footers say nothing to users.
    body = re.split(r"\n#+\s*(verification|how it was verified|testing)\b", body, flags=re.I)[0]
    body = re.sub(r"🤖 Generated with.*", "", body, flags=re.S).strip()
    return body[:PR_BODY_CAP]


# ── model ────────────────────────────────────────────────────────────────────

SYSTEM_PROMPT = """You write the release notes for Glaze, a native app for AI roleplay \
chats (characters, presets, lorebooks, themes, plugins). You get the list of pull \
requests that went into a release and the previous article as a style reference.

Answer with one JSON object, nothing else:
{
  "lead": {"ru": "...", "en": "..."},
  "roadmap_title": {"ru": "...", "en": "..."},
  "new": {"ru": ["..."], "en": ["..."]},
  "fixes": {"ru": ["..."], "en": ["..."]},
  "body": {"ru": "...", "en": "..."}
}

- lead: one sentence, the 2-4 most important things in this release, the way the \
reference article's lead reads. No version number.
- roadmap_title: 2-4 words naming the release's main themes, like "Summary, themes \
and Windows".
- new / fixes: short roadmap lines, 3-9 for new, 0-6 for fixes, Sentence case, no \
trailing period. Group small things into one line.
- body: the full article in Markdown, exactly in the reference's style: `## section` \
headings in lower case (chat, themes, plugins, fixes, ...), `- ` bullets, lower-case \
bullet starts, **bold** for the key feature in a bullet, `code` for settings and \
identifiers. No top-level `#` heading, no intro paragraph, no version number, no PR \
numbers, no links.
- Write for users: what they can now do or what no longer breaks. Leave out internal \
refactors, CI, tests, logging-only changes and anything a user cannot notice.
- Russian is the primary text; English says the same thing. Natural language, no \
marketing words ("revolutionary", "seamless", "exciting").
- Only describe what the pull requests say. Never invent features."""


def ask_model(changes: list[dict], reference: dict[str, str]) -> dict:
    key = os.environ.get("DEEPSEEK_API_KEY", "").strip()
    if not key:
        sys.exit("release_article: DEEPSEEK_API_KEY is not set")
    base = (os.environ.get("DEEPSEEK_BASE_URL") or "https://api.deepseek.com").rstrip("/")
    model = os.environ.get("DEEPSEEK_MODEL") or "deepseek-chat"

    user = (
        "Reference article (Russian):\n\n" + reference.get("ru", "(none)")
        + "\n\nReference article (English):\n\n" + reference.get("en", "(none)")
        + "\n\nPull requests in this release:\n\n"
        + json.dumps(changes, ensure_ascii=False, indent=1)
    )
    payload = json.dumps({
        "model": model,
        "temperature": 0.4,
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user},
        ],
    }).encode()

    last_error = ""
    for attempt in range(3):
        req = urllib.request.Request(
            f"{base}/chat/completions", data=payload, method="POST",
            headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=600) as res:
                data = json.load(res)
            answer = json.loads(data["choices"][0]["message"]["content"])
            return validate(answer)
        except (urllib.error.URLError, KeyError, ValueError, TimeoutError) as e:
            last_error = str(e)
            print(f"release_article: attempt {attempt + 1} failed: {e}", file=sys.stderr)
            time.sleep(10 * (attempt + 1))
    sys.exit(f"release_article: the model gave no usable answer ({last_error})")


def validate(a: dict) -> dict:
    def text(path: str, v, cap: int) -> str:
        if not isinstance(v, str) or not v.strip():
            raise ValueError(f"{path} is empty")
        v = v.strip()
        if len(v) > cap:
            raise ValueError(f"{path} is longer than {cap} characters")
        return v

    def lines(path: str, v, lo: int, hi: int) -> list[str]:
        if not isinstance(v, list) or not lo <= len(v) <= hi:
            raise ValueError(f"{path} must have {lo}-{hi} lines")
        return [text(f"{path}[{i}]", x, 200).rstrip(".") for i, x in enumerate(v)]

    out: dict = {}
    for lang in ("ru", "en"):
        out.setdefault("lead", {})[lang] = text(f"lead.{lang}", a["lead"][lang], 300)
        out.setdefault("roadmap_title", {})[lang] = text(
            f"roadmap_title.{lang}", a["roadmap_title"][lang], 60)
        out.setdefault("new", {})[lang] = lines(f"new.{lang}", a["new"][lang], 1, 12)
        out.setdefault("fixes", {})[lang] = lines(f"fixes.{lang}", a.get("fixes", {}).get(lang, []), 0, 10)
        body = text(f"body.{lang}", a["body"][lang], 20000)
        if not body.startswith("## ") or re.search(r"^# ", body, re.M):
            raise ValueError(f"body.{lang} must start with a `## ` section and have no `# ` heading")
        out.setdefault("body", {})[lang] = body + "\n"
    return out


# ── site files ───────────────────────────────────────────────────────────────

def js(s: str) -> str:
    """A single-quoted JS string literal, the way data.js writes them."""
    s = s.replace("\\", "\\\\").replace("'", "\\'").replace("\n", " ")
    return f"'{s}'"


def js_list(items: list[str], indent: str) -> str:
    return "[\n" + "".join(f"{indent}  {js(x)},\n" for x in items) + f"{indent}]"


def update_data_js(path: Path, version: str, tag: str, date: str, author: str,
                   article: dict, assets: list[dict]) -> None:
    src = path.read_text(encoding="utf-8")
    if re.search(rf"slug: '{re.escape(version)}'", src):
        sys.exit(f"release_article: data.js already has the {version} article")

    def sub(pattern: str, repl, flags=0) -> None:
        nonlocal src
        src, n = re.subn(pattern, repl, src, count=1, flags=flags)
        if n != 1:
            sys.exit(f"release_article: data.js no longer matches /{pattern}/")

    # Download fallback: shown when the GitHub API cannot be reached.
    asset_lines = "".join(
        f"      {{ name: {js(a['name'])}, size: {int(a['size'])} }},\n"
        for a in assets if not a["name"].endswith(".sha256")
    )
    sub(r"  fallbackRelease: \{\n.*?\n  \},\n",
        lambda _: (f"  fallbackRelease: {{\n    tag: {js(tag)},\n    date: {js(date)},\n"
                   f"    assets: [\n{asset_lines}    ],\n  }},\n"),
        re.S)
    sub(r"devVersion: '[^']*'", lambda _: f"devVersion: {js(version)}")
    sub(r"(dl_api_failed: 'Не удалось связаться с GitHub\. Показаны ссылки на )v[^']*?(\.')",
        lambda m: f"{m.group(1)}{tag}{m.group(2)}")
    sub(r"(dl_api_failed: 'Could not reach GitHub\. Showing links for )v[^']*?(\.')",
        lambda m: f"{m.group(1)}{tag}{m.group(2)}")

    title = f"Glaze {version}"
    entry = (
        "    {\n"
        f"      slug: {js(version)},\n"
        "      kind: 'changelog',\n"
        f"      date: {js(date)},\n"
        f"      author: {js(author)},\n"
        "      langs: ['ru', 'en'],\n"
        f"      download: {js(tag)},\n"
        f"      title: {{ ru: {js(title)}, en: {js(title)} }},\n"
        "      lead: {\n"
        f"        ru: {js(article['lead']['ru'])},\n"
        f"        en: {js(article['lead']['en'])},\n"
        "      },\n"
        "    },\n"
    )
    sub(r"  articles: \[\n", lambda m: m.group(0) + entry)

    # Roadmap: the previous `latest` becomes `released`, the new one goes in
    # front of it (right after the `planned` entry, the list is newest first).
    sub(r"status: 'latest'", lambda _: "status: 'released'")
    groups = [("Новое", "New", article["new"])]
    if article["fixes"]["ru"] and article["fixes"]["en"]:
        groups.append(("Исправления", "Fixes", article["fixes"]))
    group_src = "".join(
        "        {\n"
        f"          title: {{ ru: {js(ru)}, en: {js(en)} }},\n"
        "          items: {\n"
        f"            ru: {js_list(items['ru'], '            ')},\n"
        f"            en: {js_list(items['en'], '            ')},\n"
        "          },\n"
        "        },\n"
        for ru, en, items in groups
    )
    release = (
        "    {\n"
        f"      version: {js(version)},\n"
        f"      date: {js(date)},\n"
        "      status: 'latest',\n"
        f"      tag: {js(tag)},\n"
        f"      article: {js(version)},\n"
        f"      title: {{ ru: {js(article['roadmap_title']['ru'])}, en: {js(article['roadmap_title']['en'])} }},\n"
        f"      groups: [\n{group_src}      ],\n"
        "    },\n"
    )
    sub(r"(  releases: \[\n.*?\n)(    \{\n      version: ')",
        lambda m: m.group(1) + release + m.group(2), re.S)

    path.write_text(src, encoding="utf-8")


def preview_page(version: str, date: str, author: str, lead_en: str) -> str:
    url = f"{SITE_URL}/articles/{version}/"
    title = html.escape(f"Glaze {version}")
    lead = html.escape(lead_en, quote=True)
    target = f"../../#articles/{version}"
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <!--
    Static entry for one article, so link previews (Discord, Telegram, etc.)
    get the post's own title, description and image. The app itself routes on
    the hash, which a crawler never sees, so sharing #articles/{version} would only
    ever show the site-wide card. Share this URL instead: it serves these tags
    and sends a human on to the article in the app.
    Written by .github/scripts/release_article.py.
  -->
  <title>{title} — Glaze</title>
  <meta name="description" content="{lead}">
  <link rel="canonical" href="{url}">
  <meta name="theme-color" content="#19191A">

  <meta property="og:type" content="article">
  <meta property="og:site_name" content="Glaze">
  <meta property="og:url" content="{url}">
  <meta property="og:title" content="{title}">
  <meta property="og:description" content="{lead}">
  <meta property="og:image" content="{url}og.png">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">
  <meta property="og:locale" content="en_US">
  <meta property="og:locale:alternate" content="ru_RU">
  <meta property="article:published_time" content="{date}">
  <meta property="article:author" content="{html.escape(author)}">

  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="{title}">
  <meta name="twitter:description" content="{lead}">
  <meta name="twitter:image" content="{url}og.png">

  <link rel="icon" href="../../assets/img/glaze.svg" type="image/svg+xml">
  <meta http-equiv="refresh" content="0; url={target}">
  <script>location.replace('{target}');</script>
</head>
<body>
  <p><a href="{target}">{title}</a></p>
</body>
</html>
"""


def render_cover(out_dir: Path, version: str, date: str, author: str, avatar: str,
                 lead_en: str) -> None:
    day = dt.date.fromisoformat(date)
    fields = {
        "VERSION": html.escape(version),
        "LEAD": html.escape(lead_en),
        "AUTHOR": html.escape(author),
        "AVATAR": html.escape(avatar),
        "DATE": f"{day.day} {day.strftime('%B')} {day.year}",
    }
    page = (SCRIPTS / "release_cover.html").read_text(encoding="utf-8")
    for k, v in fields.items():
        page = page.replace("{{" + k + "}}", v)
    tmp = out_dir / "cover.html"
    tmp.write_text(page, encoding="utf-8")
    try:
        subprocess.run(
            [os.environ.get("CHROME", "google-chrome"), "--headless=new", "--no-sandbox",
             "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
             "--window-size=1200,630", "--virtual-time-budget=5000",
             f"--screenshot={out_dir / 'og.png'}", tmp.resolve().as_uri()],
            check=True, capture_output=True, timeout=120,
        )
    finally:
        tmp.unlink(missing_ok=True)
    if not (out_dir / "og.png").exists():
        sys.exit("release_article: Chrome did not write the cover")


def reference_article(site: Path) -> dict[str, str]:
    """The newest changelog article, as the model's style reference."""
    data = (site / "assets" / "data.js").read_text(encoding="utf-8")
    m = re.search(r"  articles: \[.*?slug: '([^']+)',\n      kind: 'changelog'", data, re.S)
    if not m:
        return {}
    ref = {}
    for lang in ("ru", "en"):
        f = site / "articles" / f"{m.group(1)}.{lang}.md"
        if f.exists():
            ref[lang] = f.read_text(encoding="utf-8")
    return ref


def author_avatar(site: Path, author: str) -> str:
    data = (site / "assets" / "data.js").read_text(encoding="utf-8")
    m = re.search(rf"\b{re.escape(author)}: \{{[^}}]*img: '([^']+)'", data)
    return m.group(1) if m else "glaze.svg"


# ── main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--prev-tag")
    ap.add_argument("--date", default=dt.date.today().isoformat())
    ap.add_argument("--author", default="hydall")
    ap.add_argument("--site", default="site", type=Path)
    ap.add_argument("--assets", type=Path, help="JSON list of {name, size}")
    ap.add_argument("--announce-out", type=Path, required=True)
    ap.add_argument("--llm-response", type=Path, help="use this JSON instead of calling the model (tests)")
    ap.add_argument("--announce-only", action="store_true",
                    help="the article exists: only write the announcement from data.js")
    args = ap.parse_args()

    site: Path = args.site
    version = args.version
    args.prev_tag = args.prev_tag or None  # the workflow passes "" when there is none
    if args.announce_only:
        write_announcement(args.announce_out, version, existing_lead(site, version), None)
        return
    md = {lang: site / "articles" / f"{version}.{lang}.md" for lang in ("ru", "en")}
    if any(p.exists() for p in md.values()):
        sys.exit(f"release_article: the {version} article already exists")

    if args.llm_response:
        article = validate(json.loads(args.llm_response.read_text(encoding="utf-8")))
    else:
        changes = collect_changes(args.prev_tag, args.tag)
        if not changes:
            sys.exit("release_article: no user-facing changes since the previous release")
        print(f"release_article: {len(changes)} change(s) since {args.prev_tag or 'the start'}")
        article = ask_model(changes, reference_article(site))

    assets = json.loads(args.assets.read_text()) if args.assets else []

    # data.js first: it is the step most likely to refuse (layout changed,
    # article already listed), and refusing before any file is written keeps
    # the tree clean.
    update_data_js(site / "assets" / "data.js", version, args.tag, args.date,
                   args.author, article, assets)
    for lang, path in md.items():
        path.write_text(article["body"][lang], encoding="utf-8")
    page_dir = site / "articles" / version
    page_dir.mkdir(parents=True, exist_ok=True)
    (page_dir / "index.html").write_text(
        preview_page(version, args.date, args.author, article["lead"]["en"]), encoding="utf-8")
    render_cover(page_dir, version, args.date, args.author,
                 author_avatar(site, args.author), article["lead"]["en"])

    write_announcement(args.announce_out, version, article["lead"], article["new"])
    print(f"release_article: wrote the {version} article")


def write_announcement(out: Path, version: str, lead: dict, new: dict | None) -> None:
    out.write_text(json.dumps({
        "version": version,
        "url": f"{SITE_URL}/articles/{version}/",
        "lead": lead,
        "new": new or {"ru": [], "en": []},
    }, ensure_ascii=False, indent=1), encoding="utf-8")


def existing_lead(site: Path, version: str) -> dict:
    data = (site / "assets" / "data.js").read_text(encoding="utf-8")
    m = re.search(
        rf"slug: '{re.escape(version)}',.*?lead: \{{\n\s*ru: '((?:[^'\\]|\\.)*)',\n\s*en: '((?:[^'\\]|\\.)*)'",
        data, re.S)
    if not m:
        sys.exit(f"release_article: data.js has no {version} article")
    unq = lambda s: s.replace("\\'", "'").replace("\\\\", "\\")
    return {"ru": unq(m.group(1)), "en": unq(m.group(2))}


if __name__ == "__main__":
    main()
