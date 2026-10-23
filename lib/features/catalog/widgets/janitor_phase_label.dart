import 'package:easy_localization/easy_localization.dart';

/// Localized label for a raw JanitorAI capture / import phase.
///
/// The extractor and the WebView proxy report bare English identifiers
/// (`configuring proxy`, `triggering (card)`, …) meant for the log. Shown as-is
/// they read as jargon, so the UI maps them onto a few plain steps. The split
/// passes carry their `pass N/M` counter along. Anything not known here is left
/// raw rather than dropped, so a new phase still shows up.
String janitorPhaseLabel(String? phase) {
  final raw = phase?.trim() ?? '';
  if (raw.isEmpty) return '';
  final pass = _passPattern.firstMatch(raw);
  if (pass != null) {
    return 'janitor_phase_trigger_pass'.tr(args: [pass[1]!, pass[2]!]);
  }
  final key = _keys[raw];
  return key == null ? raw : key.tr();
}

final _passPattern = RegExp(r'^triggering \(lorebook, pass (\d+)/(\d+)\)$');

const _keys = <String, String>{
  'fetching metadata': 'janitor_phase_metadata',
  'loading tokenizer': 'janitor_phase_preparing',
  'starting': 'janitor_phase_preparing',
  'configuring proxy': 'janitor_phase_account',
  'checking profile': 'janitor_phase_account',
  'preparing persona': 'janitor_phase_account',
  'creating chat': 'janitor_phase_chat',
  'opening chat': 'janitor_phase_chat',
  'reloading for preset': 'janitor_phase_chat',
  'waiting for chat UI': 'janitor_phase_chat',
  'triggering (card)': 'janitor_phase_card',
  'triggering (lorebook)': 'janitor_phase_trigger',
  'captured': 'janitor_phase_captured',
  'deleting chat': 'janitor_phase_cleanup',
  'restoring settings': 'janitor_phase_cleanup',
  'separating': 'janitor_phase_separating',
  'importing character': 'janitor_phase_saving_character',
  'rebuilding lorebook (LLM)': 'janitor_phase_building',
  'saving lorebook': 'janitor_phase_saving_lorebook',
};
