import '../../models/chat_message.dart';
import '../history_assembler.dart';
import '../macro_engine.dart';
import '../prompt/selective_ledger_projection_filter.dart';
import '../prompt/exact_lorebook_manifest.dart';

enum StudioContextSlot {
  characterCard,
  characterPersonality,
  userPersona,
  scenario,
  exampleDialogue,
  authorsNote,
  summary,
  memory,
  loreBefore,
  loreAfter,
  loreMacro,
  recalledMessages,
  characterKnowledge,
  studioSessionState,
  runtimeDynamic,
  staticContext,
  dynamicContext,
}

final class StudioContextDiagnostics {
  final List<TriggeredEntry> triggeredLorebooks;
  final List<TriggeredEntry> triggeredMemories;
  final Map<String, dynamic> memoryCoverage;
  final int vectorLoreTokens;
  final Set<String> visibleMessageIds;
  final List<LedgerProjectionDiagnostic> ledgerProjectionDiagnostics;
  final String ledgerInjectionIdentity;
  final ExactLorebookManifest? exactLorebookManifest;

  const StudioContextDiagnostics({
    this.triggeredLorebooks = const [],
    this.triggeredMemories = const [],
    this.memoryCoverage = const {},
    this.vectorLoreTokens = 0,
    this.visibleMessageIds = const {},
    this.ledgerProjectionDiagnostics = const [],
    this.ledgerInjectionIdentity = '',
    this.exactLorebookManifest,
  });
}

/// Preset-independent context prepared for one explicit Studio source window.
final class StudioContext {
  final Map<StudioContextSlot, List<PromptMessage>> slots;
  final List<PromptMessage> history;
  final Map<String, String> sessionVars;
  final Map<String, String> globalVars;
  final MacroContext macroContext;
  final StudioContextDiagnostics diagnostics;

  /// Continue mode: the system turn the final writer must see immediately
  /// after the assistant reply it is extending. Null on every other path, and
  /// never shown to the controller agents — they analyse the scene, they do
  /// not extend the reply. See `docs/INVARIANTS.md` INV-CM3.
  final String? continueInstruction;

  const StudioContext({
    required this.slots,
    required this.history,
    required this.sessionVars,
    required this.globalVars,
    required this.macroContext,
    required this.diagnostics,
    this.continueInstruction,
  });

  List<PromptMessage> messagesFor(StudioContextSlot slot) => switch (slot) {
    StudioContextSlot.staticContext => staticContext,
    StudioContextSlot.dynamicContext => dynamicContext,
    _ => slots[slot] ?? const <PromptMessage>[],
  };

  String join(StudioContextSlot slot) =>
      messagesFor(slot).map((message) => message.content).join('\n\n');

  List<PromptMessage> get staticContext => [
    ...messagesFor(StudioContextSlot.characterCard),
    ...messagesFor(StudioContextSlot.characterPersonality),
    ...messagesFor(StudioContextSlot.userPersona),
    ...messagesFor(StudioContextSlot.scenario),
    ...messagesFor(StudioContextSlot.exampleDialogue),
    ...messagesFor(StudioContextSlot.authorsNote),
  ];

  List<PromptMessage> get dynamicContext => [
    ...messagesFor(StudioContextSlot.characterKnowledge),
    ...messagesFor(StudioContextSlot.studioSessionState),
    ...messagesFor(StudioContextSlot.summary),
    ...messagesFor(StudioContextSlot.memory),
    ...messagesFor(StudioContextSlot.loreBefore),
    ...messagesFor(StudioContextSlot.loreAfter),
    ...messagesFor(StudioContextSlot.loreMacro),
    ...messagesFor(StudioContextSlot.recalledMessages),
    ...messagesFor(StudioContextSlot.runtimeDynamic),
  ];
}
