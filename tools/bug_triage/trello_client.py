"""Trello REST access. The board holds the triage state (which Discord thread
already has a card, whether it was audited, and — since the vision pass — how
that audit ended); we never store state elsewhere.

The board is now read as a work queue too, not only as a cross-check for the
forum: after the Discord phase the run sweeps cards that carry no Discord marker
and no audited label, and re-visits cards whose audit was blocked on a
screenshot. That means reading each card's attachments and comments, so those
two calls live here as well — made only for cards whose badges say there is
something to fetch.

De-dup contract: every card that tracks a Discord post carries a hidden marker
line in its description:

    discord-thread:<thread_id>

so "is this bug already on the board?" is just a scan over card descriptions —
survives workflow restarts with no external DB. A card can carry SEVERAL such
markers: when two forum threads turn out to report the same bug, the later ones
are appended to the card that reported it first instead of opening duplicates.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

import requests

from images import ImageRef

_API = "https://api.trello.com/1"
_MARKER_RE = re.compile(r"discord-thread:(\d+)")
# How many comments of one card are replayed. A bug card does not have a
# thousand; the cap only stops a runaway request.
_MAX_COMMENTS = 50
_IMAGE_URL_RE = re.compile(r"\.(?:png|jpe?g|gif|webp)(?:\?|$)", re.IGNORECASE)
# Bare or markdown-embedded links inside a comment body.
_URL_IN_TEXT_RE = re.compile(r"https?://[^\s<>()\[\]\"']+", re.IGNORECASE)
# The bookkeeping footer a card grows: markers and back-links, no bug content.
_FOOTER_LINE_RE = re.compile(
    r"^(?:---|discord-thread:\d+|(?:Also )?[Rr]eported on Discord:.*|"
    r"Attachments:.*)$\n?",
    re.MULTILINE,
)


def marker_for(thread_id: str) -> str:
    return f"discord-thread:{thread_id}"


def strip_markers(desc: str) -> str:
    """Card text without the bookkeeping footer.

    The `discord-thread:` markers and back-links say nothing about what the bug
    is, and on a card that already collected several reports they would crowd
    out the part a model has to judge.
    """
    return _FOOTER_LINE_RE.sub("", desc).strip()


def image_refs_in_text(text: str, origin: str) -> list[ImageRef]:
    """Image links pasted into a card description or comment.

    Trello has no attachment concept for comments, so a screenshot discussed in
    a comment is a URL in its body — usually the card's own attachment link.
    """
    return [
        ImageRef(url=u.rstrip(".,);"), name="", origin=origin)
        for u in _URL_IN_TEXT_RE.findall(text)
        if _IMAGE_URL_RE.search(u) or "/attachments/" in u
    ]


@dataclass(frozen=True)
class Comment:
    """One `commentCard` action: what a human (or this agent) said on a card."""

    id: str
    text: str
    author: str
    author_id: str
    date: str


@dataclass(frozen=True)
class Card:
    id: str
    name: str
    desc: str
    list_id: str
    label_ids: tuple[str, ...]
    url: str = ""
    # From the card's badges — how many attachments / comments it carries.
    # Zero means the per-card fetches below can be skipped entirely.
    attachment_count: int = 0
    comment_count: int = 0

    @property
    def discord_thread_ids(self) -> tuple[str, ...]:
        """Every Discord thread this card tracks, in the order they were linked."""
        return tuple(m.group(1) for m in _MARKER_RE.finditer(self.desc))

    @property
    def created_at(self) -> int:
        """Creation time as a unix timestamp.

        Trello ids are Mongo ObjectIds: the first four bytes are the creation
        time. That is what makes "the card that reported it first" answerable
        without another API call.
        """
        try:
            return int(self.id[:8], 16)
        except ValueError:
            return 0

    @property
    def is_discord_linked(self) -> bool:
        return bool(self.discord_thread_ids)


def _card_from_json(c: dict) -> Card:
    badges = c.get("badges") or {}
    return Card(
        id=c["id"],
        name=c.get("name", ""),
        desc=c.get("desc", ""),
        list_id=c.get("idList", ""),
        label_ids=tuple(c.get("idLabels", [])),
        url=c.get("shortUrl", ""),
        attachment_count=int(badges.get("attachments") or 0),
        comment_count=int(badges.get("comments") or 0),
    )


class TrelloClient:
    def __init__(self, key: str, token: str, board_id: str, dry_run: bool = False):
        self._board_id = board_id
        self._dry_run = dry_run
        self._auth = {"key": key, "token": token}
        self._s = requests.Session()

    def _req(self, method: str, path: str, **params) -> dict | list:
        r = self._s.request(
            method, f"{_API}{path}", params={**self._auth, **params}, timeout=30
        )
        r.raise_for_status()
        return r.json() if r.text else {}

    def fetch_cards(self) -> list[Card]:
        raw = self._req(
            "GET",
            f"/boards/{self._board_id}/cards",
            fields="name,desc,idList,idLabels,shortUrl,badges",
        )
        return [_card_from_json(c) for c in raw]  # type: ignore[union-attr]

    def fetch_attachments(self, card: Card) -> list[ImageRef]:
        """The card's image attachments, as refs (nothing is downloaded here).

        Trello reports the attachment count in the card's badges, so a card
        with none costs no request at all.
        """
        if not card.attachment_count:
            return []
        try:
            raw = self._req(
                "GET",
                f"/cards/{card.id}/attachments",
                fields="name,url,mimeType,bytes",
            )
        except requests.RequestException as e:
            print(f"[trello] attachments unavailable for {card.id}: {e}")
            return []
        refs: list[ImageRef] = []
        for a in raw:  # type: ignore[union-attr]
            url = a.get("url") or ""
            if not url:
                continue
            mime = (a.get("mimeType") or "").lower()
            if not (mime.startswith("image/") or _IMAGE_URL_RE.search(url)):
                continue
            refs.append(
                ImageRef(url=url, name=a.get("name", ""), origin="card attachment")
            )
        return refs

    def fetch_comments(self, card: Card) -> list[Comment]:
        """The card's comments, oldest first. Skipped when the badge says none."""
        if not card.comment_count:
            return []
        try:
            raw = self._req(
                "GET",
                f"/cards/{card.id}/actions",
                filter="commentCard",
                limit=_MAX_COMMENTS,
            )
        except requests.RequestException as e:
            print(f"[trello] comments unavailable for {card.id}: {e}")
            return []
        out = [
            Comment(
                id=a.get("id", ""),
                text=((a.get("data") or {}).get("text") or "").strip(),
                author=((a.get("memberCreator") or {}).get("username") or "unknown"),
                author_id=a.get("idMemberCreator", ""),
                date=a.get("date", ""),
            )
            for a in raw  # type: ignore[union-attr]
        ]
        out.reverse()  # the API returns newest-first; audit history reads forward
        return out

    def me(self) -> str:
        """The member id this token acts as — that is what marks our own
        comments as ours when a card's audit history is replayed."""
        try:
            m = self._req("GET", "/members/me", fields="id")
            return str(m.get("id", ""))  # type: ignore[union-attr]
        except requests.RequestException as e:
            print(f"[trello] could not identify the token's member: {e}")
            return ""

    def create_card(self, list_id: str, name: str, desc: str) -> str:
        if self._dry_run:
            print(f"[dry-run] would create card: {name!r}")
            return "dry-run-card-id"
        card = self._req("POST", "/cards", idList=list_id, name=name, desc=desc)
        return card["id"]  # type: ignore[index]

    def set_desc(self, card_id: str, desc: str) -> None:
        """Overwrite a card's description — used to write the Discord marker
        and back-link into a card a human created for the same bug."""
        if self._dry_run:
            print(f"[dry-run] would rewrite desc of {card_id}")
            return
        self._req("PUT", f"/cards/{card_id}", desc=desc)

    def add_comment(self, card_id: str, text: str) -> None:
        if self._dry_run:
            print(f"[dry-run] would comment on {card_id}: {text[:80]}...")
            return
        self._req("POST", f"/cards/{card_id}/actions/comments", text=text)

    def add_label(self, card_id: str, label_id: str) -> None:
        if self._dry_run:
            print(f"[dry-run] would label {card_id} with {label_id}")
            return
        self._req("POST", f"/cards/{card_id}/idLabels", value=label_id)
