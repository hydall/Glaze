import 'package:easy_localization/easy_localization.dart';

import '../../extensions/models/extension_preset.dart';
import '../../extensions/models/extensions_settings.dart';
import 'magic_drawer_models.dart';

/// The status line under a Tools card — what the card's feature currently
/// holds for this chat. Shared by every surface the Tools tab is drawn on, so
/// they cannot disagree. [pluginsStatus] is the line of the Plugins card, read
/// by the caller (it follows a provider the caller watches).
String? magicDrawerStatusFor(
  String id,
  MagicDrawerStats stats, {
  required ExtensionsSettings extSettings,
  required List<ExtensionPreset> extPresets,
  String? pluginsStatus,
}) {
  return switch (id) {
    'inspector' =>
      stats.promptTokens > 0 && stats.contextSize > 0
          ? '${stats.promptTokens}/${stats.contextSize} tokens'
          : stats.approximateHistoryTokens > 0 && stats.contextSize > 0
          ? '~${stats.approximateHistoryTokens}/${stats.contextSize} tokens'
          : null,
    'memory' =>
      stats.summaryChars > 0
          ? '${stats.summaryChars} chars • ${stats.memoryEntryCount} entries'
          : '${stats.memoryEntryCount} entries',
    'sessions' => '${stats.sessionCount} sessions',
    'char-card' =>
      stats.characterTokens > 0
          ? '${stats.characterTokens} tokens'
          : stats.character?.name,
    'lorebooks' => '${stats.lorebookEntryCount} entries',
    'regex' => '${stats.regexCount} scripts',
    'api' =>
      stats.apiConfig?.name.isNotEmpty == true
          ? stats.apiConfig!.name
          : stats.apiConfig?.model,
    'presets' =>
      stats.activePresetDisplayName == null
          ? 'label_default'.tr()
          : stats.presetTokens > 0
          ? '${stats.activePresetDisplayName} • ${stats.presetTokens} tokens'
          : stats.activePresetDisplayName,
    'personas' => stats.activePersona?.name ?? 'label_default'.tr(),
    'image-gen' => stats.imageGenEnabled ? 'on'.tr() : 'off'.tr(),
    'authors-note' =>
      stats.session?.authorsNote != null &&
              stats.session!.authorsNote!.content.isNotEmpty
          ? '${stats.session!.authorsNote!.content.length} chars'
          : 'placeholder_empty'.tr(),
    'ext-blocks' =>
      extSettings.activePresetId == null
          ? 'No preset'
          : extPresets
                    .where((p) => p.id == extSettings.activePresetId)
                    .firstOrNull
                    ?.name ??
                'No preset',
    'plugins' => pluginsStatus,
    _ => null,
  };
}

/// The Plugins card's line: how many installed plugins are on.
String? pluginsDrawerStatus(List<({bool enabled})>? plugins) {
  if (plugins == null) return null;
  return 'plugins_drawer_status'.tr(
    namedArgs: {
      'on': '${plugins.where((x) => x.enabled).length}',
      'total': '${plugins.length}',
    },
  );
}
