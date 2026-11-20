import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../character_list/reveal_hidden_hotkey.dart';

/// Settings row for the desktop shortcut that shows/hides hidden characters.
/// Tapping it opens a sheet that records the next key combination.
class RevealHiddenHotkeyItem extends ConsumerWidget {
  const RevealHiddenHotkeyItem({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hotkey = ref.watch(revealHiddenHotkeyProvider);
    return MenuItem(
      icon: Icons.keyboard_outlined,
      label: 'menu_reveal_hidden_hotkey'.tr(),
      subtitle: 'desc_reveal_hidden_hotkey'.tr(),
      value: hotkey == null ? 'hotkey_none'.tr() : formatHotkey(hotkey),
      onTap: () => _openRecorder(context, ref),
    );
  }

  void _openRecorder(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(revealHiddenHotkeyProvider.notifier);
    void close() => Navigator.of(context, rootNavigator: true).pop();
    GlazeBottomSheet.show<void>(
      context,
      title: 'menu_reveal_hidden_hotkey'.tr(),
      child: _HotkeyRecorder(
        onCaptured: (activator) {
          notifier.set(activator);
          close();
        },
        onCancel: close,
      ),
      items: [
        BottomSheetItem(
          icon: Icons.restart_alt_rounded,
          label: 'hotkey_reset_default'.tr(
            namedArgs: {'hotkey': formatHotkey(kDefaultRevealHiddenHotkey)},
          ),
          onTap: () {
            notifier.resetToDefault();
            close();
          },
        ),
        BottomSheetItem(
          icon: Icons.block_rounded,
          label: 'hotkey_disable'.tr(),
          isDestructive: true,
          onTap: () {
            notifier.set(null);
            close();
          },
        ),
      ],
    );
  }
}

/// Grabs keyboard focus and reports the first combination that has a
/// non-modifier key plus at least one of Ctrl / Alt / Cmd (or is a function
/// key), so a bare letter can't hijack typing. Escape cancels.
class _HotkeyRecorder extends StatefulWidget {
  final ValueChanged<SingleActivator> onCaptured;
  final VoidCallback onCancel;

  const _HotkeyRecorder({required this.onCaptured, required this.onCancel});

  @override
  State<_HotkeyRecorder> createState() => _HotkeyRecorderState();
}

class _HotkeyRecorderState extends State<_HotkeyRecorder> {
  final _focus = FocusNode(debugLabel: 'hotkey-recorder');

  static final _modifiers = <LogicalKeyboardKey>{
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.capsLock,
    LogicalKeyboardKey.numLock,
    LogicalKeyboardKey.fn,
  };

  static final _functionKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.f1,
    LogicalKeyboardKey.f2,
    LogicalKeyboardKey.f3,
    LogicalKeyboardKey.f4,
    LogicalKeyboardKey.f5,
    LogicalKeyboardKey.f6,
    LogicalKeyboardKey.f7,
    LogicalKeyboardKey.f8,
    LogicalKeyboardKey.f9,
    LogicalKeyboardKey.f10,
    LogicalKeyboardKey.f11,
    LogicalKeyboardKey.f12,
  };

  @override
  void initState() {
    super.initState();
    revealHiddenHotkeyRecording = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    revealHiddenHotkeyRecording = false;
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final key = event.logicalKey;
    if (_modifiers.contains(key)) return KeyEventResult.handled;
    final kb = HardwareKeyboard.instance;
    if (key == LogicalKeyboardKey.escape && !kb.isControlPressed) {
      widget.onCancel();
      return KeyEventResult.handled;
    }
    final hasModifier =
        kb.isControlPressed || kb.isAltPressed || kb.isMetaPressed;
    if (!hasModifier && !_functionKeys.contains(key)) {
      return KeyEventResult.handled;
    }
    widget.onCaptured(
      SingleActivator(
        key,
        control: kb.isControlPressed,
        shift: kb.isShiftPressed,
        alt: kb.isAltPressed,
        meta: kb.isMetaPressed,
      ),
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.keyboard_rounded, size: 40, color: context.cs.primary),
            const SizedBox(height: 12),
            Text(
              'hotkey_press_prompt'.tr(),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.cs.onSurface,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'hotkey_press_hint'.tr(),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.cs.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
