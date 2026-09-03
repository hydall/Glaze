import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../state/request_timeline.dart';

/// Colour per stage family, picked per brightness so the timeline reads the
/// same on a light preset as on a dark one.
Color requestFamilyColor(BuildContext context, RequestStageFamily family) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  Color pick(int onDark, int onLight) =>
      Color(dark ? onDark : onLight);
  return switch (family) {
    RequestStageFamily.main => pick(0xFF7996CE, 0xFF3F5C96),
    RequestStageFamily.agent => pick(0xFFC084FC, 0xFF7C3AED),
    RequestStageFamily.cleaner => pick(0xFF4ADE80, 0xFF16A34A),
    RequestStageFamily.ledger => pick(0xFF22D3EE, 0xFF0E7490),
    RequestStageFamily.memory => pick(0xFF60A5FA, 0xFF2563EB),
    RequestStageFamily.extBlock => pick(0xFFFBBF24, 0xFFB45309),
    RequestStageFamily.card => pick(0xFFF472B6, 0xFFBE185D),
    RequestStageFamily.summary => pick(0xFF94A3B8, 0xFF64748B),
    RequestStageFamily.embedding => pick(0xFF2DD4BF, 0xFF0F766E),
    RequestStageFamily.image => pick(0xFFFB7185, 0xFFBE123C),
    RequestStageFamily.other => pick(0xFFA9AAAB, 0xFF6B6C6E),
  };
}

String requestFamilyLabel(RequestStageFamily family) => switch (family) {
  RequestStageFamily.main => 'requests_stage_main'.tr(),
  RequestStageFamily.agent => 'requests_stage_agents'.tr(),
  RequestStageFamily.cleaner => 'requests_stage_cleaner'.tr(),
  RequestStageFamily.ledger => 'requests_stage_ledger'.tr(),
  RequestStageFamily.memory => 'requests_stage_memory'.tr(),
  RequestStageFamily.extBlock => 'requests_stage_extblock'.tr(),
  RequestStageFamily.card => 'requests_stage_card'.tr(),
  RequestStageFamily.summary => 'requests_stage_summary'.tr(),
  RequestStageFamily.embedding => 'requests_stage_embedding'.tr(),
  RequestStageFamily.image => 'requests_stage_image'.tr(),
  RequestStageFamily.other => 'requests_stage_unknown'.tr(),
};

IconData requestFamilyIcon(RequestStageFamily family) => switch (family) {
  RequestStageFamily.main => Icons.chat_bubble_outline_rounded,
  RequestStageFamily.agent => Icons.smart_toy_outlined,
  RequestStageFamily.cleaner => Icons.auto_fix_high_outlined,
  RequestStageFamily.ledger => Icons.receipt_long_outlined,
  RequestStageFamily.memory => Icons.psychology_alt_outlined,
  RequestStageFamily.extBlock => Icons.extension_outlined,
  RequestStageFamily.card => Icons.badge_outlined,
  RequestStageFamily.summary => Icons.notes_rounded,
  RequestStageFamily.embedding => Icons.scatter_plot_outlined,
  RequestStageFamily.image => Icons.image_outlined,
  RequestStageFamily.other => Icons.bolt_outlined,
};

/// The name of a single step inside a group: the agent that ran, or the part of
/// the stage after its family prefix (`ledger.turn_repair` → `turn_repair`).
/// The family is already on the group, so repeating it per row is noise.
String requestStepLabel({String? stage, String? agentId}) {
  if (agentId != null && agentId.isNotEmpty) return agentId;
  if (stage == null || stage.isEmpty) return 'requests_stage_unknown'.tr();
  final dot = stage.indexOf('.');
  return dot < 0 || dot == stage.length - 1 ? stage : stage.substring(dot + 1);
}

String formatRequestTime(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}:'
    '${time.second.toString().padLeft(2, '0')}';
