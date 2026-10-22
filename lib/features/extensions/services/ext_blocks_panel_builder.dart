import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/character_provider.dart';

import '../models/block_config.dart';
import '../models/block_run_status.dart';
import '../models/info_block.dart';
import '../providers/extension_presets_provider.dart';
import '../providers/extensions_settings_provider.dart';
import '../providers/info_blocks_provider.dart';
import 'card_blocks.dart';
import 'blocks/block_trigger_rules.dart';
import 'ext_blocks_inline_display.dart';

typedef ExtBlocksPanelKey = ({
  String? charId,
  String sessionId,
  String messageId,
  int swipeId,
  int agentSwipeId,
});

typedef ExtBlocksPanelVisibilityKey = ({
  String? charId,
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
    return settings.activePresetId != null &&
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
    String? charId,
  }) {
    if (!isAssistant || !extensionsActive(ref)) return false;
    // Never show the panel on greeting/first_mes messages that have no stored
    // blocks yet — they were not produced by the user's generation flow.
    if (isGreeting) return false;
    final blocks = build(
      ref,
      charId: charId,
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
  /// The panel hangs under an assistant message and runs the reply chain,
  /// so only those blocks can ever fill a placeholder here. A user-only block
  /// stores its result under the user message (deliberately panel-less), a
  /// `periodic` block stores nothing at all, a `rewrite` block changes the
  /// message instead of leaving a result, and an `accumulation` block stores
  /// state only under a message carrying its updater — listing them would
  /// leave a row stuck on "pending" forever,
  /// with a run button that either re-binds the block to the wrong message or
  /// writes an error card.
  ///
  /// A block gated by a keyword or by a period longer than one turn is
  /// expected to be missing from most replies, so its absence is not shown
  /// as pending either.
  static bool _canPlaceholder(BlockConfig cfg) =>
      cfg.runsOnChar &&
      cfg.type.isRunnable &&
      cfg.type.hasPanelResult &&
      cfg.keyword.isEmpty &&
      cfg.period <= 2;

  /// Merges enabled preset blocks with DB rows. A block that can run here but
  /// has no row yet becomes `pending`.
  static List<Map<String, dynamic>> build(
    Ref ref, {
    required String sessionId,
    required String messageId,
    required int swipeId,
    int agentSwipeId = -1,
    String? charId,
  }) {
    // The character's card blocks show here too, as they run.
    final preset = effectiveExtBlocksPreset(ref.read, charId);
    if (preset == null) return [];

    final dbBlocks = ref
        .read(infoBlocksProvider(sessionId).notifier)
        .getByMessageId(
          messageId,
          swipeId: swipeId,
          agentSwipeId: agentSwipeId,
        );
    final dbByBlockId = {for (final b in dbBlocks) b.blockId: b};

    // A block hidden from display still runs and injects; it only stays out
    // of the panel.
    final enabledConfigs =
        preset.blocks.where((b) => b.enabled && !b.hideDisplay).toList()
          ..sort((a, b) => a.order.compareTo(b.order));

    if (enabledConfigs.isEmpty) return [];

    return [
      for (final cfg in enabledConfigs)
        // A script runs for what it does, not for what it says: the original
        // displays nothing of it. One that finished without returning anything
        // has no row to show (a script drawn on the ExtBlocks page always
        // returns nothing). A failed or unfinished one keeps its row, where
        // the status and the retry control are.
        if (_isSilentScript(cfg, dbByBlockId[cfg.id]))
          ...const <Map<String, dynamic>>[]
        // A block shown inside the message leaves the panel once it is done;
        // while it runs, fails or waits, its row here is where that shows.
        else if (showsInMessage(cfg) &&
            dbByBlockId[cfg.id]?.status == BlockRunStatus.done)
          ...const <Map<String, dynamic>>[]
        else if (dbByBlockId[cfg.id] != null)
          {
            ...dbByBlockId[cfg.id]!.toMap(),
            if (cfg.type == BlockType.accumulation)
              'content': accumulationPanelHtml(dbByBlockId[cfg.id]!.content),
            'manualOnly': cfg.manualOnly,
          }
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

  /// A script block that finished without content: nothing to show, and no
  /// control that would act on it.
  static bool _isSilentScript(BlockConfig cfg, InfoBlock? row) =>
      cfg.type == BlockType.script &&
      row != null &&
      row.status == BlockRunStatus.done &&
      row.content.trim().isEmpty;

  /// Whether the panel's "run all" control has anything to do: a block the
  /// automatic `afterAssistant` chain would run is not finished. Manual-only
  /// blocks are excluded — Run All never runs them, so a panel holding nothing
  /// but a manual placeholder would offer a button that does nothing.
  /// An accumulation block's YAML state as the panel shows it: kept as
  /// written, line breaks and indentation included.
  @visibleForTesting
  static String accumulationPanelHtml(String yaml) {
    if (yaml.trim().isEmpty) return '';
    return '<pre class="ext-block-state">'
        '${const HtmlEscape(HtmlEscapeMode.element).convert(yaml)}</pre>';
  }

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
      if (key.charId != null) ref.watch(characterByIdProvider(key.charId!));
      return ExtBlocksPanelBuilder.build(
        ref,
        charId: key.charId,
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
      if (key.charId != null) ref.watch(characterByIdProvider(key.charId!));
      return ExtBlocksPanelBuilder.shouldShowPanel(
        ref,
        charId: key.charId,
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
