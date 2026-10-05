import 'dart:async';
import 'dart:collection';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// One thing to play: a file, or a direct-speech call for providers that do
/// not produce audio.
class TtsPlayItem {
  final String messageId;

  /// Position of this clip's start within its message, for message-level
  /// progress.
  final int offsetMs;
  final String? path;
  final Future<void> Function()? speak;
  final Future<void> Function()? stopSpeaking;

  const TtsPlayItem.file({
    required this.messageId,
    required this.offsetMs,
    required String this.path,
  }) : speak = null,
       stopSpeaking = null;

  const TtsPlayItem.direct({
    required this.messageId,
    required Future<void> Function() this.speak,
    required this.stopSpeaking,
  }) : offsetMs = 0,
       path = null;
}

/// Plays clips one after another on a single player, so voices never
/// overlap — SillyTavern's audio job queue.
class TtsPlayer {
  final AudioPlayer _player;
  final Queue<TtsPlayItem> _queue = Queue();
  TtsPlayItem? _current;
  double _rate = 1;
  int _epoch = 0;
  final List<StreamSubscription<dynamic>> _subs = [];

  /// Called with the message being played and the position within it.
  void Function(String messageId, int positionMs)? onProgress;

  /// Called when a message starts playing, or with null when playback stops
  /// and the queue is empty.
  void Function(String? messageId)? onActiveChanged;

  /// Called when an item could not be played.
  void Function(String messageId, Object error)? onError;

  TtsPlayer({AudioPlayer? player})
    : _player = player ?? AudioPlayer(playerId: 'glaze.tts') {
    _subs.add(_player.onPlayerComplete.listen((_) => _advance()));
    _subs.add(
      _player.onPositionChanged.listen((pos) {
        final item = _current;
        if (item == null || item.path == null) return;
        onProgress?.call(item.messageId, item.offsetMs + pos.inMilliseconds);
      }),
    );
  }

  String? get activeMessageId => _current?.messageId;

  bool get isBusy => _current != null || _queue.isNotEmpty;

  /// Whether anything of [messageId] is playing or waiting.
  bool hasMessage(String messageId) =>
      _current?.messageId == messageId ||
      _queue.any((i) => i.messageId == messageId);

  Future<void> setRate(double rate) async {
    _rate = rate;
    if (_current?.path != null) {
      try {
        await _player.setPlaybackRate(rate);
      } catch (_) {}
    }
  }

  void enqueue(TtsPlayItem item) {
    _queue.add(item);
    if (_current == null) _advance();
  }

  Future<void> _advance() async {
    final finished = _current;
    _current = null;
    if (_queue.isEmpty) {
      if (finished != null) onActiveChanged?.call(null);
      return;
    }
    final item = _queue.removeFirst();
    _current = item;
    final epoch = _epoch;
    if (finished?.messageId != item.messageId) {
      onActiveChanged?.call(item.messageId);
    }
    try {
      if (item.path != null) {
        await _player.setReleaseMode(ReleaseMode.stop);
        await _player.play(DeviceFileSource(item.path!));
        if (_rate != 1) await _player.setPlaybackRate(_rate);
      } else {
        await item.speak!();
        if (epoch == _epoch) unawaited(_advance());
      }
    } catch (e) {
      debugPrint('[TTS] playback failed: $e');
      if (epoch != _epoch) return;
      onError?.call(item.messageId, e);
      unawaited(_advance());
    }
  }

  /// Stops everything and empties the queue.
  Future<void> stopAll() async {
    _epoch++;
    final current = _current;
    _queue.clear();
    _current = null;
    try {
      if (current?.path != null) await _player.stop();
      await current?.stopSpeaking?.call();
    } catch (_) {}
    if (current != null) onActiveChanged?.call(null);
  }

  Future<void> dispose() async {
    await stopAll();
    for (final s in _subs) {
      await s.cancel();
    }
    await _player.dispose();
  }
}
