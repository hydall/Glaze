import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/llm/prompt/main_model_context_snapshot.dart';
import 'package:glaze_flutter/features/chat/abort_handler.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/services/stages/ext_blocks_stage.dart';
import 'package:glaze_flutter/features/chat/services/stages/stage_context.dart';
import 'package:glaze_flutter/features/chat/state/post_gen_status_provider.dart';
import 'package:glaze_flutter/features/extensions/models/extensions_settings.dart';
import 'package:glaze_flutter/features/extensions/providers/extensions_settings_provider.dart';
import 'package:glaze_flutter/features/extensions/services/extension_post_gen_service.dart';

class _RecordingExtensionPostGenService extends ExtensionPostGenService {
  _RecordingExtensionPostGenService(super.ref, {this.didRun = false});

  int processCalls = 0;
  final bool didRun;

  @override
  Future<bool> processAfterGeneration({
    required String charId,
    required ChatSession session,
    required Character character,
    required Persona? persona,
    int agentSwipeId = -1,
    void Function()? onStarted,
    MainModelContextSnapshot? mainModelContextSnapshot,
  }) async {
    processCalls++;
    if (didRun) onStarted?.call();
    return didRun;
  }
}

final _extBlocksStageProvider = Provider<ExtBlocksStage>((ref) {
  late AsyncValue<ChatState> state = const AsyncData(ChatState());
  final abortHandler = AbortHandler(
    ref: ref,
    charId: 'c1',
    setState: (next) => state = next,
    getState: () => state,
    mutateSession: (_, _) async => null,
    loadSession: (_) async => null,
  );
  return ExtBlocksStage(
    StageContext(
      ref: ref,
      charId: 'c1',
      abortHandler: abortHandler,
      setState: (next) => state = next,
      getState: () => state,
    ),
  );
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ExtBlocks no-op does not publish a status', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        extensionPostGenServiceProvider.overrideWith(
          (ref) => _RecordingExtensionPostGenService(ref),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(extensionsSettingsProvider.notifier)
        .update(const ExtensionsSettings(enabled: false, activePresetId: 'p1'));

    await container
        .read(_extBlocksStageProvider)
        .launchForSwipe(
          session: const ChatSession(
            id: 's1',
            characterId: 'c1',
            sessionIndex: 0,
            sessionVars: {},
            messages: [
              ChatMessage(
                id: 'm1',
                role: 'assistant',
                content: 'Hello',
                timestamp: 1,
              ),
            ],
          ),
          character: Character(id: 'c1', name: 'Alice'),
          agentSwipeId: -1,
        );

    final service =
        container.read(extensionPostGenServiceProvider)
            as _RecordingExtensionPostGenService;
    expect(service.processCalls, 1);
    expect(
      container.read(postGenStatusProvider),
      isA<PostGenStatusState>()
          .having((state) => state.phase, 'phase', PostGenTaskPhase.idle)
          .having((state) => state.task, 'task', PostGenTask.none),
    );
  });

  test('ExtBlocks publishes done after real work starts', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        extensionPostGenServiceProvider.overrideWith(
          (ref) => _RecordingExtensionPostGenService(ref, didRun: true),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(_extBlocksStageProvider)
        .launchForSwipe(
          session: const ChatSession(
            id: 's1',
            characterId: 'c1',
            sessionIndex: 0,
            sessionVars: {},
            messages: [
              ChatMessage(
                id: 'm1',
                role: 'assistant',
                content: 'Hello',
                timestamp: 1,
              ),
            ],
          ),
          character: Character(id: 'c1', name: 'Alice'),
          agentSwipeId: -1,
        );

    expect(
      container.read(postGenStatusProvider),
      isA<PostGenStatusState>()
          .having((state) => state.phase, 'phase', PostGenTaskPhase.done)
          .having((state) => state.task, 'task', PostGenTask.extBlocks),
    );
  });
}
