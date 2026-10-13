import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'plugin_library_provider.dart';

/// One kind of thing a plugin was stopped from doing.
class PluginDenial {
  const PluginDenial({
    required this.action,
    required this.count,
    required this.lastSeen,
  });

  /// Translation key naming the attempt.
  final String action;
  final int count;

  /// Milliseconds since epoch.
  final int lastSeen;

  Map<String, Object?> toJson() => {'count': count, 'lastSeen': lastSeen};

  static PluginDenial fromJson(String action, Map<dynamic, dynamic> json) =>
      PluginDenial(
        action: action,
        count: (json['count'] as num?)?.toInt() ?? 0,
        lastSeen: (json['lastSeen'] as num?)?.toInt() ?? 0,
      );
}

/// What a plugin tried and was not allowed to do, by plugin id, kept in
/// `<plugin_data>/<id>/history.json`.
final pluginHistoryProvider =
    AsyncNotifierProvider.family<
      PluginHistoryNotifier,
      Map<String, PluginDenial>,
      String
    >(PluginHistoryNotifier.new);

class PluginHistoryNotifier extends AsyncNotifier<Map<String, PluginDenial>> {
  PluginHistoryNotifier(this.pluginId);

  final String pluginId;
  Timer? _flush;

  static const maxEntries = 100;

  Future<File> get _file async {
    final store = await ref.read(pluginStoreProvider.future);
    return File(p.join(store.dataDir(pluginId), 'history.json'));
  }

  @override
  Future<Map<String, PluginDenial>> build() async {
    ref.onDispose(() => _flush?.cancel());
    try {
      final file = await _file;
      if (!await file.exists()) return const {};
      final json = jsonDecode(await file.readAsString());
      final denied = json is Map ? json['denied'] : null;
      if (denied is! Map) return const {};
      return {
        for (final e in denied.entries)
          if (e.value is Map)
            '${e.key}': PluginDenial.fromJson('${e.key}', e.value as Map),
      };
    } catch (e) {
      debugPrint('[PluginHistory] $pluginId unreadable: $e');
      return const {};
    }
  }

  Future<void> denied(String action) async {
    final current = await future;
    final now = DateTime.now().millisecondsSinceEpoch;
    final next = {
      ...current,
      action: PluginDenial(
        action: action,
        count: (current[action]?.count ?? 0) + 1,
        lastSeen: now,
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
    final denied = state.value ?? const {};
    try {
      final file = await _file;
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'denied': {for (final e in denied.entries) e.key: e.value.toJson()},
        }),
      );
    } catch (e) {
      debugPrint('[PluginHistory] $pluginId not saved: $e');
    }
  }
}
