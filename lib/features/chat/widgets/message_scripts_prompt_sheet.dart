import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/state/shared_prefs_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../settings/app_settings_provider.dart';

/// SharedPreferences flag: the user has made an explicit choice about message
/// script execution — either by answering the in-chat offer or by flipping the
/// switch in the interface settings — so the offer is never shown again. Kept
/// next to the sheet so its lifecycle stays self-contained; the setting itself
/// lives in [AppSettings.allowMessageScripts].
const kMessageScriptsChoiceMadeKey = 'messageScriptsChoiceMade';

/// Guards against a second sheet while one is already on screen. The bridge
/// reports at most once per WebView load, but a chat can host more than one
/// WebView across a session switch.
bool _sheetOpen = false;

/// Records that the user has decided about message scripts, so the in-chat
/// offer stays quiet from now on.
///
/// The settings switch must `await` this **before** saving the new value: the
/// save re-renders the chat under the new policy, which is exactly what makes
/// the WebView report the scripts it just blocked.
Future<void> markMessageScriptsChoiceMade(WidgetRef ref) async {
  final prefs = await ref.read(sharedPreferencesProvider.future);
  await prefs.setBool(kMessageScriptsChoiceMadeKey, true);
}

/// Offers to turn message script execution on after a chat message was found to
/// carry JavaScript while [AppSettings.allowMessageScripts] is off.
///
/// Shown at most once — both answers are recorded via
/// [markMessageScriptsChoiceMade]. Dismissing the sheet without answering
/// records nothing, so the offer can come back later.
Future<void> maybeShowMessageScriptsPrompt(
  BuildContext context,
  WidgetRef ref,
) async {
  if (_sheetOpen) return;
  if (ref.read(appSettingsProvider).value?.allowMessageScripts ?? false) return;

  final prefs = await ref.read(sharedPreferencesProvider.future);
  if (prefs.getBool(kMessageScriptsChoiceMadeKey) ?? false) return;
  if (!context.mounted || _sheetOpen) return;

  _sheetOpen = true;
  try {
    final enable = await GlazeBottomSheet.show<bool>(
      context,
      child: const _MessageScriptsPromptBody(),
    );
    if (enable == null) return;
    await prefs.setBool(kMessageScriptsChoiceMadeKey, true);
    if (!enable) return;
    final settings = ref.read(appSettingsProvider).value;
    if (settings == null) return;
    // Turning the setting on pushes the new policy into the WebView, which
    // re-renders the messages already on screen so their scripts run.
    await ref
        .read(appSettingsProvider.notifier)
        .save(settings.copyWith(allowMessageScripts: true));
  } finally {
    _sheetOpen = false;
  }
}

class _MessageScriptsPromptBody extends StatelessWidget {
  const _MessageScriptsPromptBody();

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(Icons.code_rounded, color: cs.primary, size: 30),
          ),
          const SizedBox(height: 18),
          Text(
            'message_scripts_detected_title'.tr(),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'message_scripts_detected_body'.tr(),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14.5,
              height: 1.45,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 22),
          GlazeActionButton(
            icon: Icons.check_rounded,
            label: 'message_scripts_detected_enable'.tr(),
            tone: GlazeActionTone.primary,
            expand: true,
            onTap: () => Navigator.of(context).pop(true),
          ),
          const SizedBox(height: 8),
          GlazeActionButton(
            icon: Icons.block_rounded,
            label: 'message_scripts_detected_keep_off'.tr(),
            tone: GlazeActionTone.neutral,
            expand: true,
            onTap: () => Navigator.of(context).pop(false),
          ),
        ],
      ),
    );
  }
}
