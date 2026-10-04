import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Last-known Chub account, persisted across launches.
///
/// The API key *is* the logged-in signal: every catalog request to Chub carries
/// it as `CH-API-KEY` (and the parallel `samwise` header the site itself sends),
/// which unlocks account-scoped results — most importantly NSFL, which the
/// public API refuses to return without a session. Only the display [userName]
/// and the key are kept here; nothing is written to Drift.
class ChubAccount {
  final String? userName;
  final String? apiKey;

  /// Account-level NSFL opt-in, the app's counterpart to the `no_nsfl` flag the
  /// site stores on the user profile. chub.ai serves NSFL only to a signed-in
  /// account, and asks per search on top of that — so this is the persistent
  /// "I want it" and the filter sheet's NSFL toggle is the per-search narrowing.
  /// It is ORed into every search.
  final bool nsfl;

  const ChubAccount({this.userName, this.apiKey, this.nsfl = false});

  bool get isLoggedIn => apiKey != null && apiKey!.isNotEmpty;
}

/// Holds the persisted Chub [apiKey] and display [userName]. Loaded from prefs
/// on first build so the menu hint is correct immediately, before any network
/// call.
class ChubAccountNotifier extends Notifier<ChubAccount> {
  static const _apiKeyPref = 'gz_chub_api_key';
  static const _userNamePref = 'gz_chub_user_name';
  static const _nsflPref = 'gz_chub_nsfl';

  @override
  ChubAccount build() {
    _load();
    return const ChubAccount();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = ChubAccount(
      apiKey: prefs.getString(_apiKeyPref),
      userName: prefs.getString(_userNamePref),
      nsfl: prefs.getBool(_nsflPref) ?? false,
    );
  }

  /// Stores [key] (clearing the account when null/empty). [userName] is kept
  /// alongside it when supplied, so the menu can show who is signed in.
  Future<void> setApiKey(String? key, {String? userName}) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = key?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      await prefs.remove(_apiKeyPref);
      await prefs.remove(_userNamePref);
      state = ChubAccount(nsfl: state.nsfl);
      return;
    }
    await prefs.setString(_apiKeyPref, trimmed);
    final name = userName?.trim();
    if (name != null && name.isNotEmpty) {
      await prefs.setString(_userNamePref, name);
      state = ChubAccount(apiKey: trimmed, userName: name, nsfl: state.nsfl);
    } else {
      state = ChubAccount(
        apiKey: trimmed,
        userName: state.userName,
        nsfl: state.nsfl,
      );
    }
  }

  /// Updates only the display name, leaving the stored key untouched.
  Future<void> setUserName(String? name) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      await prefs.remove(_userNamePref);
      state = ChubAccount(apiKey: state.apiKey, nsfl: state.nsfl);
      return;
    }
    await prefs.setString(_userNamePref, trimmed);
    state = ChubAccount(
      apiKey: state.apiKey,
      userName: trimmed,
      nsfl: state.nsfl,
    );
  }

  /// Turns the account-level NSFL opt-in on or off.
  Future<void> setNsfl(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_nsflPref, value);
    state = ChubAccount(
      apiKey: state.apiKey,
      userName: state.userName,
      nsfl: value,
    );
  }

  /// Clears the stored key and display name. NSFL is account-scoped, so it goes
  /// with the account.
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_apiKeyPref);
    await prefs.remove(_userNamePref);
    await prefs.remove(_nsflPref);
    state = const ChubAccount();
  }
}

final chubAccountProvider =
    NotifierProvider<ChubAccountNotifier, ChubAccount>(ChubAccountNotifier.new);
