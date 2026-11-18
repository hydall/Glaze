import 'package:easy_localization/easy_localization.dart';

/// Localized label for a stage an agent script runs at (see
/// `studioRegexStages`). An unknown stage falls back to its raw value instead
/// of being mislabelled.
String agentRegexStageLabel(String stage) => switch (stage) {
  'pregen' => 'studio_point_pregen'.tr(),
  'specificAgent' => 'studio_point_specific_agent'.tr(),
  'final' => 'studio_point_final'.tr(),
  'output' => 'studio_point_output'.tr(),
  'cleaner' => 'studio_point_cleaner'.tr(),
  'ledger' => 'studio_point_ledger'.tr(),
  _ => stage,
};
