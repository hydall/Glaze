import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class SyncDeletionTracker {
  static const _key = 'gz_sync_deleted_entries';

  static Future<void> record(String type, String id, [SharedPreferences? prefs]) async {
    prefs ??= await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    final list = raw != null
        ? (jsonDecode(raw) as List).cast<Map<String, dynamic>>().toList()
        : <Map<String, dynamic>>[];
    list.add({'type': type, 'id': id});
    await prefs.setString(_key, jsonEncode(list));
  }

  static Future<void> recordSessionRuntimeClear(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    await record('tracker_value', sessionId, prefs);
    await record('tracker_snapshot', sessionId, prefs);
    await record('info_block', sessionId, prefs);
  }
}
