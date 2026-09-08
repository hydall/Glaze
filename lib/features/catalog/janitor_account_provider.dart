import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Last-known JanitorAI account, persisted across launches alongside the
/// session. Only the display [userName] is kept — enough to show "Logged in as
/// …" in the menu without booting the headless WebView to re-check the session.
class JanitorAccount {
  final String? userName;
  const JanitorAccount({this.userName});

  bool get isLoggedIn => userName != null && userName!.isNotEmpty;
}

/// Holds the persisted JanitorAI [userName]. Written when a login lands (the
/// login sheet fetches `/hampter/profiles/mine` and calls [setUserName]) and
/// cleared on logout. Loaded from prefs on first build so the menu hint is
/// correct immediately, before any network call.
class JanitorAccountNotifier extends Notifier<JanitorAccount> {
  static const _userNameKey = 'gz_janitor_user_name';

  @override
  JanitorAccount build() {
    _load();
    return const JanitorAccount();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_userNameKey);
    if (name != null && name.isNotEmpty) {
      state = JanitorAccount(userName: name);
    }
  }

  /// Persists [name] (or clears it when null/empty) and updates the state.
  Future<void> setUserName(String? name) async {
    final prefs = await SharedPreferences.getInstance();
    if (name == null || name.isEmpty) {
      await prefs.remove(_userNameKey);
      state = const JanitorAccount();
    } else {
      await prefs.setString(_userNameKey, name);
      state = JanitorAccount(userName: name);
    }
  }
}

final janitorAccountProvider =
    NotifierProvider<JanitorAccountNotifier, JanitorAccount>(
  JanitorAccountNotifier.new,
);
