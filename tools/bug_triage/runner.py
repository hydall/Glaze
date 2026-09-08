"""Audit one subject: fetch its pictures, pick a model, render the comment.

This is where "the triage agent can now read screenshots" actually happens. The
orchestrator hands over an `AuditSubject` and gets back the text to post; which
model ran, whether the images made it, and what to do when the vision call falls
over are all decided here.

Model choice is mechanical:
  * pictures loaded  -> the vision model, with them attached;
  * no pictures      -> the cheaper text model, exactly as before;
  * vision call fails -> retry once on the text model, so an experimental
    endpoint having a bad day costs a weaker audit, not a lost report.

Both agents are built lazily and reused for the whole run: a batch of text-only
reports never constructs the vision agent, and a batch of screenshots never
constructs the text one.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass

import audit_comment
from auditor import BugAudit, build_agent, run
from config import Config
from images import ImageLoader, LoadedImage
from subjects import AuditSubject

# Below this much readable text, and with no picture to look at, a report cannot
# be audited at all — so we skip the LLM entirely and ask a human instead.
_MIN_REPORT_CHARS = 15


@dataclass(frozen=True)
class AuditResult:
    comment: str  # ready to post on the card
    mode: str  # "vision" / "text" / "none"
    images: int  # how many pictures the model actually received
    needs_more_info: bool


class AuditRunner:
    def __init__(self, cfg: Config, loader: ImageLoader):
        self._cfg = cfg
        self._loader = loader
        self._text = None
        self._vision = None

    def _text_agent(self):
        if self._text is None:
            print(f"[audit] using text model {self._cfg.deepseek_model}")
            self._text = build_agent(
                self._cfg.deepseek_api_key,
                self._cfg.deepseek_base_url,
                self._cfg.deepseek_model,
                can_see_images=False,
            )
        return self._text

    def _vision_agent(self):
        if self._vision is None:
            print(f"[audit] using vision model {self._cfg.deepseek_vision_model}")
            self._vision = build_agent(
                self._cfg.deepseek_api_key,
                self._cfg.deepseek_base_url,
                self._cfg.deepseek_vision_model,
                can_see_images=True,
            )
        return self._vision

    def _load_images(self, subject: AuditSubject) -> list[LoadedImage]:
        if not subject.images:
            return []
        if not self._cfg.vision_enabled:
            print(f"[audit] {subject.key}: {len(subject.images)} image(s) ignored "
                  f"(VISION_ENABLED=false)")
            return []
        got = self._loader.load(
            list(subject.images), self._cfg.max_images_per_audit
        )
        print(f"[audit] {subject.key}: {len(got)}/{len(subject.images)} image(s) "
              f"loaded for the model")
        return got

    def audit(self, subject: AuditSubject) -> AuditResult:
        """Audit one report. Raises only if every model attempt failed."""
        images = self._load_images(subject)

        # Nothing to read and nothing to look at -> ask a human, spend nothing.
        if not images and len(subject.text) < _MIN_REPORT_CHARS:
            return AuditResult(
                comment=audit_comment.unreadable(
                    subject.source_url, len(subject.images)
                ),
                mode="none",
                images=0,
                needs_more_info=True,
            )

        report = subject.report([img.ref for img in images])

        if images:
            try:
                out = run(self._vision_agent(), report, images)
                return self._result(out, subject, "vision", images)
            except Exception as e:  # noqa: BLE001 — fall back, don't lose the card
                print(f"[audit] vision call FAILED for {subject.key}: {e} — "
                      f"retrying on {self._cfg.deepseek_model} without images",
                      file=sys.stderr)
                report = subject.report()

        out = run(self._text_agent(), report, ())
        return self._result(out, subject, "text", [])

    def _result(
        self,
        audit: BugAudit,
        subject: AuditSubject,
        mode: str,
        images: list[LoadedImage],
    ) -> AuditResult:
        return AuditResult(
            comment=audit_comment.render(
                audit, subject.source_url, mode, [i.ref for i in images]
            ),
            mode=mode,
            images=len(images),
            needs_more_info=audit.needs_more_info,
        )
