import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'plugin_library_provider.dart';

/// What one plugin's frames were seen loading from one host.
class PluginHostRecord {
  const PluginHostRecord({
    required this.host,
    required this.count,
    required this.blocked,
    required this.lastSeen,
    this.lastBlocked = false,
  });

  final String host;

  /// Requests that went through.
  final int count;

  /// Requests the frame's policy stopped (the plugin has no internet access).
  final int blocked;

  /// Milliseconds since epoch.
  final int lastSeen;

  /// Whether the latest request was stopped.
  final bool lastBlocked;

  PluginHostRecord seen({required bool wasBlocked, required int at}) =>
      PluginHostRecord(
        host: host,
        count: count + (wasBlocked ? 0 : 1),
        blocked: blocked + (wasBlocked ? 1 : 0),
        lastSeen: at,
        lastBlocked: wasBlocked,
      );

  Map<String, Object?> toJson() => {
    'count': count,
    'blocked': blocked,
    'lastSeen': lastSeen,
    'lastBlocked': lastBlocked,
  };

  static PluginHostRecord fromJson(String host, Map<dynamic, dynamic> json) =>
      PluginHostRecord(
        host: host,
        count: (json['count'] as num?)?.toInt() ?? 0,
        blocked: (json['blocked'] as num?)?.toInt() ?? 0,
        lastSeen: (json['lastSeen'] as num?)?.toInt() ?? 0,
        lastBlocked: json['lastBlocked'] == true,
      );
}

/// Hosts a plugin's frames loaded from (or tried to), by plugin id, kept in
/// `<plugin_data>/<id>/network.json`. Fed by the chat's plugin runtime.
final pluginNetworkLogProvider =
    AsyncNotifierProvider.family<
      PluginNetworkLogNotifier,
      Map<String, PluginHostRecord>,
      String
    >(PluginNetworkLogNotifier.new);

class PluginNetworkLogNotifier
    extends AsyncNotifier<Map<String, PluginHostRecord>> {
  PluginNetworkLogNotifier(this.pluginId);

  final String pluginId;
  Timer? _flush;

  static const maxHosts = 200;

  Future<File> get _file async {
    final store = await ref.read(pluginStoreProvider.future);
    return File(p.join(store.dataDir(pluginId), 'network.json'));
  }

  @override
  Future<Map<String, PluginHostRecord>> build() async {
    ref.onDispose(() => _flush?.cancel());
    try {
      final file = await _file;
      if (!await file.exists()) return const {};
      final json = jsonDecode(await file.readAsString());
      final hosts = json is Map ? json['hosts'] : null;
      if (hosts is! Map) return const {};
      return {
        for (final e in hosts.entries)
          if (e.value is Map)
            '${e.key}': PluginHostRecord.fromJson('${e.key}', e.value as Map),
      };
    } catch (e) {
      debugPrint('[PluginNetworkLog] $pluginId unreadable: $e');
      return const {};
    }
  }

  Future<void> record(String host, {required bool blocked}) async {
    final current = await future;
    final now = DateTime.now().millisecondsSinceEpoch;
    final previous =
        current[host] ??
        PluginHostRecord(host: host, count: 0, blocked: 0, lastSeen: now);
    final next = {
      ...current,
      host: previous.seen(wasBlocked: blocked, at: now),
    };
    // The plugin reports its own hosts, so it could flood the list; the
    // oldest entries go first.
    if (next.length > maxHosts) {
      final oldest = next.values.toList()
        ..sort((a, b) => a.lastSeen.compareTo(b.lastSeen));
      for (final r in oldest.take(next.length - maxHosts)) {
        next.remove(r.host);
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
    final hosts = state.value ?? const {};
    try {
      final file = await _file;
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'hosts': {for (final e in hosts.entries) e.key: e.value.toJson()},
        }),
      );
    } catch (e) {
      debugPrint('[PluginNetworkLog] $pluginId not saved: $e');
    }
  }
}
