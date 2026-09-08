"""Discord -> Trello mirroring: give every open forum post a card.

Deterministic, apart from the duplicate check it delegates to `matcher.py`. A
thread already carrying a `discord-thread:` marker somewhere on the board is
left alone; the rest either join the card that reported the same bug first, or
open a new one in the "new bugs" list.

Nothing here audits anything — mirroring finishes before the first LLM audit
call, which is what lets a run with nothing new exit without spending tokens.
"""

from __future__ import annotations

from dataclasses import replace

from config import Config
from discord_client import ForumPost
from matcher import build_matcher, find_existing_card
from trello_client import Card, TrelloClient, marker_for


def card_body(post: ForumPost) -> str:
    """Title/body/replies of one thread, plus the de-dup marker footer."""
    parts = [post.body.strip() or "(no text in the original post)"]

    if post.replies:
        parts.append("**Replies from the thread:**")
        parts.extend(f"- {r}" for r in post.replies)

    footer = ["---"]
    if post.attachment_count:
        readable = (
            f", {len(post.images)} of them image(s) the triage agent reads"
            if post.images
            else " (no readable image among them)"
        )
        footer.append(f"Attachments: {post.attachment_count}{readable}.")
    footer.append(f"Reported on Discord: {post.url}")
    footer.append(marker_for(post.thread_id))

    return "\n\n".join(parts) + "\n\n" + "\n".join(footer)


def linked_desc(card: Card, post: ForumPost) -> str:
    """A human-written card's description with the Discord link glued on.

    Only the footer is appended — whatever a human typed stays untouched, so
    linking a card can never destroy the report they wrote.
    """
    return (
        f"{card.desc.rstrip()}\n\n---\n"
        f"Also reported on Discord: {post.url}\n"
        f"{marker_for(post.thread_id)}"
    )


def mirror(
    cfg: Config,
    trello: TrelloClient,
    posts: list[ForumPost],
    cards: list[Card],
    by_thread: dict[str, Card],
) -> None:
    """Give every unlinked post a card, in place: `by_thread` and `cards` grow.

    `cards` keeps mirroring the board so the later passes see the cards this run
    just created, and the duplicate check gets them as candidates too — two
    threads about one bug in the same batch land on one card.
    """
    new_posts = [p for p in posts if p.thread_id not in by_thread]
    if cfg.max_new_cards_per_run and len(new_posts) > cfg.max_new_cards_per_run:
        print(f"[triage] {len(new_posts)} new thread(s); capped to "
              f"{cfg.max_new_cards_per_run} this run (MAX_NEW_CARDS_PER_RUN)")
        new_posts = new_posts[: cfg.max_new_cards_per_run]

    matcher = None  # built lazily: no new threads -> no lookup, no tokens

    for post in new_posts:
        hit = None
        if cfg.match_existing_cards and cards:
            if matcher is None:
                matcher = build_matcher(
                    cfg.deepseek_api_key, cfg.deepseek_base_url, cfg.deepseek_model
                )
            hit = find_existing_card(matcher, post, cards, cfg.max_match_candidates)

        if hit is not None:
            desc = linked_desc(hit, post)
            trello.set_desc(hit.id, desc)
            also = f" (now tracks {len(hit.discord_thread_ids) + 1} threads)"
            print(f"[triage] linked thread {post.thread_id} to existing card "
                  f"{hit.id}: {hit.name!r}{also}")
            linked = replace(hit, desc=desc)
            by_thread[post.thread_id] = linked
            cards[cards.index(hit)] = linked
            continue

        body = card_body(post)
        new_id = trello.create_card(cfg.trello_new_bug_list_id, post.title, body)
        print(f"[triage] created card for thread {post.thread_id}: {post.title!r}")
        fresh = Card(
            id=new_id,
            name=post.title,
            desc=body,
            list_id=cfg.trello_new_bug_list_id,
            label_ids=(),
        )
        by_thread[post.thread_id] = fresh
        cards.append(fresh)
