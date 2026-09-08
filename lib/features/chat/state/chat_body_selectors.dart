import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

/// In battery-saver mode we want to read provider values once and
/// avoid subscribing to rebuilds. Outside battery-saver mode, we want
/// the normal `ref.watch` behavior so the UI rebuilds when the value
/// changes. This helper centralizes that dual-read pattern so the chat
/// screen does not have to repeat it for every provider.
///
/// Usage:
/// ```dart
/// final preset = batteryAware(
///   ref,
///   appSettings?.batterySaver ?? false,
///   themeProvider.select((p) => p.activePreset),
/// );
/// ```
T batteryAware<T>(
  WidgetRef ref,
  bool batterySaver,
  ProviderListenable<T> provider,
) {
  return batterySaver ? ref.read(provider) : ref.watch(provider);
}
