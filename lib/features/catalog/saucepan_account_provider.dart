import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/saucepan_extractor.dart';

/// Persisted Saucepan account state. A configured bearer token *is* the
/// logged-in signal (the token, not a display name, gates local extraction);
/// [handle] is kept only to show "Logged in as …" in the menu.
class SaucepanAccount {
  final bool loggedIn;
  final String? handle;
  const SaucepanAccount({this.loggedIn = false, this.handle});

  bool get isLoggedIn => loggedIn;
}

/// Owns the Saucepan login lifecycle. Delegates the token to the shared
/// [SaucepanExtractor] (same instance used for extraction) and mirrors its
/// logged-in state, plus the display [handle], for the menu.
class SaucepanAccountNotifier extends Notifier<SaucepanAccount> {
  static const _handleKey = 'gz_saucepan_handle';

  @override
  SaucepanAccount build() {
    _load();
    return const SaucepanAccount();
  }

  Future<void> _load() async {
    final ext = ref.read(saucepanExtractorProvider);
    await ext.loadToken();
    final prefs = await SharedPreferences.getInstance();
    final handle = prefs.getString(_handleKey);
    state = SaucepanAccount(loggedIn: ext.isLoggedIn, handle: handle);
  }

  /// Logs in with handle + password; throws [SaucepanException] on failure.
  Future<void> login(String handle, String password) async {
    final ext = ref.read(saucepanExtractorProvider);
    await ext.login(handle, password);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_handleKey, handle.trim());
    state = SaucepanAccount(loggedIn: true, handle: handle.trim());
  }

  /// Stores a pasted bearer token directly (no handle).
  Future<void> setToken(String token) async {
    final ext = ref.read(saucepanExtractorProvider);
    await ext.setToken(token);
    state = SaucepanAccount(loggedIn: ext.isLoggedIn, handle: state.handle);
  }

  /// Clears the stored session.
  Future<void> logout() async {
    final ext = ref.read(saucepanExtractorProvider);
    await ext.logout();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_handleKey);
    state = const SaucepanAccount();
  }
}

final saucepanAccountProvider =
    NotifierProvider<SaucepanAccountNotifier, SaucepanAccount>(
  SaucepanAccountNotifier.new,
);
