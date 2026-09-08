import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../core/llm/prompt/lorebook_vector_searcher.dart';
import '../../../core/llm/prompt_builder.dart';
import '../../../core/llm/prompt_inputs_collector.dart';
import '../../../core/llm/prompt_payload_builder.dart';
import '../../../core/models/chat_message.dart';
import '../../extensions/services/ext_blocks_prompt_injection.dart';
import '../../extensions/services/runtime_prompt_injection_service.dart';
import '../../settings/api_list_provider.dart';

List<RuntimePromptBlock> mapRuntimePromptBlocks(
  Iterable<RuntimePromptInjection> blocks,
) => List.unmodifiable(
  blocks.map(
    (block) => RuntimePromptBlock(
      id: block.id,
      content: block.content,
      depth: block.depth,
      role: block.role,
    ),
  ),
);

final promptInputsCollectorProvider = Provider<PromptInputsCollector>((ref) {
  return PromptInputsCollector(
    ref,
    initializeApiConfigs: () async {
      await ref.read(apiListProvider.future);
    },
    readActiveApiConfig: () => ref.read(activeApiConfigProvider),
    injectHistory: ({required sessionId, required messages}) => ref
        .read(extBlocksPromptInjectionProvider)
        .injectIntoHistory(sessionId: sessionId, messages: messages),
    readRuntimePromptBlocks: (sessionId) => mapRuntimePromptBlocks(
      ref.read(runtimePromptInjectionProvider.notifier).bySession(sessionId),
    ),
  );
});

final promptPayloadBuilderProvider = Provider<PromptPayloadBuilder>((ref) {
  Future<void> initializeApiConfigs() async {
    await ref.read(apiListProvider.future);
  }

  Future<List<ChatMessage>> injectHistory({
    required String sessionId,
    required List<ChatMessage> messages,
  }) => ref
      .read(extBlocksPromptInjectionProvider)
      .injectIntoHistory(sessionId: sessionId, messages: messages);
  List<RuntimePromptBlock> readRuntimePromptBlocks(String sessionId) =>
      mapRuntimePromptBlocks(
        ref.read(runtimePromptInjectionProvider.notifier).bySession(sessionId),
      );

  return PromptPayloadBuilder(
    ref,
    inputsCollector: ref.watch(promptInputsCollectorProvider),
    initializeApiConfigs: initializeApiConfigs,
    readActiveApiConfig: () => ref.read(activeApiConfigProvider),
    injectHistory: injectHistory,
    readRuntimePromptBlocks: readRuntimePromptBlocks,
    onLorebookVectorSearchDiagnostic: (diagnostic) {
      ref.read(lorebookVectorSearchDiagnosticProvider.notifier).state =
          diagnostic;
    },
  );
});

final lorebookVectorSearchDiagnosticProvider =
    StateProvider<LorebookVectorSearchDiagnostic?>((ref) => null);
