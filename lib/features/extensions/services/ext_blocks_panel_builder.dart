import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/extension_presets_provider.dart';
import '../providers/extensions_settings_provider.dart';
import '../providers/info_blocks_provider.dart';

typedef ExtBlocksPanelKey = ({
  String sessionId,
  String messageId,
  int swipeId,
  int agentSwipeId,
});

typedef ExtBlocksPanelVisibilityKey = ({
  String sessionId,
  String messageId,
  bool isAssistant,
  bool isLastAssistant,
  bool isGreeting,
  int swipeId,
  int agentSwipeId,
});

/// Builds WebView panel payloads by merging preset block definitions with
/// stored [InfoBlock] rows for a message.
class ExtBlocksPanelBuilder {
  const ExtBlocksPanelBuilder._();

  static bool extensionsActive(Ref ref) {
    final settings = ref.read(extensionsSettingsProvider);
    return settings.enabled &&
        settings.activePresetId != null &&
        settings.activePresetId!.isNotEmpty;
  }

  /// Whether the inline panel should be shown under [messageId].
  static bool shouldShowPanel(
    Ref ref, {
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    required bool isAssistant,
    required bool isLastAssistant,
    bool isGreeting = false,
  }) {
    if (!isAssistant || !extensionsActive(ref)) return false;
    // Never show the panel on greeting/first_mes messages that have no stored
    // blocks yet — they were not produced by the user's generation flow.
    if (isGreeting) return false;
    final blocks = build(
      ref,
      sessionId: sessionId,
      messageId: messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
    );
    if (blocks.isNotEmpty) return true;
    return isLastAssistant;
  }

  /// Merges enabled preset blocks with DB rows. Missing rows become `pending`.
  static List<Map<String, dynamic>> build(
    Ref ref, {
    required String sessionId,
    required String messageId,
    required int swipeId,
    int agentSwipeId = -1,
  }) {
    final settings = ref.read(extensionsSettingsProvider);
    if (!settings.enabled) return [];
    final presetId = settings.activePresetId;
    if (presetId == null || presetId.isEmpty) return [];

    final preset = ref
        .read(extensionPresetsProvider)
        .where((p) => p.id == presetId)
        .firstOrNull;
    if (preset == null) return [];

    final dbBlocks = ref
        .read(infoBlocksProvider(sessionId).notifier)
        .getByMessageId(messageId, swipeId: swipeId, agentSwipeId: agentSwipeId);
    final dbByBlockId = {for (final b in dbBlocks) b.blockId: b};

    final enabledConfigs = preset.blocks.where((b) => b.enabled).toList()
      ..sort((a, b) => a.order.compareTo(b.order));

    if (enabledConfigs.isEmpty) return [];

    return [
      for (final cfg in enabledConfigs)
        dbByBlockId[cfg.id]?.toMap() ??
            {
              'blockId': cfg.id,
              'blockName': cfg.name,
              'type': cfg.type.name,
              'status': 'pending',
              'content': '',
              'order': cfg.order,
            },
    ];
  }

  static bool canRunAll(List<Map<String, dynamic>> blocks) {
    return blocks.any((b) {
      final s = b['status'] as String? ?? '';
      return s == 'pending' || s == 'error' || s == 'stopped';
    });
  }
}

final extBlocksPanelBlocksProvider =
    Provider.family<List<Map<String, dynamic>>, ExtBlocksPanelKey>((ref, key) {
      ref.watch(infoBlocksProvider(key.sessionId));
      ref.watch(extensionsSettingsProvider);
      ref.watch(extensionPresetsProvider);
      return ExtBlocksPanelBuilder.build(
        ref,
        sessionId: key.sessionId,
        messageId: key.messageId,
        swipeId: key.swipeId,
        agentSwipeId: key.agentSwipeId,
      );
    });

final extBlocksPanelVisibleProvider =
    Provider.family<bool, ExtBlocksPanelVisibilityKey>((ref, key) {
      ref.watch(infoBlocksProvider(key.sessionId));
      ref.watch(extensionsSettingsProvider);
      ref.watch(extensionPresetsProvider);
      return ExtBlocksPanelBuilder.shouldShowPanel(
        ref,
        sessionId: key.sessionId,
        messageId: key.messageId,
        swipeId: key.swipeId,
        agentSwipeId: key.agentSwipeId,
        isAssistant: key.isAssistant,
        isLastAssistant: key.isLastAssistant,
        isGreeting: key.isGreeting,
      );
    });

final extBlocksPanelCanRunAllProvider =
    Provider.family<bool, ExtBlocksPanelKey>((ref, key) {
      final blocks = ref.watch(extBlocksPanelBlocksProvider(key));
      return ExtBlocksPanelBuilder.canRunAll(blocks);
    });
