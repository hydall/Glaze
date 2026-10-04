"""Orchestrator. Runs once per invocation (the workflow schedules it daily).

Discord is still the primary work queue, but it is no longer the only one: after
the forum is mirrored and audited, the board itself is swept twice — once for
cards whose earlier audit gave up on a screenshot, once for cards nobody
mirrored from Discord at all.

Flow (only the audit passes touch the LLM):
  1. Pull the open Discord forum posts.
  2. Pull Trello cards ONCE, and index them by their `discord-thread:<id>`
     markers: does this thread already have a card, and was that card audited?
  3. mirror.py — any thread with no card of its own either joins the card that
     already reports that bug (one DeepSeek text call) or gets a new one.
  4. EARLY EXIT: nothing to audit in any of the three passes -> stop before the
     agents are ever built. A quiet day still spends zero tokens.
  5. Pass 1 (discord): every open thread whose card lacks the audited label.
     A report carrying screenshots goes to the vision model with the pictures
     attached; a text-only report stays on the cheap text model.
  6. Pass 2 (reaudit): cards whose recorded verdict was "blocked on images" —
     the backlog the text-only era left behind — judged again with their
     pictures. Retires itself per card once a vision verdict exists.
  7. Pass 3 (board): cards with no Discord marker and no audited label, i.e.
     hand-written ones. Title, description, comments and attached images.

Both board passes only ever touch cards sitting in `TRELLO_AUDIT_LIST_IDS`
(the new-bug list unless it is set); the rest of the board is read as an index
and left alone.

Nothing here ever modifies source code or opens a PR.
"""

from __future__ import annotations

import sys

import mirror
from audit_pass import AuditPass
from config import Config
from discord_client import DiscordClient, ForumPost
from images import ImageLoader
from runner import AuditRunner
from trello_client import Card, TrelloClient


def _audit_queue(
    posts: list[ForumPost],
    by_thread: dict[str, Card],
    audited_label_id: str,
) -> list[tuple[ForumPost, Card]]:
    """Threads still needing a first audit, one entry per card.

    Driven by the forum, never by the board: a thread is a candidate only if its
    card is missing the audited label. Threads whose card creation was capped
    during mirroring simply wait for the next run. Duplicates share a card, and
    a card is audited once — the later threads add their link, not a second
    audit of the same bug.
    """
    queue: list[tuple[ForumPost, Card]] = []
    claimed: set[str] = set()
    for p in posts:
        card = by_thread.get(p.thread_id)
        if card is None or audited_label_id in card.label_ids:
            continue
        if card.id in claimed:
            print(f"[triage] thread {p.thread_id} shares card {card.id} with an "
                  f"earlier thread — no second audit")
            continue
        claimed.add(card.id)
        queue.append((p, card))
    return queue


def main() -> int:
    cfg = Config.load()

    discord = DiscordClient(
        cfg.discord_bot_token,
        cfg.discord_guild_id,
        cfg.discord_forum_channel_id,
        ignored_tag_ids=cfg.discord_ignored_tag_ids,
        skip_archived=cfg.discord_skip_archived,
    )
    trello = TrelloClient(
        cfg.trello_key, cfg.trello_token, cfg.trello_board_id, dry_run=cfg.dry_run
    )

    # --- Step 1+2: the forum queue and the board index ----------------------
    posts = discord.fetch_posts()
    cards = trello.fetch_cards()
    by_thread: dict[str, Card] = {tid: c for c in cards for tid in c.discord_thread_ids}
    images_seen = sum(len(p.images) for p in posts)
    print(f"[triage] discord posts={len(posts)} (images={images_seen}) "
          f"trello cards={len(cards)} already-linked-threads={len(by_thread)}")
    in_scope = sum(1 for c in cards if c.list_id in cfg.trello_audit_list_ids)
    print(f"[triage] board passes scoped to list(s) "
          f"{', '.join(cfg.trello_audit_list_ids)} — {in_scope} card(s) in scope")

    # --- Step 3: mirror new Discord posts into Trello -----------------------
    mirror.mirror(cfg, trello, posts, cards, by_thread)

    # --- Step 4: is there anything to audit at all? -------------------------
    queue = _audit_queue(posts, by_thread, cfg.trello_audited_label_id)
    if cfg.max_audits_per_run and len(queue) > cfg.max_audits_per_run:
        print(f"[triage] {len(queue)} thread(s) pending; auditing "
              f"{cfg.max_audits_per_run} this run (MAX_AUDITS_PER_RUN)")
        queue = queue[: cfg.max_audits_per_run]

    # Building the passes costs nothing — both agents are lazy — so the board
    # scan below can reuse the very cache the passes will run on.
    passes = AuditPass(
        cfg,
        trello,
        AuditRunner(
            cfg,
            ImageLoader(cfg.trello_key, cfg.trello_token, cfg.max_image_bytes),
        ),
    )

    if not queue and not passes.has_work(cards):
        print("[triage] nothing new to audit — exiting before LLM.")
        return 0

    # --- Steps 5-7: the three audit passes ---------------------------------
    passes.discord(queue)

    posts_by_thread = {p.thread_id: p for p in posts}
    if cfg.reaudit_image_blocked:
        passes.image_blocked(cards, posts_by_thread)
    if cfg.audit_board_cards:
        passes.board(cards)

    if passes.failures:
        print(f"[triage] completed with {passes.failures} audit failure(s).",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
