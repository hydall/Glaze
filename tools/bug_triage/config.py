"""Central config: everything comes from env vars (GitHub Secrets in CI).

Nothing here has a real default for a secret — a missing secret raises loudly
so a misconfigured workflow fails fast instead of silently doing nothing.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


def _require(name: str) -> str:
    val = os.environ.get(name, "").strip()
    if not val:
        raise SystemExit(f"[config] missing required env var: {name}")
    return val


def _optional(name: str, default: str = "") -> str:
    """An unset *or empty* var falls back to the default.

    Empty matters: GitHub Actions expands an undefined `vars.X` to an empty
    string, so without this an unconfigured variable would silently mean
    "model = ''" or "matching off" instead of the documented default.
    """
    return os.environ.get(name, "").strip() or default


def _flag(name: str, default: str) -> bool:
    return _optional(name, default).lower() in ("1", "true", "yes")


def _csv(name: str) -> tuple[str, ...]:
    raw = _optional(name)
    return tuple(x.strip() for x in raw.split(",") if x.strip())


@dataclass(frozen=True)
class Config:
    # --- DeepSeek (OpenAI-compatible) ---
    deepseek_api_key: str
    deepseek_base_url: str
    deepseek_model: str
    # Multimodal sibling, used for any report that carries a picture. Same API,
    # same tools — it just has eyes. Text-only reports stay on the cheap model.
    deepseek_vision_model: str

    # --- Trello ---
    trello_key: str
    trello_token: str
    trello_board_id: str
    trello_new_bug_list_id: str  # where freshly-discovered bugs land
    trello_audited_label_id: str  # label meaning "AI already audited this"
    # The ONLY lists the board passes may audit. Everything outside them is
    # index-only: such a card still links its Discord thread and still counts as
    # a duplicate candidate, but is never audited, commented on or labelled —
    # which is what keeps the sweep off the Ideas / Feature columns. Empty means
    # no list is in scope; `load()` never leaves it empty (see below).
    trello_audit_list_ids: tuple[str, ...]
    # Subtractive filter applied on top: a list named here is dropped even if it
    # is in the allowlist. Only useful when the allowlist spans several columns.
    trello_skip_list_ids: tuple[str, ...]

    # --- Discord ---
    discord_bot_token: str
    discord_guild_id: str
    discord_forum_channel_id: str
    # Forum tag ids that mean "closed" (e.g. Solved / Duplicate / Won't fix).
    discord_ignored_tag_ids: tuple[str, ...]
    # Closed forum posts show up as archived, so they are skipped like locked
    # ones. Set DISCORD_SKIP_ARCHIVED=false to also triage auto-archived posts.
    discord_skip_archived: bool

    # --- Behaviour ---
    dry_run: bool  # if true: don't create cards / post comments, just log
    # Before mirroring a new thread, ask the model whether an existing
    # (human-written) card already tracks that bug; on a hit the thread is
    # linked to that card instead of opening a duplicate.
    match_existing_cards: bool
    # How many unlinked cards may be shown to the model in one lookup.
    max_match_candidates: int
    # Per-run ceilings so a first run over a long-lived forum can't flood the
    # board or the token budget in one go. 0 = unlimited.
    max_new_cards_per_run: int
    max_audits_per_run: int

    # --- Vision ---
    # Master switch. Off = images are never downloaded and the vision model is
    # never built; the pipeline behaves exactly as it did before.
    vision_enabled: bool
    # Pictures shown to the model per report. Each one costs up to 384 tokens,
    # and the fifth screenshot of the same dialog rarely adds anything.
    max_images_per_audit: int
    # Images larger than this are skipped rather than uploaded.
    max_image_bytes: int

    # --- Board passes (they read the board as a queue, not just as an index) --
    # Re-open cards whose audit ended "NEED MORE INFO" because it could not see
    # the screenshot, and run them again with the vision model.
    reaudit_image_blocked: bool
    max_reaudits_per_run: int
    # Audit cards that were never mirrored from Discord: no `discord-thread:`
    # marker, no audited label — someone typed them straight onto the board.
    audit_board_cards: bool
    max_board_audits_per_run: int

    @staticmethod
    def load() -> "Config":
        # The audit scope defaults to the new-bug list alone: an unconfigured
        # board is swept where the bugs are, never across the whole board.
        new_bug_list = _require("TRELLO_NEW_BUG_LIST_ID")
        return Config(
            deepseek_api_key=_require("DEEPSEEK_API_KEY"),
            deepseek_base_url=_optional("DEEPSEEK_BASE_URL", "https://api.deepseek.com"),
            deepseek_model=_optional("DEEPSEEK_MODEL", "deepseek-chat"),
            deepseek_vision_model=_optional(
                "DEEPSEEK_VISION_MODEL", "deepseek-v4-flash-vision-exp"
            ),
            trello_key=_require("TRELLO_KEY"),
            trello_token=_require("TRELLO_TOKEN"),
            trello_board_id=_require("TRELLO_BOARD_ID"),
            trello_new_bug_list_id=new_bug_list,
            trello_audited_label_id=_require("TRELLO_AUDITED_LABEL_ID"),
            trello_audit_list_ids=_csv("TRELLO_AUDIT_LIST_IDS") or (new_bug_list,),
            trello_skip_list_ids=_csv("TRELLO_SKIP_LIST_IDS"),
            discord_bot_token=_require("DISCORD_BOT_TOKEN"),
            discord_guild_id=_require("DISCORD_GUILD_ID"),
            discord_forum_channel_id=_require("DISCORD_FORUM_CHANNEL_ID"),
            discord_ignored_tag_ids=_csv("DISCORD_IGNORED_TAG_IDS"),
            discord_skip_archived=_flag("DISCORD_SKIP_ARCHIVED", "true"),
            dry_run=_flag("DRY_RUN", "false"),
            match_existing_cards=_flag("MATCH_EXISTING_CARDS", "true"),
            max_match_candidates=int(_optional("MAX_MATCH_CANDIDATES", "20")),
            max_new_cards_per_run=int(_optional("MAX_NEW_CARDS_PER_RUN", "25")),
            max_audits_per_run=int(_optional("MAX_AUDITS_PER_RUN", "15")),
            vision_enabled=_flag("VISION_ENABLED", "true"),
            max_images_per_audit=int(_optional("MAX_IMAGES_PER_AUDIT", "4")),
            max_image_bytes=int(_optional("MAX_IMAGE_BYTES", "8000000")),
            reaudit_image_blocked=_flag("REAUDIT_IMAGE_BLOCKED", "true"),
            max_reaudits_per_run=int(_optional("MAX_REAUDITS_PER_RUN", "10")),
            audit_board_cards=_flag("AUDIT_BOARD_CARDS", "true"),
            max_board_audits_per_run=int(
                _optional("MAX_BOARD_AUDITS_PER_RUN", "10")
            ),
        )
