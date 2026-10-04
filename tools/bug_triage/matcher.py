"""Duplicate check: is this Discord thread already a card on the board?

New threads are not blindly mirrored. Before creating a card, the thread is
compared against the cards already on the board — the ones a human typed in by
hand and the ones earlier forum threads produced alike — and a DeepSeek call
decides whether any of them reports the SAME bug. On a match the orchestrator
writes the marker and the back-link into that card instead of opening a
duplicate, so two people reporting one bug in two threads land on one card.

Two guards keep this cheap and quiet:
  * candidates are pre-ranked by shared words and cut to the top N, so the
    prompt stays small on a busy board;
  * the model must answer with a card number and a confidence, and anything
    below _MIN_CONFIDENCE is treated as "no match" — a missed link costs one
    duplicate card, a wrong link puts a thread on the wrong card, so we bias to
    the cheap mistake.

This agent gets NO tools: it only compares text. Source-code investigation is
the auditor's job.
"""

from __future__ import annotations

import re
import sys

from pydantic import BaseModel, Field
from pydantic_ai import Agent, PromptedOutput
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider

from discord_client import ForumPost
from trello_client import Card, strip_markers

# Below this the model is guessing; we open a fresh card instead.
_MIN_CONFIDENCE = 0.7
# Prompt budget per thread.
_MAX_POST_CHARS = 1200
_MAX_CARD_DESC_CHARS = 400

_SYSTEM_PROMPT = """\
You decide whether a bug reported on Discord is ALREADY tracked by one of the
existing Trello cards you are shown.

Answer with the number of the single card that reports the SAME bug, or 0 if
none of them does. The cards are listed oldest first, and some of them were
themselves written from an earlier Discord thread — that is fine: a second
thread about the same bug belongs on the card that reported it first. If more
than one card reports this bug, answer with the SMALLEST matching number.

The same bug means the same faulty behaviour: same symptom in the same feature,
even when the wording, language or level of detail differs. It is NOT enough
that two reports touch the same screen, the same feature area, or are both
crashes. Two different bugs in the same widget are two different bugs.

Be conservative. A missed match only costs a duplicate card that a human can
merge; a wrong match hangs a Discord thread on an unrelated card. If you are
unsure, answer 0. Set `confidence` to how sure you are that the card you picked
is the same bug (0.0-1.0); when you answer 0, confidence is ignored.
"""

_WORD_RE = re.compile(r"[^\W\d_]+", re.UNICODE)
_STOP = {
    "when", "with", "that", "this", "from", "have", "does", "doesn", "there",
    "after", "before", "while", "should", "would", "could", "about", "into",
    "then", "than", "they", "them", "your", "just", "only", "also",
    "если", "когда", "после", "чтобы", "этот", "того", "тоже", "есть", "быть",
}


class CardMatch(BaseModel):
    card_number: int = Field(
        description="1-based number of the card reporting the same bug, 0 if none."
    )
    confidence: float = Field(
        default=0.0, description="0.0-1.0 — how sure you are about that card."
    )
    reason: str = Field(default="", description="One short sentence.")


def build_matcher(api_key: str, base_url: str, model_name: str) -> Agent[None, CardMatch]:
    model = OpenAIChatModel(
        model_name,
        provider=OpenAIProvider(base_url=base_url, api_key=api_key),
    )
    return Agent(
        model,
        # Prompted JSON rather than a forced output tool — see auditor.py.
        output_type=PromptedOutput(CardMatch),
        system_prompt=_SYSTEM_PROMPT,
        retries=2,
    )


def _tokens(text: str) -> set[str]:
    return {
        w for w in (m.group().lower() for m in _WORD_RE.finditer(text))
        if len(w) > 3 and w not in _STOP
    }


def shortlist(post: ForumPost, cards: list[Card], limit: int) -> list[Card]:
    """The `limit` candidate cards most likely to be about this thread.

    Pure lexical pre-ranking — it only decides what the model gets to look at
    when a board has more cards than fit in one prompt, never whether something
    is a match. Whatever survives the cut is handed over oldest first, so
    "answer with the smallest matching number" means "the card that reported
    this bug first".
    """
    picked = list(cards)
    if limit and len(picked) > limit:
        wanted = _tokens(f"{post.title}\n{post.body}")
        ranked = sorted(
            picked,
            key=lambda c: len(wanted & _tokens(f"{c.name}\n{c.desc}")),
            reverse=True,
        )
        picked = ranked[:limit]
    return sorted(picked, key=lambda c: c.created_at)


def _trim(text: str, limit: int) -> str:
    text = text.strip()
    return text if len(text) <= limit else text[:limit] + " …[trimmed]"


def _prompt(post: ForumPost, candidates: list[Card]) -> str:
    body = _trim(post.body or "(no text in the original post)", _MAX_POST_CHARS)
    lines = [
        "Discord bug report:",
        f"Title: {post.title}",
        f"Body: {body}",
        "",
        "Existing Trello cards:",
    ]
    for i, c in enumerate(candidates, start=1):
        lines.append(f"{i}. {c.name}")
        desc = _trim(strip_markers(c.desc), _MAX_CARD_DESC_CHARS)
        if desc:
            lines.append(f"   {desc}")
    lines.append("")
    lines.append("Which card reports the same bug? Answer 0 if none.")
    return "\n".join(lines)


def find_existing_card(
    agent: Agent[None, CardMatch],
    post: ForumPost,
    cards: list[Card],
    max_candidates: int,
) -> Card | None:
    """The card that already tracks this thread's bug, or None.

    A failed call is not fatal: the caller just creates a card, which is the
    same outcome the pipeline had before this check existed.
    """
    candidates = shortlist(post, cards, max_candidates)
    if not candidates:
        return None

    try:
        result = agent.run_sync(_prompt(post, candidates))
    except Exception as e:  # noqa: BLE001 — a bad match call must not sink the run
        print(f"[match] lookup FAILED for thread {post.thread_id}: {e}",
              file=sys.stderr)
        return None

    m = result.output
    if not 1 <= m.card_number <= len(candidates):
        return None
    if m.confidence < _MIN_CONFIDENCE:
        print(f"[match] thread {post.thread_id}: candidate "
              f"{candidates[m.card_number - 1].name!r} rejected, confidence "
              f"{m.confidence:.2f} < {_MIN_CONFIDENCE}")
        return None

    hit = candidates[m.card_number - 1]
    print(f"[match] thread {post.thread_id} == card {hit.id} {hit.name!r} "
          f"(confidence {m.confidence:.2f}) — {m.reason}")
    return hit
