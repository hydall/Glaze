import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Process-wide singleton repository for global JS extension variables.
///
/// Persisted to [SharedPreferences] as a single JSON string under
/// [_storageKey] (default `'glaze.global_variables'`). All operations are
/// atomic read-modify-write — concurrent writes are serialized through an
/// internal [_writeLock] so a lost-update race cannot corrupt the
/// stored payload.
///
/// `maxJsonBytes` mirrors the bridge-level limit (64 KiB). Writes that
/// would push the payload past the cap are rejected with
/// [ArgumentError] so the caller can surface a JS error.
class GlobalVariablesRepo {
  GlobalVariablesRepo._({
    required this._prefsLoader,
  });

  static const _defaultStorageKey = 'glaze.global_variables';
  static const _defaultMaxJsonBytes = 64 * 1024;

  /// Build a repo backed by the system [SharedPreferences].
  static Future<GlobalVariablesRepo> create() async {
    final prefs = await SharedPreferences.getInstance();
    return GlobalVariablesRepo._(prefsLoader: Future.value(prefs));
  }

  /// Test seam: build a repo against a custom [SharedPreferences] loader
  /// (e.g. `SharedPreferences.setMockInitialValues({})`).
  factory GlobalVariablesRepo.withPrefsLoader(
    Future<SharedPreferences> Function() loader,
  ) =>
      GlobalVariablesRepo._(prefsLoader: loader());

  final Future<SharedPreferences> _prefsLoader;
  final String _storageKey = _defaultStorageKey;
  final int _maxJsonBytes = _defaultMaxJsonBytes;
  Future<void> _writeLock = Future.value();

  Future<SharedPreferences> get _prefs => _prefsLoader;

  /// Read the current root map. Returns an empty map when the storage
  /// is empty or the persisted payload is malformed.
  Future<Map<String, dynamic>> read() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return <String, dynamic>{};
  }

  /// Atomically transform the current root. The [update] callback
  /// receives the current decoded map (never null) and must return the
  /// next map. The repository validates the returned payload's size and
  /// throws [ArgumentError] if the result would exceed
  /// [maxJsonBytes].
  Future<Map<String, dynamic>> update(
    Map<String, dynamic> Function(Map<String, dynamic> root) update,
  ) async {
    final next = await _runSerialized(() async {
      final prefs = await _prefs;
      final root = await read();
      final mutated = update(root);
      _validateSize(mutated);
      final encoded = jsonEncode(mutated);
      await prefs.setString(_storageKey, encoded);
      return Map<String, dynamic>.from(mutated);
    });
    return next;
  }

  /// Replaces the entire root payload. Used by tests and by the
  /// permission-protected bridge layer when the JS calls a top-level
  /// `setVariables({ scope: 'global' })` without a path.
  Future<Map<String, dynamic>> replaceAll(Map<String, dynamic> next) {
    return update((_) => next);
  }

  Future<T> _runSerialized<T>(Future<T> Function() op) {
    final completer = Completer<T>();
    final previous = _writeLock;
    _writeLock = previous.then(
      (_) => op().then(
        (v) {
          if (!completer.isCompleted) completer.complete(v);
        },
        onError: (Object e, StackTrace s) {
          if (!completer.isCompleted) completer.completeError(e, s);
        },
      ),
      onError: (Object e, StackTrace s) {
        if (!completer.isCompleted) completer.completeError(e, s);
      },
    );
    return completer.future;
  }

  void _validateSize(Map<String, dynamic> root) {
    final bytes = utf8.encode(jsonEncode(root)).length;
    if (bytes > _maxJsonBytes) {
      throw ArgumentError(
        'Global variables payload exceeds $_maxJsonBytes bytes (got $bytes)',
      );
    }
  }
}
