import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

/// The palette and wording the Requests tab uses for a capture's `stage`.
///
/// Stage strings come from the orchestration layer (`LlmCaptureContext.stage`)
/// and are open-ended, so an unknown one falls back to the raw value rather
/// than being swallowed — a request nobody can name is exactly the one worth
/// seeing.
({String label, Color color}) requestStageLabel(
  BuildContext context,
  String? stage,
) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  Color pick(Color onDark, Color onLight) => dark ? onDark : onLight;
  final main = pick(const Color(0xFF7996CE), const Color(0xFF3F5C96));
  final aux = pick(const Color(0xFF4ADE80), const Color(0xFF16A34A));
  final agent = pick(const Color(0xFFC084FC), const Color(0xFF7C3AED));
  final neutral = pick(const Color(0xFFA9AAAB), const Color(0xFF6B6C6E));

  return switch (stage) {
    null || '' => (label: 'requests_stage_unknown'.tr(), color: neutral),
    'main' || 'chat' || 'generation' => (
      label: 'requests_stage_main'.tr(),
      color: main,
    ),
    'cleaner' || 'post_cleaner' => (
      label: 'requests_stage_cleaner'.tr(),
      color: aux,
    ),
    'ledger' => (label: 'requests_stage_ledger'.tr(), color: aux),
    'memory' || 'memory_writer' => (
      label: 'requests_stage_memory'.tr(),
      color: aux,
    ),
    'summary' || 'auto_summary' => (
      label: 'requests_stage_summary'.tr(),
      color: aux,
    ),
    _ => (label: stage, color: agent),
  };
}
