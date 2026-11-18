import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../core/models/agent_binding.dart';
import '../../core/models/agent_definition.dart';

String agentPhaseLabel(String phase) => switch (phase) {
  AgentPhase.parallel => 'agents_phase_parallel'.tr(),
  AgentPhase.postProcessing => 'agents_phase_post'.tr(),
  _ => 'agents_phase_pre'.tr(),
};

String agentPhaseHint(String phase) => switch (phase) {
  AgentPhase.parallel => 'agents_phase_parallel_hint'.tr(),
  AgentPhase.postProcessing => 'agents_phase_post_hint'.tr(),
  _ => 'agents_phase_pre_hint'.tr(),
};

IconData agentPhaseIcon(String phase) => switch (phase) {
  AgentPhase.parallel => Icons.call_split,
  AgentPhase.postProcessing => Icons.fact_check_outlined,
  _ => Icons.lightbulb_outline,
};

String agentResultLabel(String resultType) => switch (resultType) {
  AgentResultType.textRewrite => 'agents_result_rewrite'.tr(),
  AgentResultType.ledgerUpdate => 'agents_result_ledger'.tr(),
  AgentResultType.cardUpdateProposal => 'agents_result_card'.tr(),
  _ => 'agents_result_context'.tr(),
};

String agentConnectionLabel(String mode) => switch (mode) {
  AgentConnectionMode.helper => 'agents_connection_helper'.tr(),
  AgentConnectionMode.config => 'agents_connection_config'.tr(),
  _ => 'agents_connection_chat'.tr(),
};

String agentPlacementLabel(String placement) => switch (placement) {
  AgentPlacement.beforeMain => 'agents_place_before'.tr(),
  AgentPlacement.afterMain => 'agents_place_after'.tr(),
  AgentPlacement.macroOnly => 'agents_place_macro'.tr(),
  _ => 'agents_place_depth'.tr(),
};

String agentSourceLabel(AgentStateSource source) => switch (source) {
  AgentStateSource.chat => 'agents_source_chat'.tr(),
  AgentStateSource.character => 'agents_source_character'.tr(),
  AgentStateSource.global => 'agents_source_global'.tr(),
};

/// Requests one agent adds to a reply, averaged over its cadence.
double agentRequestsPerReply(AgentDefinition agent) {
  final everyN = agent.cadence.everyN < 1 ? 1 : agent.cadence.everyN;
  return 1 / everyN;
}

/// "+1.5" style count for the cost badge.
String formatRequestCount(double value) {
  final rounded = (value * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(1);
}
