import 'dart:async';
import 'dart:io' show Platform;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/haptics.dart';
import '../../core/state/character_provider.dart';
import '../../core/state/shared_prefs_provider.dart';
import '../../shared/widgets/glaze_toast.dart';

/// Keyboard shortcut that toggles hidden characters on desktop — the keyboard
/// twin of the triple tap on the "Characters" header title.
///
/// Stored in SharedPreferences under [_prefsKey] as `ctrl+shift+alt+meta+<id>`
/// (modifiers optional, `<id>` is the [LogicalKeyboardKey.keyId]), or `none`
/// when the user cleared it. Absent means [kDefaultRevealHiddenHotkey].
const _prefsKey = 'reveal_hidden_hotkey';
const _noneValue = 'none';

/// Ctrl+Shift+H — Cmd+Shift+H on macOS, where Ctrl+letter is not the norm.
SingleActivator get kDefaultRevealHiddenHotkey => SingleActivator(
  LogicalKeyboardKey.keyH,
  control: !_isMac,
  meta: _isMac,
  shift: true,
);

bool get _isMac => Platform.isMacOS;

String encodeHotkey(SingleActivator? a) {
  if (a == null) return _noneValue;
  return [
    if (a.control) 'ctrl',
    if (a.shift) 'shift',
    if (a.alt) 'alt',
    if (a.meta) 'meta',
    '${a.trigger.keyId}',
  ].join('+');
}

/// Parses [encodeHotkey]'s output. Returns the default for null or garbage,
/// and null for an explicitly cleared shortcut.
SingleActivator? decodeHotkey(String? raw) {
  if (raw == null) return kDefaultRevealHiddenHotkey;
  if (raw == _noneValue) return null;
  final parts = raw.split('+');
  final id = int.tryParse(parts.last);
  if (id == null) return kDefaultRevealHiddenHotkey;
  final mods = parts.sublist(0, parts.length - 1).toSet();
  return SingleActivator(
    LogicalKeyboardKey(id),
    control: mods.contains('ctrl'),
    shift: mods.contains('shift'),
    alt: mods.contains('alt'),
    meta: mods.contains('meta'),
  );
}

/// Human-readable label, e.g. `Ctrl + Shift + H`.
String formatHotkey(SingleActivator a) {
  final label = a.trigger.keyLabel;
  return [
    if (a.control) 'Ctrl',
    if (a.alt) _isMac ? 'Option' : 'Alt',
    if (a.shift) 'Shift',
    if (a.meta) _isMac ? 'Cmd' : 'Win',
    label.isEmpty ? (a.trigger.debugName ?? '?') : label,
  ].join(' + ');
}

/// The current shortcut, or null when the user turned it off.
final revealHiddenHotkeyProvider =
    NotifierProvider<RevealHiddenHotkeyNotifier, SingleActivator?>(
      RevealHiddenHotkeyNotifier.new,
    );

class RevealHiddenHotkeyNotifier extends Notifier<SingleActivator?> {
  @override
  SingleActivator? build() {
    final cached = ref.read(sharedPreferencesProvider).value;
    if (cached != null) return decodeHotkey(cached.getString(_prefsKey));
    unawaited(_load());
    return kDefaultRevealHiddenHotkey;
  }

  Future<void> _load() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    if (!ref.mounted) return;
    state = decodeHotkey(prefs.getString(_prefsKey));
  }

  /// Saves [activator]; null turns the shortcut off.
  Future<void> set(SingleActivator? activator) async {
    state = activator;
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setString(_prefsKey, encodeHotkey(activator));
  }

  Future<void> resetToDefault() async {
    state = kDefaultRevealHiddenHotkey;
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.remove(_prefsKey);
  }
}

/// True while the settings recorder is listening, so pressing the current
/// shortcut there records it instead of toggling hidden characters.
bool revealHiddenHotkeyRecording = false;

/// [HardwareKeyboard] handler: toggles hidden characters when the configured
/// shortcut is pressed. Returns true when it consumed the event.
bool handleRevealHiddenHotkey(WidgetRef ref, KeyEvent event) {
  if (revealHiddenHotkeyRecording || event is! KeyDownEvent) return false;
  final activator = ref.read(revealHiddenHotkeyProvider);
  if (activator == null ||
      !activator.accepts(event, HardwareKeyboard.instance)) {
    return false;
  }
  announceRevealHidden(
    ref.read(revealHiddenCharactersProvider.notifier).toggle(),
  );
  return true;
}

/// Haptic + toast confirming the hidden characters were shown or hidden.
void announceRevealHidden(bool revealed) {
  Haptics.heavyImpact();
  GlazeToast.showWithoutContext(
    revealed ? 'hidden_chars_revealed'.tr() : 'hidden_chars_hidden'.tr(),
  );
}
