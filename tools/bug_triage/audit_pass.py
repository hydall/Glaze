"""The three passes that actually audit something, in the order they run.

1. `discord`  — the forum queue: every open thread whose card is not yet
   labelled `audited`. Unchanged in spirit; it just goes through the runner now,
   so a screenshot-only report reaches the vision model instead of a
   "NEED MORE INFO" boilerplate.
2. `image_blocked` — the catch-up: cards whose recorded verdict was "could not
   read this, it's a screenshot". They were audited under a blind model, so the
   board is walked once to find them and they are judged again with their
   pictures attached. This is the pass that drains the backlog the text-only era
   left behind, and it retires itself — once a card has a vision verdict it is
   never re-opened by it again.
3. `board` — the sweep the pipeline never had: cards nobody mirrored from
   Discord and nobody audited, i.e. the ones a human typed straight onto the
   board. Title, description, comments and attached images all go in.

Passes 2 and 3 read the board as a queue, so they are scoped to the lists in
`TRELLO_AUDIT_LIST_IDS` (the new-bug list by default): a card in an Ideas or
Feature column is never audited, commented on or labelled by them. Pass 1 is
driven by the forum, not by the board, and audits a thread's own card wherever
that card sits.

All three share one commit path (comment + `audited` label) and one per-card
cache, so a card whose comments were read in pass 2 costs no second request in
pass 3. A card touched by an earlier pass is never touched again in the same
run.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass

import audit_comment
import subjects
from config import Config
from discord_client import ForumPost
from images import ImageRef
from runner import AuditRunner
from subjects import AuditSubject
from trello_client import Card, Comment, TrelloClient


@dataclass
class _CardContext:
    comments: list[Comment]
    attachments: list[ImageRef]


class AuditPass:
    """Runs an audit pass over cards and commits the verdict to the board."""

    def __init__(self, cfg: Config, trello: TrelloClient, runner: AuditRunner):
        self._cfg = cfg
        self._trello = trello
        self._runner = runner
        self._ctx: dict[str, _CardContext] = {}
        self._touched: set[str] = set()
        self.failures = 0

    # --- board reads -------------------------------------------------------

    def _context(self, card: Card) -> _CardContext:
        if card.id not in self._ctx:
            self._ctx[card.id] = _CardContext(
                comments=self._trello.fetch_comments(card),
                attachments=self._trello.fetch_attachments(card),
            )
        return self._ctx[card.id]

    def has_work(self, cards: list[Card]) -> bool:
        """Would pass 2 or pass 3 do anything on this board?

        Answered without an LLM — pass 3's candidates are visible in the cards
        already in hand, and pass 2's only needs the comments of cards that have
        any. Those reads land in the same cache the passes use, so asking costs
        nothing beyond what running would have cost anyway. This is what keeps
        the orchestrator's early exit meaningful now that the board is a queue.
        """
        for card in cards:
            if self._skipped(card):
                continue
            if (
                self._cfg.audit_board_cards
                and not card.is_discord_linked
                and self._cfg.trello_audited_label_id not in card.label_ids
                and not audit_comment.read_state(self._context(card).comments).audited
            ):
                return True
            if (
                self._cfg.reaudit_image_blocked
                and self._cfg.vision_enabled
                and card.comment_count
                and audit_comment.read_state(self._context(card).comments).wants_vision
            ):
                return True
        return False

    def _skipped(self, card: Card) -> bool:
        """Is this card out of the board passes' reach?

        The allowlist is what scopes the sweep: a card outside
        `TRELLO_AUDIT_LIST_IDS` is read (it may link a thread, it may be a
        duplicate candidate) but never audited, whatever else is true of it.
        """
        return (
            card.id in self._touched
            or card.list_id not in self._cfg.trello_audit_list_ids
            or card.list_id in self._cfg.trello_skip_list_ids
        )

    # --- one audit ---------------------------------------------------------

    def _commit(self, card: Card, subject: AuditSubject, tag: str) -> None:
        """Audit one subject and write the verdict onto its card."""
        try:
            result = self._runner.audit(subject)
        except Exception as e:  # noqa: BLE001 — one bad report must not sink the run
            print(f"[{tag}] audit FAILED for {subject.key}: {e}", file=sys.stderr)
            self.failures += 1
            return

        self._trello.add_comment(card.id, result.comment)
        if self._cfg.trello_audited_label_id not in card.label_ids:
            self._trello.add_label(card.id, self._cfg.trello_audited_label_id)
        self._touched.add(card.id)

        flag = " [NEED MORE INFO]" if result.needs_more_info else ""
        seen = f", {result.images} image(s)" if result.images else ""
        print(f"[{tag}] {subject.key}: {subject.title!r} — {result.mode}{seen}{flag}")

    # --- pass 1: the Discord queue ----------------------------------------

    def discord(self, queue: list[tuple[ForumPost, Card]]) -> None:
        for post, card in queue:
            self._commit(card, subjects.from_post(post), "discord")

    # --- pass 2: cards whose audit died on a screenshot -------------------

    def image_blocked(self, cards: list[Card], posts: dict[str, ForumPost]) -> None:
        """Re-audit the cards a blind model could not judge.

        A linked card is re-read from its Discord thread rather than from its
        own description: the thread is where the screenshots live, and by now it
        may also carry replies the card never got.
        """
        if not self._cfg.vision_enabled:
            print("[reaudit] VISION_ENABLED=false — nothing this pass can add")
            return

        cap = self._cfg.max_reaudits_per_run
        done = 0
        for card in cards:
            if self._skipped(card):
                continue
            if cap and done >= cap:
                print(f"[reaudit] cap reached ({cap}), the rest waits for the "
                      f"next run")
                return
            if not audit_comment.read_state(self._context(card).comments).wants_vision:
                continue

            subject = self._subject(card, posts)
            if not subject.has_images:
                print(f"[reaudit] card {card.id} {card.name!r}: blocked on images "
                      f"but none can be reached — left as is")
                continue
            self._commit(card, subject, "reaudit")
            done += 1

    # --- pass 3: cards nobody mirrored and nobody audited -----------------

    def board(self, cards: list[Card]) -> None:
        cap = self._cfg.max_board_audits_per_run
        done = 0
        for card in cards:
            if self._skipped(card):
                continue
            if card.is_discord_linked:
                continue  # the forum owns those; pass 1 already had its say
            if self._cfg.trello_audited_label_id in card.label_ids:
                continue
            if cap and done >= cap:
                print(f"[board] cap reached ({cap}), the rest waits for the "
                      f"next run")
                return
            ctx = self._context(card)
            if audit_comment.read_state(ctx.comments).audited:
                continue  # audited before the label existed / was removed by hand
            subject = subjects.from_card(card, ctx.comments, ctx.attachments)
            self._commit(card, subject, "board")
            done += 1

    # --- helpers -----------------------------------------------------------

    def _subject(self, card: Card, posts: dict[str, ForumPost]) -> AuditSubject:
        for tid in card.discord_thread_ids:
            post = posts.get(tid)
            if post is not None:
                return subjects.from_post(post)
        ctx = self._context(card)
        return subjects.from_card(card, ctx.comments, ctx.attachments)
