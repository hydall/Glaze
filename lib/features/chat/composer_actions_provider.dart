import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/shared_prefs_provider.dart';

/// One of the circular buttons in the row under the chat composer.
///
/// The set is closed: every entry is wired to a concrete callback in
/// [ChatInputBar], so users pick *which* of these show and in what order, not
/// what a button does. Ids are persisted, so never rename an enum value —
/// add a new one and drop the old id in [ComposerActionsNotifier._decode].
enum ComposerAction {
  /// Opens the Tools / Actions drawer. Never offered on desktop, where the
  /// drawer lives in the right sidebar instead.
  drawer('drawer', Icons.auto_awesome, 'composer_action_drawer'),

  /// Attaches an image to the next message.
  attach('attach', Icons.attach_file, 'composer_action_attach'),

  /// Opens the fullscreen composer.
  fullscreen('fullscreen', Icons.fullscreen, 'composer_action_fullscreen'),

  /// Toggles the guidance field (the steering note sent alongside the reply).
  guidance('guidance', Icons.north_east, 'composer_action_guidance');

  final String id;
  final IconData icon;
  final String labelKey;

  const ComposerAction(this.id, this.icon, this.labelKey);

  String get label => labelKey.tr();

  static ComposerAction? byId(String id) {
    for (final action in values) {
      if (action.id == id) return action;
    }
    return null;
  }
}

/// The row as shipped: everything on, in the order the buttons had before the
/// row became configurable.
const List<ComposerAction> kDefaultComposerActions = ComposerAction.values;

/// Which composer buttons are shown, in display order.
///
/// Persisted as a list of ids rather than a per-action flag map: order is half
/// the setting, and a list carries both halves at once. An action missing from
/// the stored list is hidden; an action added in a later release is appended,
/// so an upgrade never silently withholds a new button.
class ComposerActionsNotifier extends AsyncNotifier<List<ComposerAction>> {
  static const storageKey = 'composer_actions_v1';

  @override
  Future<List<ComposerAction>> build() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final saved = prefs.getStringList(storageKey);
    if (saved == null) return List<ComposerAction>.from(kDefaultComposerActions);
    return _decode(saved);
  }

  /// Stored ids -> actions, dropping ids this build no longer knows.
  ///
  /// An empty result is honoured: hiding every button is a legitimate choice
  /// (the send button is not part of this row and stays), and silently
  /// restoring the defaults would make the setting look broken.
  static List<ComposerAction> _decode(List<String> ids) {
    final out = <ComposerAction>[];
    for (final id in ids) {
      final action = ComposerAction.byId(id);
      if (action != null && !out.contains(action)) out.add(action);
    }
    return out;
  }

  Future<void> _persist(List<ComposerAction> next) async {
    state = AsyncData(next);
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setStringList(storageKey, [for (final a in next) a.id]);
  }

  /// Shows or hides one button, keeping the rest of the order intact. A newly
  /// enabled button lands in its canonical position rather than at the end, so
  /// toggling one off and back on does not reshuffle the row.
  Future<void> setEnabled(ComposerAction action, bool enabled) async {
    final current = state.value ?? const <ComposerAction>[];
    if (current.contains(action) == enabled) return;
    final next = enabled
        ? _insertCanonically(current, action)
        : current.where((a) => a != action).toList();
    await _persist(next);
  }

  static List<ComposerAction> _insertCanonically(
    List<ComposerAction> current,
    ComposerAction action,
  ) {
    final next = List<ComposerAction>.from(current);
    final index = next.indexWhere((a) => a.index > action.index);
    next.insert(index < 0 ? next.length : index, action);
    return next;
  }

  Future<void> reorder(int from, int to) async {
    final current = state.value ?? const <ComposerAction>[];
    if (from < 0 || to < 0 || from >= current.length || to >= current.length) {
      return;
    }
    final next = List<ComposerAction>.from(current);
    next.insert(to, next.removeAt(from));
    await _persist(next);
  }

  Future<void> reset() =>
      _persist(List<ComposerAction>.from(kDefaultComposerActions));
}

final composerActionsProvider =
    AsyncNotifierProvider<ComposerActionsNotifier, List<ComposerAction>>(
      ComposerActionsNotifier.new,
    );
