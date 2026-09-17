import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/block_config.dart';
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

  /// Whether a block without a stored row belongs in this message's panel as a
  /// `pending` placeholder.
  ///
  /// The panel hangs under an assistant message and runs the `afterAssistant`
  /// set, so only those blocks can ever fill a placeholder here. An
  /// `afterUser` block stores its result under the user message (deliberately
  /// panel-less), a `periodic` block stores nothing at all, and `rewrite` /
  /// `accumulation` blocks have no runtime yet — listing them would leave a row
  /// stuck on "pending" forever, with a run button that either re-binds the
  /// block to the wrong message or writes an error card.
  static bool _canPlaceholder(BlockConfig cfg) =>
      cfg.trigger == BlockTrigger.afterAssistant && cfg.type.isRunnable;

  /// Merges enabled preset blocks with DB rows. A block that can run here but
  /// has no row yet becomes `pending`.
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
        if (dbByBlockId[cfg.id] != null)
          {...dbByBlockId[cfg.id]!.toMap(), 'manualOnly': cfg.manualOnly}
        else if (_canPlaceholder(cfg))
          {
            'blockId': cfg.id,
            'blockName': cfg.name,
            'type': cfg.type.name,
            'status': 'pending',
            'content': '',
            'order': cfg.order,
            'manualOnly': cfg.manualOnly,
          },
    ];
  }

  /// Whether the panel's "run all" control has anything to do: a block the
  /// automatic `afterAssistant` chain would run is not finished. Manual-only
  /// blocks are excluded — Run All never runs them, so a panel holding nothing
  /// but a manual placeholder would offer a button that does nothing.
  static bool canRunAll(List<Map<String, dynamic>> blocks) {
    return blocks.any((b) {
      if (b['manualOnly'] == true) return false;
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
