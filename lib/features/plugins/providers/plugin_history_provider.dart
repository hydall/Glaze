import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'plugin_library_provider.dart';

/// One kind of thing a plugin asked for: how often it was let through and
/// how often it was stopped.
class PluginRequestRecord {
  const PluginRequestRecord({
    required this.action,
    this.permission,
    this.allowed = 0,
    this.lastAllowed = 0,
    this.denied = 0,
    this.lastDenied = 0,
  });

  /// Translation key naming the request (see `pluginActionKey`).
  final String action;

  /// The permission it was checked against; null in histories kept before
  /// it was noted.
  final String? permission;
  final int allowed;
  final int denied;

  /// Milliseconds since epoch; 0 for never.
  final int lastAllowed;
  final int lastDenied;

  int get lastSeen => lastAllowed > lastDenied ? lastAllowed : lastDenied;

  PluginRequestRecord _count({
    required bool allowed,
    required int at,
    required String permission,
  }) => PluginRequestRecord(
    action: action,
    permission: permission,
    allowed: this.allowed + (allowed ? 1 : 0),
    lastAllowed: allowed ? at : lastAllowed,
    denied: denied + (allowed ? 0 : 1),
    lastDenied: allowed ? lastDenied : at,
  );

  Map<String, Object?> toJson() => {
    'permission': ?permission,
    'allowed': allowed,
    'lastAllowed': lastAllowed,
    'denied': denied,
    'lastDenied': lastDenied,
  };

  static int _int(Object? v) => (v as num?)?.toInt() ?? 0;

  static PluginRequestRecord fromJson(String action, Map<dynamic, dynamic> j) =>
      PluginRequestRecord(
        action: action,
        permission: j['permission'] is String
            ? j['permission'] as String
            : null,
        allowed: _int(j['allowed']),
        lastAllowed: _int(j['lastAllowed']),
        denied: _int(j['denied']),
        lastDenied: _int(j['lastDenied']),
      );
}

/// What a plugin asked to use and whether it was let through, by plugin
/// id, kept in `<plugin_data>/<id>/history.json`.
final pluginHistoryProvider =
    AsyncNotifierProvider.family<
      PluginHistoryNotifier,
      Map<String, PluginRequestRecord>,
      String
    >(PluginHistoryNotifier.new);

class PluginHistoryNotifier
    extends AsyncNotifier<Map<String, PluginRequestRecord>> {
  PluginHistoryNotifier(this.pluginId);

  final String pluginId;
  Timer? _flush;

  static const maxEntries = 100;

  Future<File> get _file async {
    final store = await ref.read(pluginStoreProvider.future);
    return File(p.join(store.dataDir(pluginId), 'history.json'));
  }

  @override
  Future<Map<String, PluginRequestRecord>> build() async {
    ref.onDispose(() => _flush?.cancel());
    try {
      final file = await _file;
      if (!await file.exists()) return const {};
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return const {};
      final requests = json['requests'];
      if (requests is Map) {
        return {
          for (final e in requests.entries)
            if (e.value is Map)
              '${e.key}': PluginRequestRecord.fromJson(
                '${e.key}',
                e.value as Map,
              ),
        };
      }
      // Kept refusals only, before allowed requests were counted too.
      final denied = json['denied'];
      if (denied is! Map) return const {};
      return {
        for (final e in denied.entries)
          if (e.value is Map)
            '${e.key}': PluginRequestRecord(
              action: '${e.key}',
              denied: PluginRequestRecord._int((e.value as Map)['count']),
              lastDenied: PluginRequestRecord._int(
                (e.value as Map)['lastSeen'],
              ),
            ),
      };
    } catch (e) {
      debugPrint('[PluginHistory] $pluginId unreadable: $e');
      return const {};
    }
  }

  Future<void> allowed(String action, String permission) =>
      _count(action, permission, allowed: true);

  Future<void> denied(String action, String permission) =>
      _count(action, permission, allowed: false);

  Future<void> _count(
    String action,
    String permission, {
    required bool allowed,
  }) async {
    final current = await future;
    final now = DateTime.now().millisecondsSinceEpoch;
    final next = {
      ...current,
      action: (current[action] ?? PluginRequestRecord(action: action))._count(
        allowed: allowed,
        at: now,
        permission: permission,
      ),
    };
    if (next.length > maxEntries) {
      final oldest = next.values.toList()
        ..sort((a, b) => a.lastSeen.compareTo(b.lastSeen));
      for (final d in oldest.take(next.length - maxEntries)) {
        next.remove(d.action);
      }
    }
    state = AsyncData(next);
    _flush?.cancel();
    _flush = Timer(const Duration(seconds: 2), () => unawaited(_write()));
  }

  Future<void> clear() async {
    _flush?.cancel();
    state = const AsyncData({});
    await _write();
  }

  Future<void> _write() async {
    final requests = state.value ?? const {};
    try {
      final file = await _file;
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'requests': {
            for (final e in requests.entries) e.key: e.value.toJson(),
          },
        }),
      );
    } catch (e) {
      debugPrint('[PluginHistory] $pluginId not saved: $e');
    }
  }
}
