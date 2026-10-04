"""What the agent writes on a card, and how a later run reads it back.

The board is the only database this pipeline has. Since the vision pass, one
more fact has to survive between runs: *why* an audit ended the way it did —
because a screenshot could not be read, or because the report itself was too
thin. That is what lets the next run come back for exactly the cards whose
verdict a picture might change, instead of re-auditing the whole board.

So every comment this agent posts ends with a marker line:

    glaze-triage:v2 mode=vision images=3 blocked=no

`mode` is the model that judged it (`text` / `vision` / `none` when no model ran
at all), `images` is how many pictures actually reached it, and `blocked=yes`
means "this verdict is a request for information, not an audit".

Comments written before the marker existed are still recognised, by the two
headlines the old code emitted — a card audited last month is picked up by the
image sweep just like a fresh one.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import TYPE_CHECKING, Iterable, Sequence

if TYPE_CHECKING:  # pragma: no cover — import cycle at runtime, types only
    from auditor import BugAudit
    from trello_client import Comment

_MARKER_RE = re.compile(
    r"glaze-triage:v\d+\s+mode=(\w+)\s+images=(\d+)\s+blocked=(yes|no)"
)
# Headlines of the pre-marker comments. Only these two shapes were ever posted.
_LEGACY_AUDIT = "**Automated audit**"
_LEGACY_BLOCKED = "**NEED MORE INFO**"


def marker(mode: str, images: int, blocked: bool) -> str:
    return (
        f"glaze-triage:v2 mode={mode} images={images} "
        f"blocked={'yes' if blocked else 'no'}"
    )


def is_triage_comment(text: str) -> bool:
    """Did this agent write that comment? (marker, or a pre-marker headline)"""
    return bool(_MARKER_RE.search(text)) or (
        _LEGACY_AUDIT in text or _LEGACY_BLOCKED in text
    )


@dataclass(frozen=True)
class AuditState:
    """How this card's most recent audit ended."""

    audited: bool = False
    mode: str = ""  # "text" / "vision" / "none" / "" when never audited
    images_seen: int = 0
    blocked_on_images: bool = False

    @property
    def wants_vision(self) -> bool:
        """Would showing the pictures to a vision model change anything?

        Yes when an audit exists, it ended as a request for information, and no
        vision model has looked at this card yet. A card the vision model
        already saw is never re-opened — if it still says NEED MORE INFO, the
        answer really is missing, and repeating the call would only spend
        tokens to post the same comment again.
        """
        return self.audited and self.blocked_on_images and self.mode != "vision"


def read_state(comments: Iterable["Comment"]) -> AuditState:
    """Replay a card's comments (oldest first) into the state they leave behind."""
    state = AuditState()
    for c in comments:
        text = c.text or ""
        m = _MARKER_RE.search(text)
        if m:
            state = AuditState(
                audited=True,
                mode=m.group(1),
                images_seen=int(m.group(2)),
                blocked_on_images=m.group(3) == "yes",
            )
        elif _LEGACY_BLOCKED in text:
            state = AuditState(audited=True, mode="text", blocked_on_images=True)
        elif _LEGACY_AUDIT in text:
            state = AuditState(audited=True, mode="text", blocked_on_images=False)
    return state


def _footer(source_url: str | None, mode: str, images: int, blocked: bool) -> str:
    src = f"\nSource: {source_url}" if source_url else ""
    return f"{src}\n\n{marker(mode, images, blocked)}"


def unreadable(source_url: str | None, images_attempted: int) -> str:
    """No text, and no picture we could read either — ask a human.

    `images_attempted` separates the two cases in the wording: a report with no
    attachments at all is missing its description, while one whose attachments
    all failed to load needs them re-uploaded.
    """
    if images_attempted:
        why = (
            f"Its {images_attempted} attachment(s) could not be read — they may "
            f"be an unsupported format, too large, or no longer available."
        )
    else:
        why = "It carries no attachments to read either."
    return (
        f"⚠️ **NEED MORE INFO** — this report carries no readable "
        f"text. {why}\n\nPlease add: what you did, what you expected, and what "
        f"happened instead. A screenshot of the problem helps — it is read "
        f"automatically.\n\n*(No audit was performed. Nothing was changed.)*"
        f"{_footer(source_url, 'none', 0, True)}"
    )


def render(
    audit: "BugAudit",
    source_url: str | None,
    mode: str,
    images: Sequence[object] = (),
) -> str:
    """The audit as a Trello comment (markdown-ish), marker included."""
    seen = len(images)
    src = f"\nSource: {source_url}" if source_url else ""
    shown = (
        f"\n\n**Images read** ({seen})\n{audit.image_findings.strip()}"
        if seen and audit.image_findings.strip()
        else ""
    )

    if audit.needs_more_info:
        asks = audit.missing_info.strip() or (
            "The report does not say enough to tell what went wrong. Ask the "
            "reporter for steps to reproduce."
        )
        return (
            f"⚠️ **NEED MORE INFO** — automated triage could not "
            f"judge this report.{src}\n\n"
            f"**What was understood**\n{audit.summary}{shown}\n\n"
            f"**What is missing**\n{asks}\n\n"
            f"*(No audit was performed. Nothing was changed.)*\n\n"
            f"{marker(mode, seen, True)}"
        )

    files = "\n".join(f"- {f}" for f in audit.relevant_files) or "- (none identified)"
    verdict = "actionable" if audit.is_actionable else "NOT clearly actionable"
    notes = f"\n**Notes:** {audit.notes}" if audit.notes else ""
    eyes = " \U0001f441 read the attached image(s)" if seen else ""
    return (
        f"\U0001f916 **Automated audit** (DeepSeek{eyes}) — {verdict}, severity "
        f"**{audit.severity}**, confidence **{audit.confidence}**{src}\n\n"
        f"**Summary**\n{audit.summary}{shown}\n\n"
        f"**Suspected root cause**\n{audit.root_cause}\n\n"
        f"**Proposed fix (needs human approval — nothing was changed)**\n"
        f"{audit.proposed_fix}\n\n"
        f"**Relevant files**\n{files}{notes}\n\n"
        f"{marker(mode, seen, False)}"
    )
