import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'theme_preset.dart';

/// Catalog of ready-made themes curated by the authors, surfaced in the
/// "Built-In" tab of the theme presets screen.
///
/// These entries are *templates*, not live presets: tapping one in the
/// Built-In tab clones it into the user's own theme list (with a fresh `id`),
/// so the original stays pristine and can be re-installed at any time.
///
/// To add an author theme, append a [ThemePreset] here. The easiest path is to
/// design it in-app, export it (`action_export`), then paste the decoded JSON:
///
/// ```dart
/// ThemePreset.fromJson(<json map from the exported .json>),
/// ```
///
/// Give each one a stable, unique [ThemePreset.id] prefixed with `builtin_`
/// (e.g. `builtin_midnight`) so it can be recognised across app updates and
/// never collides with user-created (`custom_…`) or system (`default`) ids.
final List<ThemePreset> kBuiltInThemes = <ThemePreset>[
  // Author themes go here — intentionally empty for now.
];

/// Exposes the built-in theme catalog to the UI.
///
/// A provider (rather than the raw list) so the source can later be swapped for
/// an async one — a bundled asset bundle or a remote catalog — without touching
/// the theme presets screen.
final builtInThemesProvider = Provider<List<ThemePreset>>(
  (ref) => kBuiltInThemes,
);
