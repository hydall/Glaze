import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/tts_types.dart';
import 'tts_audio_analysis.dart';

/// A clip on disk plus what is known about it.
class TtsCachedClip {
  final String key;
  final String path;
  final TtsClipInfo? info;
  const TtsCachedClip(this.key, this.path, this.info);
}

/// Builds the cache key of one clip. Anything that changes the sound goes
/// in, so an edited message, another swipe or a different voice never reuses
/// an old recording.
String ttsClipKey({
  required String providerId,
  required String voiceId,
  required String settingsFingerprint,
  required String text,
}) {
  final digest = sha256.convert(
    utf8.encode('$providerId\u0000$voiceId\u0000$settingsFingerprint\u0000$text'),
  );
  return digest.toString().substring(0, 40);
}

/// Stores generated clips as files.
///
/// Two areas share one interface:
///  * the persistent cache (`tts_cache/`), used when the "keep generated
///    audio" option is on, with a small JSON index of durations and peaks;
///  * the session area (`tts_session/`), which holds clips only until the
///    chat closes and is wiped on start-up.
///
/// The folder lives in the app data root, outside the database, so it is
/// never part of backups or cloud sync.
class TtsAudioCache {
  final Directory _persistentDir;
  final Directory _sessionDir;
  final Map<String, _Entry> _persistent = {};
  final Map<String, _Entry> _session = {};
  Timer? _flushTimer;
  bool _loaded = false;

  TtsAudioCache(String rootDir)
    : _persistentDir = Directory(p.join(rootDir, 'tts_cache')),
      _sessionDir = Directory(p.join(rootDir, 'tts_session'));

  File get _indexFile => File(p.join(_persistentDir.path, 'index.json'));

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      if (await _sessionDir.exists()) {
        await _sessionDir.delete(recursive: true);
      }
    } catch (_) {}
    try {
      if (!await _indexFile.exists()) return;
      final raw = jsonDecode(await _indexFile.readAsString());
      if (raw is! Map) return;
      for (final e in raw.entries) {
        final entry = _Entry.fromJson(e.value);
        if (e.key is String && entry != null) _persistent[e.key as String] = entry;
      }
    } catch (e) {
      debugPrint('[TTS] cache index unreadable, starting empty: $e');
    }
  }

  /// The clip for [key], or null. The persistent area is only consulted
  /// when [usePersistent] is true.
  Future<TtsCachedClip?> lookup(String key, {required bool usePersistent}) async {
    final session = _session[key];
    if (session != null) {
      final path = p.join(_sessionDir.path, '$key.${session.ext}');
      if (await File(path).exists()) return TtsCachedClip(key, path, session.info);
      _session.remove(key);
    }
    if (!usePersistent) return null;
    final entry = _persistent[key];
    if (entry == null) return null;
    final path = p.join(_persistentDir.path, '$key.${entry.ext}');
    if (!await File(path).exists()) {
      _persistent.remove(key);
      _scheduleFlush();
      return null;
    }
    return TtsCachedClip(key, path, entry.info);
  }

  /// Synchronous peek at a known clip's info, for drawing pills without I/O.
  TtsClipInfo? infoOf(String key, {required bool usePersistent}) =>
      _session[key]?.info ?? (usePersistent ? _persistent[key]?.info : null);

  bool contains(String key, {required bool usePersistent}) =>
      _session.containsKey(key) ||
      (usePersistent && _persistent.containsKey(key));

  Future<TtsCachedClip> put(
    String key,
    TtsAudio audio,
    TtsClipInfo? info, {
    required bool persistent,
  }) async {
    final dir = persistent ? _persistentDir : _sessionDir;
    await dir.create(recursive: true);
    final ext = audio.extension;
    final path = p.join(dir.path, '$key.$ext');
    await File(path).writeAsBytes(audio.bytes, flush: true);
    final entry = _Entry(ext, audio.bytes.length, info);
    if (persistent) {
      _persistent[key] = entry;
      _scheduleFlush();
    } else {
      _session[key] = entry;
    }
    return TtsCachedClip(key, path, info);
  }

  /// Attaches analysis that arrived after the clip was stored.
  void updateInfo(String key, TtsClipInfo info) {
    final s = _session[key];
    if (s != null) _session[key] = _Entry(s.ext, s.bytes, info);
    final e = _persistent[key];
    if (e != null) {
      _persistent[key] = _Entry(e.ext, e.bytes, info);
      _scheduleFlush();
    }
  }

  /// Drops the session clips (chat closed).
  Future<void> clearSession() async {
    _session.clear();
    try {
      if (await _sessionDir.exists()) await _sessionDir.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> clearAll() async {
    _flushTimer?.cancel();
    _persistent.clear();
    try {
      if (await _persistentDir.exists()) {
        await _persistentDir.delete(recursive: true);
      }
    } catch (_) {}
    await clearSession();
  }

  /// Bytes taken by the persistent cache.
  Future<int> persistentSize() async {
    var total = 0;
    try {
      if (!await _persistentDir.exists()) return 0;
      await for (final f in _persistentDir.list()) {
        if (f is File) total += await f.length();
      }
    } catch (_) {}
    return total;
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 600), _flush);
  }

  Future<void> flush() async {
    _flushTimer?.cancel();
    await _flush();
  }

  Future<void> _flush() async {
    try {
      await _persistentDir.create(recursive: true);
      final tmp = File('${_indexFile.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({for (final e in _persistent.entries) e.key: e.value.toJson()}),
        flush: true,
      );
      await tmp.rename(_indexFile.path);
    } catch (e) {
      debugPrint('[TTS] cache index write failed: $e');
    }
  }
}

class _Entry {
  final String ext;
  final int bytes;
  final TtsClipInfo? info;
  const _Entry(this.ext, this.bytes, this.info);

  Map<String, dynamic> toJson() => {
    'ext': ext,
    'bytes': bytes,
    if (info != null) 'info': info!.toJson(),
  };

  static _Entry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final ext = raw['ext'];
    if (ext is! String) return null;
    final bytes = raw['bytes'];
    return _Entry(
      ext,
      bytes is int ? bytes : 0,
      TtsClipInfo.fromJson(raw['info']),
    );
  }
}
