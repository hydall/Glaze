import 'package:shared_preferences/shared_preferences.dart';

import '../state/dev_mode_provider.dart';

/// Marker for the one-time reset below. Its presence — not its value — is what
/// says the reset already ran, so a user who unlocks dev mode afterwards keeps
/// it across launches.
const _markerKey = 'devModeDefaultResetV1';

/// Clears a `devModeEnabled` left over from the builds where `nightly` and
/// `staging` switched developer mode on by default.
///
/// Dev mode is now off on every channel and is only reachable through the
/// 7-tap easter egg on the version badge in About. Without this those installs
/// would keep a persisted `true` forever and still show the Dev group, since a
/// stored value always wins over the default.
///
/// Runs exactly once per install: after the marker is written the stored flag
/// is the user's own choice and is never touched again.
Future<void> resetLegacyDevModeFlag({SharedPreferences? preferences}) async {
  final prefs = preferences ?? await SharedPreferences.getInstance();
  if (prefs.containsKey(_markerKey)) return;

  await prefs.remove(DevModeNotifier.prefsKey);
  await prefs.setBool(_markerKey, true);
}
