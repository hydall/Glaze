import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/state/character_provider.dart';
import '../../../core/state/persona_resolution.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../chat/bridge/chat_bridge_controller.dart';
import '../../chat/bridge/chat_bridge_registry.dart';
import '../../chat/chat_provider.dart';
import '../../chat/chat_state.dart';
import '../models/tts_pill_state.dart';
import '../models/tts_settings.dart';
import '../services/tts_audio_analysis.dart';
import '../services/tts_engine.dart';
import '../services/tts_message_inputs.dart';
import '../services/tts_voice_resolver.dart';
import '../tts_provider.dart';

/// Speaks [messageId] now, for the message's long-press menu. Stops
/// whatever was playing first.
void speakMessageNow(WidgetRef ref, String charId, String messageId) {
  final engine = ref.read(ttsEngineProvider).value;
  if (engine == null) return;
  final character = ref.read(characterByIdProvider(charId));
  final session = ref.read(chatProvider(charId)).value?.session;
  final persona = ref.read(
    effectivePersonaForChatProvider((charId: charId, sessionId: session?.id)),
  );
  final inputs = TtsMessageInputs(
    charId: charId,
    charName: character?.name ?? '',
    userName: persona?.name ?? 'User',
    personaId: persona?.id,
  );
  ChatMessage? message;
  for (final m
      in ref.read(chatProvider(charId)).value?.messages ??
          const <ChatMessage>[]) {
    if (m.id == messageId) {
      message = m;
      break;
    }
  }
  if (message == null) return;
  final input = inputs.of(message);
  if (input == null) return;
  unawaited(engine.play(input));
}

/// Connects one open chat to the TTS engine: draws the voice pills, answers
/// taps on them, speaks new replies on its own and feeds a streaming reply
/// paragraph by paragraph. Renders nothing.
class TtsChatBinding extends ConsumerStatefulWidget {
  final String charId;
  const TtsChatBinding({super.key, required this.charId});

  @override
  ConsumerState<TtsChatBinding> createState() => _TtsChatBindingState();
}

class _TtsChatBindingState extends ConsumerState<TtsChatBinding> {
  TtsEngine? _engine;
  ChatBridgeController? _bridge;
  StreamSubscription<TtsEngineEvent>? _events;
  TtsCompressedAnalyzer? _analyzer;

  /// Message id → last pushed state, and the content it was computed for.
  final Map<String, TtsPillState> _pushed = {};
  final Map<String, String> _describedText = {};
  int _syncEpoch = 0;

  /// Ids present when the chat opened or already handled, so old messages
  /// never start speaking on their own.
  final Set<String> _seenIds = {};
  bool _seeded = false;
  bool _wasBusy = false;

  /// Replies already narrated automatically, as `id|content`.
  final Set<String> _autoSpoken = {};

  TtsSettings get _settings =>
      ref.read(ttsSettingsProvider).value ?? const TtsSettings();

  @override
  void dispose() {
    unawaited(_events?.cancel());
    final bridge = _bridge;
    if (bridge != null) bridge.onTtsToggle = null;
    final engine = _engine;
    if (engine != null) {
      if (identical(engine.analyzer, _analyzer)) engine.analyzer = null;
      if (_settings.enabled) unawaited(engine.stop());
      engine.finishStream();
      unawaited(engine.cache.clearSession());
    }
    super.dispose();
  }

  // ── Inputs ──────────────────────────────────────────────────────────────

  TtsMessageInputs _inputs() {
    final charId = widget.charId;
    final character = ref.read(characterByIdProvider(charId));
    final session = ref.read(chatProvider(charId)).value?.session;
    final persona = ref.read(
      effectivePersonaForChatProvider((charId: charId, sessionId: session?.id)),
    );
    return TtsMessageInputs(
      charId: charId,
      charName: character?.name ?? '',
      userName: persona?.name ?? 'User',
      personaId: persona?.id,
    );
  }

  List<ChatMessage> _messages() =>
      ref.read(chatProvider(widget.charId)).value?.visibleMessages ?? const [];

  ChatMessage? _messageById(String id) {
    final all = ref.read(chatProvider(widget.charId)).value?.messages;
    if (all == null) return null;
    for (final m in all) {
      if (m.id == id) return m;
    }
    return null;
  }

  // ── Engine / bridge wiring ──────────────────────────────────────────────

  void _attachEngine(TtsEngine engine) {
    if (identical(_engine, engine)) return;
    unawaited(_events?.cancel());
    _engine = engine;
    _events = engine.events.listen(_onEngineEvent);
    _attachAnalyzer();
  }

  void _attachBridge(ChatBridgeController? bridge) {
    if (identical(_bridge, bridge)) return;
    _bridge?.onTtsToggle = null;
    _bridge = bridge;
    _pushed.clear();
    _describedText.clear();
    if (bridge != null) bridge.onTtsToggle = _onToggle;
    _attachAnalyzer();
    unawaited(_fullSync());
  }

  void _attachAnalyzer() {
    final engine = _engine;
    final bridge = _bridge;
    if (engine == null || bridge == null) return;
    _analyzer = (bytes, mime) async {
      final r = await bridge.tts.decodePeaks(bytes, mime, buckets: ttsPeakCount);
      return r == null
          ? null
          : TtsClipInfo(durationMs: r.durationMs, peaks: r.peaks);
    };
    engine.analyzer = _analyzer;
  }

  void _onToggle(String messageId) {
    final engine = _engine;
    final message = _messageById(messageId);
    if (engine == null || message == null) return;
    final input = _inputs().of(message);
    if (input == null) return;
    unawaited(engine.toggle(input));
  }

  /// Speaks a message from the long-press menu.
  void speak(String messageId) => _onToggle(messageId);

  void _onEngineEvent(TtsEngineEvent event) {
    final bridge = _bridge;
    switch (event) {
      case TtsStateEvent(:final messageId, :final state):
        if (bridge == null || !_pushed.containsKey(messageId)) return;
        _pushed[messageId] = state;
        unawaited(bridge.tts.patch({messageId: state.toJson()}));
      case TtsProgressEvent(:final messageId, :final positionMs, :final durationMs):
        if (bridge == null || !_pushed.containsKey(messageId)) return;
        unawaited(bridge.tts.progress(messageId, positionMs, durationMs));
      case TtsErrorEvent(:final messageId, :final message):
        if (!mounted) return;
        if (_pushed.containsKey(messageId) ||
            messageId.startsWith('__tts_stream_')) {
          GlazeToast.show(context, 'TTS: $message', isError: true);
        }
      case TtsInvalidatedEvent():
        _describedText.clear();
        unawaited(_fullSync());
    }
  }

  // ── Pills ───────────────────────────────────────────────────────────────

  /// Recomputes every pill and replaces the page's whole TTS state.
  Future<void> _fullSync() async {
    final bridge = _bridge;
    final engine = _engine;
    if (bridge == null || engine == null) return;
    final epoch = ++_syncEpoch;
    final settings = _settings;
    if (!settings.enabled) {
      _pushed.clear();
      await bridge.tts.configure(enabled: false, states: const {});
      return;
    }
    final inputs = _inputs();
    final states = <String, TtsPillState>{};
    final texts = <String, String>{};
    for (final m in _messages()) {
      final input = inputs.of(m);
      if (input == null) continue;
      states[m.id] = await engine.describe(input);
      texts[m.id] = input.text;
      if (epoch != _syncEpoch || !mounted) return;
    }
    _pushed
      ..clear()
      ..addAll(states);
    _describedText
      ..clear()
      ..addAll(texts);
    await bridge.tts.configure(
      enabled: true,
      states: {for (final e in states.entries) e.key: e.value.toJson()},
    );
  }

  /// Recomputes pills whose text changed or that are new.
  Future<void> _incrementalSync() async {
    final bridge = _bridge;
    final engine = _engine;
    if (bridge == null || engine == null || !_settings.enabled) return;
    final epoch = _syncEpoch;
    final inputs = _inputs();
    final patch = <String, Map<String, dynamic>>{};
    for (final m in _messages()) {
      final input = inputs.of(m);
      if (input == null) continue;
      if (_describedText[m.id] == input.text) continue;
      final state = await engine.describe(input);
      if (epoch != _syncEpoch || !mounted) return;
      _describedText[m.id] = input.text;
      _pushed[m.id] = state;
      patch[m.id] = state.toJson();
    }
    await bridge.tts.patch(patch);
  }

  // ── Automatic narration ─────────────────────────────────────────────────

  void _onChatState(ChatState? state) {
    if (state == null) return;
    final messages = state.messages;
    final busy =
        state.isGenerating || state.isPostGenRunning || state.isSendPending;
    if (!_seeded) {
      _seeded = true;
      _seenIds.addAll(messages.map((m) => m.id));
      _wasBusy = busy;
      return;
    }
    final settings = _settings;
    final auto = settings.enabled && settings.autoGeneration;
    final engine = _engine;
    final inputs = _inputs();

    // New user messages are read as soon as they land.
    for (final m in messages) {
      if (!_seenIds.add(m.id)) continue;
      if (auto && settings.narrateUser && m.role == 'user' && engine != null) {
        final input = inputs.of(m);
        if (input != null) engine.enqueue(input);
      }
    }

    // A reply is read once the run (and any post-processing) is over.
    if (_wasBusy && !busy && engine != null) {
      final spokenInStream = engine.finishStream();
      final last = messages.isEmpty ? null : messages.last;
      if (auto && last != null && last.role != 'user') {
        final input = inputs.of(last);
        if (input != null && _autoSpoken.add('${last.id}|${input.text}')) {
          engine.enqueue(input, skipPlayback: spokenInStream);
        }
      }
    }
    _wasBusy = busy;
  }

  void _onStreaming(StreamingState stream) {
    final settings = _settings;
    final engine = _engine;
    if (engine == null ||
        !settings.enabled ||
        !settings.autoGeneration ||
        !settings.narrateWhileStreaming ||
        stream.targetMessageId != null ||
        stream.text.isEmpty) {
      return;
    }
    engine.streamUpdate(
      _inputs().textOf(stream.text),
      speakerKey: ttsCharKey(widget.charId),
    );
  }

  TtsSettings? _lastSettings;
  bool _initialized = false;

  @override
  Widget build(BuildContext context) {
    final charId = widget.charId;
    final engine = ref.watch(ttsEngineProvider).value;
    if (engine != null) _attachEngine(engine);

    // The bridge may already exist, or arrive once the WebView is up.
    final bridge = ref.watch(chatBridgeRegistryProvider(charId));
    if (!identical(_bridge, bridge)) {
      _attachBridge(bridge);
      if (_initialized) unawaited(_fullSync());
    }

    final settings = ref.watch(ttsSettingsProvider).value;
    if (settings != null && settings != _lastSettings) {
      final before = _lastSettings;
      _lastSettings = settings;
      if (before != null && before.enabled && !settings.enabled) {
        unawaited(_engine?.stop());
      }
      if (_initialized) {
        _describedText.clear();
        unawaited(_fullSync());
      }
    }

    if (!_initialized) {
      _initialized = true;
      // Seed from whatever is already loaded before listeners can fire.
      _onChatState(ref.read(chatProvider(charId)).value);
      unawaited(_fullSync());
    }

    ref.listen<AsyncValue<ChatState>>(chatProvider(charId), (prev, next) {
      final state = next.value;
      final sessionChanged =
          prev?.value?.session?.id != state?.session?.id;
      _onChatState(state);
      if (sessionChanged) {
        unawaited(_engine?.stop());
        _seeded = false;
        _seenIds.clear();
        _onChatState(state);
        _describedText.clear();
        unawaited(_fullSync());
      } else {
        unawaited(_incrementalSync());
      }
    });
    ref.listen<StreamingState>(
      streamingStateProvider(charId),
      (_, next) => _onStreaming(next),
    );
    return const SizedBox.shrink();
  }
}
