"""Read-only smoke test. Verifies every credential/ID works BEFORE the real run.

Creates nothing, comments nothing. For DeepSeek it sends one tiny 1-token
request per model — the text one and the vision one — just to confirm the key
and both ids are valid; an experimental model id that has been retired shows up
here rather than halfway through a run.

It also prints what the two board passes would pick up (cards nobody audited,
cards whose verdict was blocked on a screenshot), so a dry run can be judged
before it is started.

Run:  python check_connections.py
"""

from __future__ import annotations

import sys

import requests

import audit_comment
from config import Config
from discord_client import DiscordClient
from trello_client import TrelloClient

OK = "OK  "
BAD = "FAIL"

# Cards whose comments the check reads before reporting the image backlog.
_MAX_SCANNED = 60


def _line(status: str, label: str, detail: str = "") -> None:
    print(f"[{status}] {label}" + (f" — {detail}" if detail else ""))


def check_discord(cfg: Config) -> bool:
    h = {"Authorization": f"Bot {cfg.discord_bot_token}"}
    try:
        me = requests.get(
            "https://discord.com/api/v10/users/@me", headers=h, timeout=20
        )
        me.raise_for_status()
        _line(OK, "Discord token", f"bot = {me.json().get('username')}")

        ch = requests.get(
            f"https://discord.com/api/v10/channels/{cfg.discord_forum_channel_id}",
            headers=h, timeout=20,
        )
        ch.raise_for_status()
        c = ch.json()
        kind = "forum" if c.get("type") == 15 else f"type={c.get('type')} (NOT a forum?)"
        _line(OK, "Discord forum channel", f"{c.get('name')} [{kind}]")

        dc = DiscordClient(
            cfg.discord_bot_token,
            cfg.discord_guild_id,
            cfg.discord_forum_channel_id,
            ignored_tag_ids=cfg.discord_ignored_tag_ids,
            skip_archived=cfg.discord_skip_archived,
        )

        tags = dc.available_tags()
        if tags:
            listed = ", ".join(f"{t.get('name')}={t.get('id')}" for t in tags)
            _line(OK, "Discord forum tags", listed)
            _line(OK, "Ignored tag ids",
                  ", ".join(cfg.discord_ignored_tag_ids) or
                  "(none set — put closed/solved tag ids in DISCORD_IGNORED_TAG_IDS)")
        else:
            _line(OK, "Discord forum tags", "none configured on the channel")

        threads = dc._threads()
        closed = sum(1 for t in threads if dc.is_closed(t)[0])
        _line(OK, "Discord closed filter",
              f"{closed} of {len(threads)} thread(s) treated as closed "
              f"(skip_archived={cfg.discord_skip_archived})")

        posts = dc.fetch_posts()
        empty = sum(1 for p in posts if not p.has_text)
        pics = sum(len(p.images) for p in posts)
        blind = sum(1 for p in posts if not p.has_text and p.has_images)
        _line(OK, "Discord forum read",
              f"{len(posts)} open post(s), {empty} without readable text, "
              f"{pics} image(s) across them")
        if blind:
            _line(OK, "Discord screenshot-only posts",
                  f"{blind} post(s) are pictures with no text — the vision model "
                  f"is what makes those auditable")
        if posts and empty == len(posts):
            _line(BAD, "Discord message content",
                  "all bodies empty → enable MESSAGE CONTENT INTENT")
            return False
        return True
    except requests.HTTPError as e:
        _line(BAD, "Discord", f"{e.response.status_code} {e.response.text[:120]}")
        return False
    except Exception as e:  # noqa: BLE001
        _line(BAD, "Discord", str(e))
        return False


def check_trello(cfg: Config) -> bool:
    auth = {"key": cfg.trello_key, "token": cfg.trello_token}
    try:
        b = requests.get(
            f"https://api.trello.com/1/boards/{cfg.trello_board_id}",
            params={**auth, "fields": "name"}, timeout=20,
        )
        b.raise_for_status()
        _line(OK, "Trello board", b.json().get("name"))

        tc = TrelloClient(cfg.trello_key, cfg.trello_token, cfg.trello_board_id)
        cards = tc.fetch_cards()
        linked = sum(1 for c in cards if c.is_discord_linked)
        _line(OK, "Trello cards read", f"{len(cards)} card(s), {linked} discord-linked")
        _report_board_passes(cfg, tc, cards)

        lst = requests.get(
            f"https://api.trello.com/1/lists/{cfg.trello_new_bug_list_id}",
            params={**auth, "fields": "name,idBoard"}, timeout=20,
        )
        lst.raise_for_status()
        lj = lst.json()
        on_board = lj.get("idBoard") == cfg.trello_board_id
        _line(OK if on_board else BAD, "Trello new-bug list",
              f"{lj.get('name')}" + ("" if on_board else " — list is NOT on this board!"))
        if not on_board:
            return False

        lbls = requests.get(
            f"https://api.trello.com/1/boards/{cfg.trello_board_id}/labels",
            params={**auth, "fields": "name"}, timeout=20,
        )
        lbls.raise_for_status()
        ids = {l["id"] for l in lbls.json()}
        if cfg.trello_audited_label_id in ids:
            _line(OK, "Trello audited label", "found on board")
        else:
            _line(BAD, "Trello audited label",
                  "id not found on this board → wrong TRELLO_AUDITED_LABEL_ID")
            return False
        return True
    except requests.HTTPError as e:
        _line(BAD, "Trello", f"{e.response.status_code} {e.response.text[:120]}")
        return False
    except Exception as e:  # noqa: BLE001
        _line(BAD, "Trello", str(e))
        return False


def _in_scope(cfg: Config, card) -> bool:
    """The same scoping the board passes apply, minus the per-run bookkeeping."""
    return (
        card.list_id in cfg.trello_audit_list_ids
        and card.list_id not in cfg.trello_skip_list_ids
    )


def _report_board_passes(cfg: Config, tc: TrelloClient, cards: list) -> None:
    """What the two board passes would find. Read-only, and capped.

    Only cards that carry comments are inspected, and only the first
    `_MAX_SCANNED` of them — this is a smoke test, not the run itself.
    """
    _line(OK, "Board pass scope",
          f"lists {', '.join(cfg.trello_audit_list_ids)} — "
          f"{sum(1 for c in cards if _in_scope(cfg, c))} card(s) in scope "
          f"(TRELLO_AUDIT_LIST_IDS)")

    hand_written = [
        c for c in cards
        if not c.is_discord_linked
        and cfg.trello_audited_label_id not in c.label_ids
        and _in_scope(cfg, c)
    ]
    _line(OK, "Board pass (unmarked cards)",
          f"{len(hand_written)} card(s) would be audited "
          f"(AUDIT_BOARD_CARDS={cfg.audit_board_cards}, cap "
          f"{cfg.max_board_audits_per_run})")

    with_comments = [
        c for c in cards if c.comment_count and _in_scope(cfg, c)
    ][:_MAX_SCANNED]
    blocked = 0
    for c in with_comments:
        if audit_comment.read_state(tc.fetch_comments(c)).wants_vision:
            blocked += 1
    _line(OK, "Board pass (blocked on images)",
          f"{blocked} card(s) of {len(with_comments)} scanned were left "
          f"unjudged because of a picture (REAUDIT_IMAGE_BLOCKED="
          f"{cfg.reaudit_image_blocked}, cap {cfg.max_reaudits_per_run})")


def _ping_model(cfg: Config, model: str, label: str) -> bool:
    try:
        r = requests.post(
            f"{cfg.deepseek_base_url}/chat/completions",
            headers={"Authorization": f"Bearer {cfg.deepseek_api_key}"},
            json={
                "model": model,
                "messages": [{"role": "user", "content": "ping"}],
                "max_tokens": 1,
            },
            timeout=30,
        )
        r.raise_for_status()
        _line(OK, label, f"model {model} responded")
        return True
    except requests.HTTPError as e:
        _line(BAD, label, f"{e.response.status_code} {e.response.text[:160]}")
        return False
    except Exception as e:  # noqa: BLE001
        _line(BAD, label, str(e))
        return False


def check_deepseek(cfg: Config) -> bool:
    ok = _ping_model(cfg, cfg.deepseek_model, "DeepSeek (text)")
    if not cfg.vision_enabled:
        _line(OK, "DeepSeek (vision)", "VISION_ENABLED=false — images are ignored")
        return ok
    return _ping_model(cfg, cfg.deepseek_vision_model, "DeepSeek (vision)") and ok


def main() -> int:
    try:
        cfg = Config.load()
    except SystemExit as e:
        print(e)
        return 2

    print("=== bug-triage connection check (read-only) ===")
    results = [check_discord(cfg), check_trello(cfg), check_deepseek(cfg)]
    print("=" * 47)
    if all(results):
        print("ALL GOOD ✅  — safe to run triage.py (try DRY_RUN=true first).")
        return 0
    print("SOME CHECKS FAILED ❌ — fix the FAIL lines above.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
