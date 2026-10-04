"""The only agentic part of the pipeline.

A DeepSeek-backed Pydantic AI agent gets two read-only tools to explore the
checked-out repo (ripgrep search + file read) and must return a *structured*
audit. It never edits code, never opens PRs — the orchestrator only posts its
output as a Trello comment for a human to act on.

One report is audited per agent run: title, description and follow-up messages
travel together, but reports are never mixed.

Two agents can be built from here, differing only in the model and in what the
system prompt promises about eyesight:

  * the text agent (`DEEPSEEK_MODEL`, e.g. `deepseek-chat`) — cheaper, used for
    reports that carry no pictures;
  * the vision agent (`DEEPSEEK_VISION_MODEL`, default
    `deepseek-v4-flash-vision-exp`) — gets the screenshots as image parts
    alongside the text, and is used whenever a report has any.

Both keep the same tools and the same structured output, so a caller can swap
one for the other — which is exactly what happens when a vision call fails and
the run falls back to text rather than losing the report.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Literal, Sequence

from pydantic import BaseModel, Field
from pydantic_ai import Agent, BinaryContent, PromptedOutput
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider

from images import LoadedImage

# The tree the agent is allowed to grep and read. Defaults to this checkout
# (two levels up from tools/bug_triage/auditor.py); CI points AUDIT_REPO_ROOT at
# a separate nightly checkout, so a scheduled run started from stable still
# judges reports against current code rather than a months-old tree.
REPO_ROOT = Path(
    os.environ.get("AUDIT_REPO_ROOT") or Path(__file__).resolve().parents[2]
).resolve()

_MAX_FILE_BYTES = 40_000
_MAX_RG_MATCHES = 60

_BASE_PROMPT = """\
You are a bug-triage engineer for Glaze, a Flutter (Dart) LLM roleplay frontend.
You receive ONE bug report at a time: its title, the original description, and
any follow-up messages (Discord replies or Trello comments). Judge them together
— a follow-up often carries the repro steps or the correction that the title
alone is missing.

Your job: investigate the CURRENT source code using the `search_code` and
`read_file` tools, then produce a structured audit. Rules:
- Only claim something is a bug if the code actually supports it. If you cannot
  reproduce the cause from the code, say so and set confidence low.
- Prefer concrete file:line references over vague statements.
- Propose a fix as a description, NOT as a patch. Do not invent files.
- Be concise. A human will read this in a Trello comment.
"""

# Appended when the report has no pictures, or the model cannot see them.
_TEXT_TAIL = """\
You CANNOT see images. When a report leans on screenshots, or the text is too
vague to tell what actually went wrong, set `needs_more_info` to true and put
the specific questions a human should ask in `missing_info`. Never guess the
contents of an attachment, and never invent repro steps that were not reported.
"""

# Appended when the screenshots themselves are attached to the message.
_VISION_TAIL = """\
The report's images are attached to this message — LOOK AT THEM. They are
usually screenshots of the app, an error dialog, a stack trace or a log. Read
the text in them, note which screen is shown and what state the UI is in, and
treat that as part of the report: a screenshot of an exception is a repro
detail, not a decoration.

Write what you actually saw into `image_findings` — one short line per image,
quoting any error text verbatim. If an image is unreadable, irrelevant or shows
nothing about the bug, say that instead; never describe an image you were not
given, and never soften a blank screenshot into a guess.

Only set `needs_more_info` when the text AND the images together still leave you
unable to tell what went wrong — with the pictures in hand that should be rare.
Put the specific questions a human should ask in `missing_info`, and never
invent repro steps that were not reported or shown.
"""


class BugAudit(BaseModel):
    is_actionable: bool = Field(
        description="True if this is a real, reproducible bug worth fixing."
    )
    severity: Literal["low", "medium", "high", "critical", "unknown"]
    summary: str = Field(description="One-paragraph restatement of the bug.")
    root_cause: str = Field(
        description="Suspected cause with file:line refs, or why it's unclear."
    )
    proposed_fix: str = Field(description="Fix direction in prose, no code patch.")
    relevant_files: list[str] = Field(default_factory=list)
    confidence: Literal["low", "medium", "high"]
    needs_more_info: bool = Field(
        default=False,
        description=(
            "True when the report cannot be judged from text alone — e.g. it "
            "relies on screenshots you cannot see, or lacks repro steps."
        ),
    )
    missing_info: str = Field(
        default="",
        description="What exactly to ask the reporter, when needs_more_info is true.",
    )
    notes: str = Field(default="", description="Anything a human should double-check.")
    image_findings: str = Field(
        default="",
        description=(
            "What the attached images actually show — one short line per image, "
            "error text quoted verbatim. Empty when no images were attached."
        ),
    )


def _safe_path(rel: str) -> Path | None:
    """Resolve a user-supplied path and confine it inside the repo."""
    p = (REPO_ROOT / rel).resolve()
    try:
        p.relative_to(REPO_ROOT)
    except ValueError:
        return None
    return p


def build_agent(
    api_key: str, base_url: str, model_name: str, can_see_images: bool = False
) -> Agent[None, BugAudit]:
    """An audit agent over `model_name`.

    `can_see_images` only changes the system prompt — telling a blind model to
    look at attachments produces confident fiction, and telling a vision model
    it cannot see makes it ignore the screenshot it was just handed.
    """
    model = OpenAIChatModel(
        model_name,
        provider=OpenAIProvider(base_url=base_url, api_key=api_key),
    )
    agent: Agent[None, BugAudit] = Agent(
        model,
        # PromptedOutput, not the default forced output tool: DeepSeek's
        # thinking models reject `tool_choice` pinned to a specific tool
        # ("Thinking mode does not support this tool_choice", HTTP 400). Asking
        # for the JSON in the prompt keeps `search_code` / `read_file` as
        # ordinary optional tools, which those models do accept.
        output_type=PromptedOutput(BugAudit),
        system_prompt=_BASE_PROMPT + (_VISION_TAIL if can_see_images else _TEXT_TAIL),
        retries=2,
    )

    @agent.tool_plain
    def search_code(pattern: str) -> str:
        """Regex-search the repo (ripgrep). Returns matching `path:line: text`."""
        try:
            out = subprocess.run(
                ["rg", "--line-number", "--no-heading", "--max-count", "20",
                 "--glob", "!**/*.g.dart", "--glob", "!**/*.freezed.dart",
                 pattern],
                cwd=REPO_ROOT, capture_output=True, text=True, timeout=30,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired) as e:
            return f"search unavailable: {e}"
        lines = out.stdout.splitlines()
        if not lines:
            return "no matches"
        return "\n".join(lines[:_MAX_RG_MATCHES])

    @agent.tool_plain
    def read_file(path: str) -> str:
        """Read a repo file (relative path). Truncated to 40KB."""
        p = _safe_path(path)
        if p is None or not p.is_file():
            return f"not found or outside repo: {path}"
        data = p.read_text(encoding="utf-8", errors="replace")
        if len(data) > _MAX_FILE_BYTES:
            return data[:_MAX_FILE_BYTES] + "\n... [truncated]"
        return data

    return agent


def run(
    agent: Agent[None, BugAudit],
    report: str,
    images: Sequence[LoadedImage] = (),
) -> BugAudit:
    """Audit one report, with its pictures attached as image parts.

    Pydantic AI takes a list as the user prompt: the text first, then one
    `BinaryContent` per image, which the OpenAI-compatible client turns into the
    base64 data URLs DeepSeek's vision endpoint expects.
    """
    prompt: list[str | BinaryContent] = [report]
    prompt += [
        BinaryContent(data=img.data, media_type=img.media_type) for img in images
    ]
    return agent.run_sync(prompt).output
