"""Image plumbing for the vision-capable audit.

The pipeline used to *count* attachments and give up on them ("images are NOT
readable by the triage agent"). DeepSeek's vision model can read them, so the
images themselves now have to travel from Discord / Trello into the prompt.

Two jobs live here and nothing else:
  * `ImageRef` — "there is a picture at this URL", produced by the Discord and
    Trello clients, cheap to build (no download, no auth).
  * `ImageLoader` — turns refs into bytes, once, with the credentials the host
    demands and hard ceilings on size and count.

Downloads are cached per URL for the whole run: the same screenshot can be
reached through a Discord thread, the mirrored card and a re-audit pass, and
paying for it three times would be silly.

The media type is sniffed from the first bytes, never taken from the file name
or the server's `Content-Type` — DeepSeek does the same, and Discord happily
serves a `.png` that is really a JPEG. Anything that is not one of the four
formats the API accepts (JPEG / PNG / GIF / WebP) is dropped here rather than
rejected with a 400 in the middle of an audit.
"""

from __future__ import annotations

from dataclasses import dataclass
from urllib.parse import urlsplit

import requests

# The four formats DeepSeek's vision endpoint accepts. `_sniff` matches on the
# magic bytes; WebP needs two windows, so it is handled separately below.
_MAGIC: tuple[tuple[bytes, str], ...] = (
    (b"\x89PNG\r\n\x1a\n", "image/png"),
    (b"\xff\xd8\xff", "image/jpeg"),
    (b"GIF87a", "image/gif"),
    (b"GIF89a", "image/gif"),
)

_TIMEOUT = 30


def _sniff(data: bytes) -> str | None:
    """The media type of these bytes, or None if it is not a supported image."""
    for magic, mime in _MAGIC:
        if data.startswith(magic):
            return mime
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None


@dataclass(frozen=True)
class ImageRef:
    """A picture we know how to reach. Nothing is downloaded to build one."""

    url: str
    name: str = ""
    # Human-readable provenance, shown to the model so it can say "the
    # screenshot in the second reply" instead of "image 2".
    origin: str = "attachment"

    @property
    def label(self) -> str:
        return f"{self.name} ({self.origin})" if self.name else self.origin


@dataclass(frozen=True)
class LoadedImage:
    ref: ImageRef
    data: bytes
    media_type: str


def dedup(refs: list[ImageRef]) -> list[ImageRef]:
    """Same picture referenced twice (post + embed, card + comment) -> once."""
    seen: set[str] = set()
    out: list[ImageRef] = []
    for r in refs:
        if r.url in seen:
            continue
        seen.add(r.url)
        out.append(r)
    return out


class ImageLoader:
    """Downloads `ImageRef`s, with the auth each host needs and a byte ceiling.

    Discord's CDN links are pre-signed, so they must NOT carry the bot token.
    Trello's own attachment URLs are the opposite: they 401 without the OAuth
    header built from the API key + token. Everything else (a link a human
    pasted onto a card) is fetched anonymously.
    """

    def __init__(
        self,
        trello_key: str,
        trello_token: str,
        max_bytes: int,
        timeout: int = _TIMEOUT,
    ):
        self._trello_auth = (
            f'OAuth oauth_consumer_key="{trello_key}", oauth_token="{trello_token}"'
        )
        self._max_bytes = max_bytes
        self._timeout = timeout
        self._s = requests.Session()
        self._s.headers.update(
            {"User-Agent": "GlazeBugTriage (https://github.com/hydall/Glaze, 1.0)"}
        )
        self._cache: dict[str, LoadedImage | None] = {}

    def _headers(self, url: str) -> dict[str, str]:
        host = (urlsplit(url).hostname or "").lower()
        if host == "trello.com" or host.endswith(".trello.com"):
            return {"Authorization": self._trello_auth}
        return {}

    def _download(self, ref: ImageRef) -> LoadedImage | None:
        try:
            r = self._s.get(
                ref.url,
                headers=self._headers(ref.url),
                timeout=self._timeout,
                stream=True,
            )
            r.raise_for_status()
            # Read one byte past the ceiling: if it arrives, the image is over
            # budget and gets dropped without buffering the whole thing.
            data = r.raw.read(self._max_bytes + 1, decode_content=True)
        except Exception as e:  # noqa: BLE001 — a dead link must not sink a run
            print(f"[images] skip {ref.url[:80]}: {e}")
            return None

        if len(data) > self._max_bytes:
            print(f"[images] skip {ref.label}: larger than {self._max_bytes} bytes")
            return None
        mime = _sniff(data)
        if mime is None:
            print(f"[images] skip {ref.label}: not a JPEG/PNG/GIF/WebP")
            return None
        return LoadedImage(ref=ref, data=data, media_type=mime)

    def load(self, refs: list[ImageRef], limit: int) -> list[LoadedImage]:
        """The first `limit` refs that turn out to be real, supported images.

        Refs that fail to download are skipped, not counted — a broken link at
        the front of the list must not eat the whole budget.
        """
        out: list[LoadedImage] = []
        for ref in dedup(refs):
            if limit and len(out) >= limit:
                print(f"[images] {ref.label}: over the per-audit cap ({limit}), "
                      f"not sent to the model")
                break
            if ref.url not in self._cache:
                self._cache[ref.url] = self._download(ref)
            got = self._cache[ref.url]
            if got is not None:
                # Cached under a different ref (same URL, other provenance):
                # keep this call's label so the prompt stays accurate.
                out.append(LoadedImage(ref, got.data, got.media_type))
        return out
