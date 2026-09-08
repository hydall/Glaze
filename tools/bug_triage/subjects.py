"""One shape for "the thing being audited", whatever it came from.

The auditor used to take a Discord thread and nothing else. It now also has to
judge a card a human typed straight onto the board, and to re-open a card whose
first audit died on a screenshot. Those three inputs differ only in where their
text and pictures live, so they are normalised here once and the agent never
learns the difference.

Nothing in here talks to the network: an `AuditSubject` is assembled from data
the clients already fetched, and its images are still just references.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

from audit_comment import is_triage_comment
from discord_client import ForumPost
from images import ImageRef, dedup
from trello_client import Card, Comment, image_refs_in_text, strip_markers

# A card comment quoted into the prompt is trimmed like a Discord reply is.
_MAX_COMMENT_CHARS = 1500


@dataclass(frozen=True)
class AuditSubject:
    key: str  # thread id or card id — for logs only
    kind: str  # "Discord thread" / "Trello card"
    title: str
    body: str
    replies: tuple[str, ...]
    images: tuple[ImageRef, ...]
    source_url: str

    @property
    def text(self) -> str:
        """The human-written part — what decides whether text alone can be read.

        The title counts. On a Trello card typed by a human it is often the
        whole report ("audio stops after switching character"), and a thread
        whose title says what broke is auditable even with an empty body.
        """
        return "\n".join([self.title, self.body, *self.replies]).strip()

    @property
    def has_images(self) -> bool:
        return bool(self.images)

    def report(self, shown: Sequence[ImageRef] = ()) -> str:
        """The report as the model sees it.

        `shown` is what actually got attached to the message — never the full
        `images` list. A picture that failed to download, or fell outside the
        per-audit cap, must not be announced to a model that cannot see it.
        """
        parts = [
            f"{self.kind} — {self.title}",
            self.body.strip() or "(no text in the original report)",
        ]
        if self.replies:
            parts.append("Follow-up messages:\n" + "\n".join(f"- {r}" for r in self.replies))
        if shown:
            parts.append(
                "Attached images (shown to you below, in this order):\n"
                + "\n".join(
                    f"- Image {i}: {ref.label}"
                    for i, ref in enumerate(shown, start=1)
                )
            )
        elif self.images:
            parts.append(
                f"This report has {len(self.images)} attachment(s), but none of "
                f"them is available to you in this message."
            )
        if self.source_url:
            parts.append(f"Source: {self.source_url}")
        return "\n\n".join(parts)


def _trim(text: str, limit: int) -> str:
    text = text.strip()
    return text if len(text) <= limit else text[:limit] + " …[trimmed]"


def from_post(post: ForumPost) -> AuditSubject:
    return AuditSubject(
        key=post.thread_id,
        kind="Discord thread",
        title=post.title,
        body=post.body,
        replies=post.replies,
        images=post.images,
        source_url=post.url,
    )


def from_card(card: Card, comments: list[Comment], attachments: list[ImageRef]) -> AuditSubject:
    """A card as a bug report: its description, the human comments, its pictures.

    Our own audit comments are dropped — they are this agent's earlier output,
    not something the reporter said, and feeding them back would let one shaky
    guess harden into a fact over successive runs.
    """
    replies: list[str] = []
    images: list[ImageRef] = list(attachments)
    images += image_refs_in_text(card.desc, "linked in the description")
    for c in comments:
        if is_triage_comment(c.text):
            continue
        images += image_refs_in_text(c.text, f"linked in a comment by {c.author}")
        if c.text:
            replies.append(f"{c.author}: {_trim(c.text, _MAX_COMMENT_CHARS)}")
    return AuditSubject(
        key=card.id,
        kind="Trello card",
        title=card.name,
        body=strip_markers(card.desc),
        replies=tuple(replies),
        images=tuple(dedup(images)),
        source_url=card.url,
    )
