import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/utils/error_format.dart';
import '../models/tts_pill_state.dart';
import '../models/tts_settings.dart';
import '../models/tts_types.dart';
import '../providers/tts_provider.dart';
import '../providers/tts_provider_registry.dart';
import 'tts_audio_analysis.dart';
import 'tts_audio_cache.dart';
import 'tts_planner.dart';
import 'tts_player.dart';
import 'tts_voice_resolver.dart';

/// Decodes compressed audio (MP3, Ogg…) into duration and peaks. Provided by
/// the chat WebView, whose audio decoder handles every format the platform
/// can play.
typedef TtsCompressedAnalyzer =
    Future<TtsClipInfo?> Function(Uint8List bytes, String mime);

sealed class TtsEngineEvent {
  const TtsEngineEvent();
}

/// A message's pill changed.
class TtsStateEvent extends TtsEngineEvent {
  final String messageId;
  final TtsPillState state;
  const TtsStateEvent(this.messageId, this.state);
}

/// Playback position within a message.
class TtsProgressEvent extends TtsEngineEvent {
  final String messageId;
  final int positionMs;
  final int? durationMs;
  const TtsProgressEvent(this.messageId, this.positionMs, this.durationMs);
}

/// Generation or playback failed; [message] is user-readable.
class TtsErrorEvent extends TtsEngineEvent {
  final String messageId;
  final String message;
  const TtsErrorEvent(this.messageId, this.message);
}

class _Job {
  final TtsMessageInput input;
  final bool autoplay;

  /// Clips already spoken while the reply streamed; generated for the pill
  /// but not played again.
  final Set<String> skipPlayback;
  const _Job(this.input, {required this.autoplay, this.skipPlayback = const {}});
}

/// The TTS pipeline: plan → generate (one job at a time) → play in order.
///
/// Two queues, as in SillyTavern: jobs wait here for synthesis, finished
/// clips wait in [TtsPlayer] for their turn on the speaker. Each message's
/// pill state is tracked here and announced through [events].
class TtsEngine {
  final TtsProviderRegistry registry;
  final TtsAudioCache cache;
  final TtsPlayer player;
  final TtsVoiceCatalog catalog;
  late final TtsPlanner _planner = TtsPlanner(TtsVoiceResolver(catalog));

  TtsSettings _settings = const TtsSettings();
  final Map<String, TtsPillState> _states = {};
  final Map<String, int> _durations = {};
  final Queue<_Job> _jobs = Queue();
  final _events = StreamController<TtsEngineEvent>.broadcast();
  String? _processingId;
  bool _working = false;
  int _epoch = 0;
  CancelToken _cancel = CancelToken();

  /// Set by the open chat; see [TtsCompressedAnalyzer].
  TtsCompressedAnalyzer? analyzer;

  // Streaming narration: how much of the live reply has been handed off,
  // and which clips that produced.
  int _streamConsumed = 0;
  final Set<String> _streamKeys = {};

  TtsEngine({
    required this.registry,
    required this.cache,
    required this.player,
    TtsVoiceCatalog? catalog,
  }) : catalog = catalog ?? TtsVoiceCatalog() {
    player.onActiveChanged = _onActiveChanged;
    player.onProgress = (id, pos) =>
        _events.add(TtsProgressEvent(id, pos, _durations[id]));
    player.onError = (id, e) => _fail(id, e);
  }

  Stream<TtsEngineEvent> get events => _events.stream;
  TtsSettings get settings => _settings;
  TtsProvider? get provider => registry.byId(_settings.providerId);
  String? get activeMessageId => player.activeMessageId;

  void updateSettings(TtsSettings next) {
    final prev = _settings;
    _settings = next;
    if (prev.providerId != next.providerId ||
        !mapEquals(
          prev.settingsFor(prev.providerId),
          next.settingsFor(next.providerId),
        )) {
      catalog.invalidate();
    }
    if (prev.playbackRate != next.playbackRate) {
      unawaited(player.setRate(next.playbackRate));
    }
    if (prev.enabled && !next.enabled) unawaited(stop());
  }

  TtsPillState stateOf(String messageId) =>
      _states[messageId] ?? TtsPillState.idle;

  /// Works out the pill for a message without generating anything: ready
  /// when every clip is cached, idle otherwise, none when nothing would be
  /// spoken.
  Future<TtsPillState> describe(TtsMessageInput input) async {
    final current = _states[input.messageId];
    if (current != null &&
        (current.status == TtsPillStatus.loading ||
            current.status == TtsPillStatus.playing)) {
      return current;
    }
    final p = provider;
    if (p == null) return TtsPillState.none;
    TtsPillState state;
    try {
      final plan = await _planner.plan(input, _settings, p);
      if (plan == null) {
        state = TtsPillState.none;
      } else if (!p.producesAudio) {
        state = TtsPillState.idle;
      } else {
        state = _cachedState(plan) ?? TtsPillState.idle;
      }
    } catch (_) {
      // A provider that is not set up yet still gets a pill; tapping it
      // reports what is missing.
      state = TtsPillState.idle;
    }
    final live = _states[input.messageId];
    if (live != null &&
        (live.status == TtsPillStatus.loading ||
            live.status == TtsPillStatus.playing)) {
      return live;
    }
    _states[input.messageId] = state;
    if (state.durationMs != null) _durations[input.messageId] = state.durationMs!;
    return state;
  }

  TtsPillState? _cachedState(TtsMessagePlan plan) {
    final persistent = _settings.cacheEnabled;
    final infos = <TtsClipInfo>[];
    for (final clip in plan.clips) {
      if (!cache.contains(clip.key, usePersistent: persistent)) return null;
      final info = cache.infoOf(clip.key, usePersistent: persistent);
      if (info != null) infos.add(info);
    }
    if (infos.length != plan.clips.length) {
      return const TtsPillState(TtsPillStatus.ready);
    }
    return TtsPillState(
      TtsPillStatus.ready,
      durationMs: infos.fold<int>(0, (s, i) => s + i.durationMs),
      peaks: TtsAudioAnalysis.mergePeaks(infos),
    );
  }

  bool isActive(String messageId) =>
      _processingId == messageId ||
      player.hasMessage(messageId) ||
      _jobs.any((j) => j.input.messageId == messageId);

  /// Pill tap: stop if this message is playing or being made, otherwise
  /// stop everything else and play it.
  Future<void> toggle(TtsMessageInput input) async {
    if (isActive(input.messageId)) {
      await stop();
      return;
    }
    await play(input);
  }

  /// Plays a message now, dropping whatever was queued.
  Future<void> play(TtsMessageInput input) async {
    await stop();
    _jobs.add(_Job(input, autoplay: true));
    unawaited(_run());
  }

  /// Queues a message behind whatever is playing (automatic narration).
  void enqueue(TtsMessageInput input, {Set<String> skipPlayback = const {}}) {
    if (_jobs.any((j) => j.input.messageId == input.messageId)) return;
    _jobs.add(_Job(input, autoplay: true, skipPlayback: skipPlayback));
    unawaited(_run());
  }

  /// Stops playback and drops pending work.
  Future<void> stop() async {
    _epoch++;
    _cancel.cancel();
    _cancel = CancelToken();
    final pending = [
      ..._jobs.map((j) => j.input.messageId),
      ?_processingId,
    ];
    _jobs.clear();
    _processingId = null;
    await player.stopAll();
    for (final id in pending) {
      final s = _states[id];
      if (s != null && s.status == TtsPillStatus.loading) {
        _setState(id, s.durationMs != null ? s.withStatus(TtsPillStatus.ready) : TtsPillState.idle);
      }
    }
  }

  // ── Streaming narration ────────────────────────────────────────────────

  /// Feeds the reply as it streams; every finished paragraph is queued
  /// straight away.
  void streamUpdate(String text, {required String speakerKey}) {
    if (text.length < _streamConsumed) _streamConsumed = 0;
    var end = text.indexOf('\n', _streamConsumed);
    while (end != -1) {
      final chunk = text.substring(_streamConsumed, end);
      _streamConsumed = end + 1;
      if (chunk.trim().isNotEmpty) {
        _jobs.add(
          _Job(
            TtsMessageInput(
              messageId: '__tts_stream_${_streamKeys.length}_$_streamConsumed',
              text: chunk,
              speakerKey: speakerKey,
            ),
            autoplay: true,
          ),
        );
        unawaited(_run());
      }
      end = text.indexOf('\n', _streamConsumed);
    }
  }

  /// Ends a streamed reply and returns the clip keys already spoken, so the
  /// final message only plays what is left.
  Set<String> finishStream() {
    final keys = Set<String>.of(_streamKeys);
    _streamKeys.clear();
    _streamConsumed = 0;
    return keys;
  }

  bool get isStreaming => _streamConsumed > 0;

  // ── Worker ─────────────────────────────────────────────────────────────

  Future<void> _run() async {
    if (_working) return;
    _working = true;
    try {
      while (_jobs.isNotEmpty) {
        final job = _jobs.removeFirst();
        _processingId = job.input.messageId;
        await _process(job);
        _processingId = null;
      }
    } finally {
      _working = false;
    }
  }

  Future<void> _process(_Job job) async {
    final epoch = _epoch;
    final id = job.input.messageId;
    final isStreamChunk = id.startsWith('__tts_stream_');
    final p = provider;
    try {
      if (p == null) throw const TtsNotConfigured('No TTS provider selected');
      final plan = await _planner.plan(
        job.input,
        _settings,
        p,
        forceParagraphs: _settings.narrateWhileStreaming,
      );
      if (epoch != _epoch) return;
      if (plan == null) {
        if (!isStreamChunk) _setState(id, TtsPillState.none);
        return;
      }
      if (!p.producesAudio) {
        for (final clip in plan.clips) {
          player.enqueue(
            TtsPlayItem.direct(
              messageId: id,
              speak: () => p.speak(clip.text, clip.voiceId, plan.config),
              stopSpeaking: p.stopSpeaking,
            ),
          );
        }
        return;
      }
      if (!isStreamChunk && _states[id]?.status != TtsPillStatus.playing) {
        _setState(id, stateOf(id).withStatus(TtsPillStatus.loading));
      }
      final persistent = _settings.cacheEnabled;
      final infos = <TtsClipInfo?>[];
      var offset = 0;
      for (final clip in plan.clips) {
        var cached = await cache.lookup(clip.key, usePersistent: persistent);
        if (cached == null) {
          final raw = await p.generate(
            clip.text,
            clip.voiceId,
            plan.config,
            speakerKey: clip.speakerKey,
            cancelToken: _cancel,
          );
          if (epoch != _epoch) return;
          final audio = _normalize(raw);
          final info = await _analyze(audio);
          cached = await cache.put(clip.key, audio, info, persistent: persistent);
        }
        if (epoch != _epoch) return;
        if (isStreamChunk) _streamKeys.add(clip.key);
        if (job.autoplay && !job.skipPlayback.contains(clip.key)) {
          player.enqueue(
            TtsPlayItem.file(messageId: id, offsetMs: offset, path: cached.path),
          );
        }
        offset += cached.info?.durationMs ?? 0;
        infos.add(cached.info);
      }
      if (isStreamChunk) return;
      final known = infos.whereType<TtsClipInfo>().toList();
      final complete = known.length == infos.length;
      final duration = complete ? offset : null;
      if (duration != null) _durations[id] = duration;
      final status = player.hasMessage(id)
          ? TtsPillStatus.playing
          : TtsPillStatus.ready;
      _setState(
        id,
        TtsPillState(
          status,
          durationMs: duration,
          peaks: complete ? TtsAudioAnalysis.mergePeaks(known) : const [],
        ),
      );
    } catch (e) {
      if (epoch != _epoch) return;
      if (e is DioException && e.type == DioExceptionType.cancel) return;
      _fail(id, e);
    }
  }

  void _fail(String id, Object e) {
    final message = e is DioException ? formatError(e) : e.toString();
    debugPrint('[TTS] $id failed: $message');
    if (!id.startsWith('__tts_stream_')) {
      _setState(id, TtsPillState(TtsPillStatus.error, error: message));
    }
    _events.add(TtsErrorEvent(id, message));
  }

  TtsAudio _normalize(TtsAudio audio) {
    final mime = audio.mime.toLowerCase();
    if (!mime.startsWith('audio/pcm') && !mime.startsWith('audio/l16')) {
      return audio;
    }
    final rate = int.tryParse(
          RegExp(r'rate=(\d+)').firstMatch(mime)?.group(1) ?? '',
        ) ??
        24000;
    return TtsAudio(
      TtsAudioAnalysis.pcm16ToWav(audio.bytes, sampleRate: rate),
      'audio/wav',
    );
  }

  Future<TtsClipInfo?> _analyze(TtsAudio audio) async {
    if (audio.extension == 'wav') {
      final info = TtsAudioAnalysis.analyzeWav(audio.bytes);
      if (info != null) return info;
    }
    final decode = analyzer;
    if (decode == null) return null;
    try {
      return await decode(audio.bytes, audio.mime);
    } catch (e) {
      debugPrint('[TTS] audio analysis failed: $e');
      return null;
    }
  }

  void _onActiveChanged(String? messageId) {
    for (final entry in _states.entries.toList()) {
      if (entry.value.status == TtsPillStatus.playing &&
          entry.key != messageId) {
        final stillMaking =
            _processingId == entry.key ||
            _jobs.any((j) => j.input.messageId == entry.key);
        _setState(
          entry.key,
          entry.value.withStatus(
            stillMaking ? TtsPillStatus.loading : TtsPillStatus.ready,
          ),
        );
      }
    }
    if (messageId != null && !messageId.startsWith('__tts_stream_')) {
      _setState(messageId, stateOf(messageId).withStatus(TtsPillStatus.playing));
    }
  }

  void _setState(String id, TtsPillState state) {
    if (_states[id] == state) return;
    _states[id] = state;
    _events.add(TtsStateEvent(id, state));
  }

  /// Forgets per-message state (chat closed).
  void forgetMessages() {
    _states.removeWhere(
      (id, s) =>
          s.status != TtsPillStatus.loading && s.status != TtsPillStatus.playing,
    );
  }

  Future<void> dispose() async {
    await stop();
    await player.dispose();
    await _events.close();
  }
}
