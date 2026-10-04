import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/theme/built_in_themes.dart';
import '../../shared/theme/theme_provider.dart';
import 'app_settings_provider.dart';

/// Returns every app setting to its factory value and switches back to the
/// default theme.
///
/// Deliberately narrow: this resets *settings*, not content. Theme presets the
/// user made are kept (only the active one changes), and API configs,
/// characters, chats, personas, presets and lorebooks are never touched — they
/// live in Drift, not in the settings store.
///
/// Two settings survive on purpose: the interface language, because resetting
/// it would drop the user into a language they may not read, and the
/// lorebook-build prompts, which are user-written text rather than a toggle.
Future<void> resetGlazeSettings(WidgetRef ref) async {
  final settings = ref.read(appSettingsProvider).value ?? const AppSettings();
  const defaults = AppSettings();

  await ref
      .read(appSettingsProvider.notifier)
      .save(
        defaults.copyWith(
          language: settings.language,
          lorebookBuildPrompt: settings.lorebookBuildPrompt,
          lorebookBuildPromptJs: settings.lorebookBuildPromptJs,
        ),
      );

  final theme = ref.read(themeProvider.notifier);
  await theme.applyPreset(kBuiltInThemes.first);
}
