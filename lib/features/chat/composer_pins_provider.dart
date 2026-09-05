import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/shared_prefs_provider.dart';

/// A button the composer itself owns, because its effect lands on the composer
/// rather than on the chat: the drawer toggle, the image attachment, the
/// fullscreen editor and the guidance field.
///
/// Ids are persisted, so never rename an enum value — add a new one and let
/// [ComposerPin.decode] drop the old id.
enum ComposerAction {
  /// Opens the Tools / Actions drawer. Never offered on desktop, where the
  /// drawer lives in the right sidebar instead.
  drawer('drawer', Icons.auto_awesome, 'composer_action_drawer'),

  /// Attaches an image to the next message.
  attach('attach', Icons.attach_file, 'composer_action_attach'),

  /// Attaches whatever image is on the clipboard. Ctrl/Cmd+V does the same
  /// thing from the keyboard; this is the way in on touch, where there is no
  /// paste shortcut to press.
  paste('paste', Icons.content_paste, 'composer_action_paste'),

  /// Opens the fullscreen composer.
  fullscreen('fullscreen', Icons.fullscreen, 'composer_action_fullscreen'),

  /// Toggles the guidance field (the steering note sent alongside the reply).
  guidance('guidance', Icons.north_east, 'composer_action_guidance');

  final String id;
  final IconData icon;
  final String labelKey;

  const ComposerAction(this.id, this.icon, this.labelKey);

  String get label => labelKey.tr();

  /// The drawer toggle is the only way *into* the drawer, so it has no card to
  /// be demoted onto and never leaves the pinned row. Everything else has a
  /// home in the Actions tab and can move both ways.
  bool get isPermanent => this == ComposerAction.drawer;

  /// Actions that appear as cards in the drawer's Actions tab while unpinned.
  static Iterable<ComposerAction> get demotable =>
      values.where((a) => !a.isPermanent);

  static ComposerAction? byId(String id) {
    for (final action in values) {
      if (action.id == id) return action;
    }
    return null;
  }
}

/// Which half of the app a pinned button borrows its behaviour from.
enum ComposerPinKind {
  /// A [ComposerAction] — the composer runs it itself.
  action,

  /// A quick reply from the drawer's Actions tab, by [QuickReply.id].
  reply,

  /// A card from the drawer's Tools tab, by `MagicDrawerItemDef.id`.
  tool,
}

/// One button in the row under the composer.
///
/// The row used to hold [ComposerAction]s alone, configured from a settings
/// sheet. It now holds anything the drawer holds, and is configured from the
/// drawer itself: the up-arrow badge on a card pins it here, the down-arrow
/// badge on a button sends it back. A pinned item is filtered out of its
/// drawer tab, so nothing is ever offered in both places at once.
@immutable
class ComposerPin {
  final ComposerPinKind kind;

  /// Identifies the thing inside [kind] — an action id, a quick-reply id or a
  /// drawer item id.
  final String refId;

  const ComposerPin({required this.kind, required this.refId});

  factory ComposerPin.action(ComposerAction action) =>
      ComposerPin(kind: ComposerPinKind.action, refId: action.id);

  factory ComposerPin.reply(String replyId) =>
      ComposerPin(kind: ComposerPinKind.reply, refId: replyId);

  factory ComposerPin.tool(String itemId) =>
      ComposerPin(kind: ComposerPinKind.tool, refId: itemId);

  /// The action this pin runs, or null when it is a reply or a tool.
  ComposerAction? get asAction =>
      kind == ComposerPinKind.action ? ComposerAction.byId(refId) : null;

  /// True for a pin that must stay in the row — see [ComposerAction.isPermanent].
  bool get isPermanent => asAction?.isPermanent ?? false;

  String encode() => '${kind.name}:$refId';

  /// Parses a stored id, or null when this build cannot honour it.
  ///
  /// A payload with no separator is a `composer_actions_v1` entry from before
  /// the row could hold anything but actions; those were bare action ids.
  static ComposerPin? decode(String raw) {
    final separator = raw.indexOf(':');
    if (separator < 0) {
      final action = ComposerAction.byId(raw);
      return action == null ? null : ComposerPin.action(action);
    }
    final name = raw.substring(0, separator);
    final refId = raw.substring(separator + 1);
    if (refId.isEmpty) return null;
    for (final kind in ComposerPinKind.values) {
      if (kind.name != name) continue;
      if (kind == ComposerPinKind.action && ComposerAction.byId(refId) == null) {
        return null;
      }
      return ComposerPin(kind: kind, refId: refId);
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is ComposerPin && other.kind == kind && other.refId == refId;

  @override
  int get hashCode => Object.hash(kind, refId);

  @override
  String toString() => encode();
}

/// Actions that ship unpinned: they start as cards in the drawer's Actions tab
/// and only reach the row if the user puts them there.
const Set<ComposerAction> _unpinnedByDefault = {ComposerAction.paste};

/// The row as shipped: the four composer actions, in the order the buttons had
/// before the row became configurable.
final List<ComposerPin> kDefaultComposerPins = [
  for (final action in ComposerAction.values)
    if (!_unpinnedByDefault.contains(action)) ComposerPin.action(action),
];

/// Which buttons sit under the composer, in display order.
///
/// Persisted as a list of encoded ids rather than a per-item flag map: order is
/// half the setting, and a list carries both halves at once. An entry this
/// build no longer understands is dropped; a quick reply or tool that has since
/// been deleted resolves to nothing and is skipped when the row is built, so a
/// stale pin costs a slot at worst and never a crash.
class ComposerPinsNotifier extends AsyncNotifier<List<ComposerPin>> {
  static const storageKey = 'composer_pins_v1';

  /// The pre-mixed-row key, holding bare [ComposerAction] ids. Read once as a
  /// fallback so an upgrade keeps the row the user had.
  static const legacyStorageKey = 'composer_actions_v1';

  @override
  Future<List<ComposerPin>> build() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final saved =
        prefs.getStringList(storageKey) ?? prefs.getStringList(legacyStorageKey);
    if (saved == null) return List<ComposerPin>.from(kDefaultComposerPins);
    return _withPermanents(decodeAll(saved));
  }

  /// Stored ids -> pins, dropping ids this build cannot parse and duplicates.
  ///
  /// An otherwise empty result is honoured: pinning nothing but the permanent
  /// buttons is a legitimate choice, and silently restoring the defaults would
  /// make the drawer's down-arrow look broken.
  static List<ComposerPin> decodeAll(List<String> ids) {
    final out = <ComposerPin>[];
    for (final id in ids) {
      final pin = ComposerPin.decode(id);
      if (pin != null && !out.contains(pin)) out.add(pin);
    }
    return out;
  }

  /// Re-inserts any permanent action missing from a stored list.
  ///
  /// The old settings sheet let the drawer button be switched off, and the
  /// switch is gone — without this, those users would be left with no way to
  /// open the drawer and no way to get the button back.
  static List<ComposerPin> _withPermanents(List<ComposerPin> pins) {
    final missing = [
      for (final action in ComposerAction.values)
        if (action.isPermanent && !pins.contains(ComposerPin.action(action)))
          ComposerPin.action(action),
    ];
    return missing.isEmpty ? pins : [...missing, ...pins];
  }

  Future<void> _persist(List<ComposerPin> next) async {
    state = AsyncData(next);
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setStringList(storageKey, [for (final p in next) p.encode()]);
  }

  /// Moves an item out of its drawer tab and into the row, at the end.
  Future<void> pin(ComposerPin pin) async {
    final current = state.value ?? const <ComposerPin>[];
    if (current.contains(pin)) return;
    await _persist([...current, pin]);
  }

  /// Same, but landing at [index] — where a card dropped onto the row goes, so
  /// the button appears under the finger rather than at the far end of a row
  /// the user may not even be able to see the end of. An index past the end
  /// appends; a pin that is already up here is a no-op, since that gesture is
  /// a [reorder].
  Future<void> pinAt(ComposerPin pin, int index) async {
    final current = state.value ?? const <ComposerPin>[];
    if (current.contains(pin)) return;
    final next = List<ComposerPin>.from(current);
    next.insert(index.clamp(0, next.length), pin);
    await _persist(next);
  }

  /// Sends a button back to its tab. Permanent buttons ignore the call — the
  /// UI hides their badge, and this is the backstop.
  Future<void> unpin(ComposerPin pin) async {
    final current = state.value ?? const <ComposerPin>[];
    if (pin.isPermanent || !current.contains(pin)) return;
    await _persist(current.where((p) => p != pin).toList());
  }

  Future<void> reorder(int from, int to) async {
    final current = state.value ?? const <ComposerPin>[];
    if (from < 0 || to < 0 || from >= current.length || to >= current.length) {
      return;
    }
    if (from == to) return;
    final next = List<ComposerPin>.from(current);
    next.insert(to, next.removeAt(from));
    await _persist(next);
  }

  Future<void> reset() =>
      _persist(List<ComposerPin>.from(kDefaultComposerPins));
}

final composerPinsProvider =
    AsyncNotifierProvider<ComposerPinsNotifier, List<ComposerPin>>(
      ComposerPinsNotifier.new,
    );

/// Lets the drawer run a [ComposerAction] whose card it is showing.
///
/// Attach / fullscreen / guidance act on the composer's own controllers, which
/// only [ChatInputBar] holds. The composer registers itself here on mount; the
/// Actions tab looks the handler up when one of those cards is tapped. A plain
/// holder rather than notifier state because nothing rebuilds on it — the
/// composer is always mounted whenever the drawer is open.
class ComposerActionBridge {
  void Function(ComposerAction action)? _run;

  void register(void Function(ComposerAction action) run) => _run = run;

  /// Identity-checked so a composer that is being replaced (a session switch
  /// re-keys [ChatInputBar]) cannot unregister its successor.
  void unregister(void Function(ComposerAction action) run) {
    if (identical(_run, run)) _run = null;
  }

  bool get isAvailable => _run != null;

  void run(ComposerAction action) => _run?.call(action);
}

final composerActionBridgeProvider = Provider<ComposerActionBridge>(
  (ref) => ComposerActionBridge(),
);
