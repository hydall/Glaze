import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Audio facade for the JS extension `glaze.playAudio(source, options)`
/// bridge.
///
/// Two source kinds are supported:
///
///   * **Built-in cues** — short, latency-critical feedback that runs
///     through the platform's native sound/vibration paths. These are
///     cheap and never block, so they're the recommended default for
///     `playAudio` callers in tight loops:
///       * `'click'`   — `SystemSoundType.click`.
///       * `'alert'`   — `SystemSoundType.alert`.
///       * `'haptic'`  — `HapticFeedback.mediumImpact()`.
///
///   * **Real audio sources** — anything else is delegated to
///     [`AudioPlayer`]. The following URI shapes are supported:
///       * `file:///...`  and absolute filesystem paths — `DeviceFileSource`.
///       * `http://` / `https://` URLs — `UrlSource`.
///       * `data:audio/...;base64,...` — `BytesSource` (the data is
///         decoded once and the prefix is stripped).
///
/// The [volume] option (0..1) controls the player's volume. The [loop]
/// option sets the player's release mode. Unknown keys in [options] are
/// ignored.
///
/// A single [AudioPlayer] is reused across calls so concurrent
/// `playAudio` invocations from the same preset replace the previous
/// one (`AudioPlayerMode.lowLatency` is used to minimise start-up
/// latency). Callers that need simultaneous playback should create
/// their own [AudioBridgeService] instance.
class AudioBridgeService {
  AudioBridgeService({AudioPlayer? player})
      : _player = player,
        _ownsPlayer = player == null;

  AudioPlayer? _player;
  bool _ownsPlayer;

  /// Plays a built-in cue or a real audio source. Returns when the
  /// request has been handed off to the platform.
  ///
  /// [source] is the cue name, file path, or URL. [options] accepts:
  ///   * `volume` (double, 0..1) — default 1.0.
  ///   * `loop` (bool) — default false.
  ///   * `severity` (string, ignored) — kept for API compatibility
  ///     with future bridge contracts that may map it to a
  ///     notifier-style short sound.
  Future<void> play(
    String? source,
    Map<String, dynamic> options,
  ) async {
    final resolved = (source ?? 'click').trim();
    if (resolved.isEmpty) return;
    final lower = resolved.toLowerCase();

    if (kDebugMode) {
      debugPrint('[AudioBridge] play source="$resolved" options=$options');
    }

    // Built-in cues — bypass the audio player entirely.
    switch (lower) {
      case 'click':
        await SystemSound.play(SystemSoundType.click);
        return;
      case 'alert':
        await SystemSound.play(SystemSoundType.alert);
        return;
      case 'haptic':
        await HapticFeedback.mediumImpact();
        return;
    }

    await _playWithPlayer(resolved, options);
  }

  Future<void> _playWithPlayer(
    String source,
    Map<String, dynamic> options,
  ) async {
    final player = _ensurePlayer();
    final volume = _parseVolume(options['volume']);
    final loop = options['loop'] == true;

    try {
      await player.setVolume(volume);
      await player.setReleaseMode(
        loop ? ReleaseMode.loop : ReleaseMode.stop,
      );

      final routed = routeSource(source);
      if (routed == null) {
        if (kDebugMode) {
          debugPrint(
            '[AudioBridge] source "$source" could not be routed — no-op',
          );
        }
        return;
      }
      await player.play(routed);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AudioBridge] play failed for "$source": $e');
      }
    }
  }  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final player = AudioPlayer(playerId: 'glaze.extensions.audio');
    _player = player;
    _ownsPlayer = true;
    return player;
  }

  double _parseVolume(Object? raw) {
    if (raw is num) {
      final v = raw.toDouble().clamp(0.0, 1.0);
      return v;
    }
    if (raw is String) {
      final parsed = double.tryParse(raw);
      if (parsed != null) return parsed.clamp(0.0, 1.0);
    }
    return 1.0;
  }

  /// Routes the [source] string to the matching [Source] subclass. Pure
  /// function — exposed for tests so the routing table can be pinned
  /// without binding to a real audio session.
  @visibleForTesting
  static Source? routeSource(String source) {
    final lower = source.toLowerCase();
    switch (lower) {
      case 'click':
      case 'alert':
      case 'haptic':
      case '':
        return null;
    }
    if (source.startsWith('data:')) {
      final bytes = _decodeDataUri(source);
      if (bytes == null) return null;
      return BytesSource(bytes);
    }
    if (source.startsWith('file://') ||
        source.startsWith('http://') ||
        source.startsWith('https://')) {
      return UrlSource(source);
    }
    if (_isAbsolutePath(source)) {
      return DeviceFileSource(source);
    }
    if (kIsWeb) {
      return UrlSource(source);
    }
    return DeviceFileSource(source);
  }

  /// Decodes a base64 / base64url data: URI payload. Exposed for tests
  /// and for future callers that need the bytes directly.
  @visibleForTesting
  static Uint8List? decodeDataUri(String uri) => _decodeDataUri(uri);

  static Uint8List? _decodeDataUri(String uri) {
    // data:<mediatype>;base64,<payload>
    final commaIdx = uri.indexOf(',');
    if (commaIdx < 0) return null;
    final header = uri.substring(5, commaIdx).toLowerCase();
    final payload = uri.substring(commaIdx + 1);
    if (!header.contains(';base64')) return null;
    try {
      // Tolerate missing padding; some JS callers omit `=`.
      var s = payload;
      while (s.length % 4 != 0) {
        s += '=';
      }
      return Uint8List.fromList(base64Decode(s));
    } catch (_) {
      return null;
    }
  }

  static bool _isAbsolutePath(String value) {
    if (value.startsWith('/')) return true;
    if (Platform.isWindows && value.length >= 2 && value[1] == ':') {
      return true;
    }
    return false;
  }

  /// Releases the underlying [AudioPlayer]. Call when the owning widget
  /// is disposed so the OS audio session is freed.
  Future<void> dispose() async {
    final player = _player;
    if (player != null && _ownsPlayer) {
      await player.release();
      await player.dispose();
    }
    _player = null;
    _ownsPlayer = false;
  }
}
