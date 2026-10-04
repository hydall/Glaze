import 'package:easy_localization/easy_localization.dart';

/// Localized label for a raw DataCat extraction phase.
///
/// DataCat's `/api/extraction/status` reports bare identifiers (`dispatching`,
/// `pulling`, `post_extract`, …). The identifiers and their English wording are
/// DataCat's own — the same set `resolveExtractionStageLabel` in datacat.run's
/// bundle renders — so Glaze does not invent stages the server cannot send.
/// Anything not in that set is left as the raw value rather than dropped, so a
/// new phase still shows up (just untranslated) instead of blanking the label.
String datacatPhaseLabel(String? phase) {
  final raw = phase?.trim() ?? '';
  if (raw.isEmpty) return '';
  return _keys.contains(raw.toLowerCase())
      ? 'datacat_phase_${raw.toLowerCase()}'.tr()
      : raw;
}

/// Every phase identifier DataCat's extraction UI knows, lower-cased.
const _keys = <String>{
  'queued',
  'preparing',
  'initiating',
  'dispatching',
  'pulling',
  'running',
  'complete',
  'completed',
  'failed',
  'error',
  'partial',
  'skipped',
  'scoring',
  'creator_profile',
  'finalizing',
  'post_extract',
  'parse',
  'wait',
  'reload',
  'favorites',
  'generating',
  'starting',
  'retrieving',
  'opening_page',
  'recovering',
};
