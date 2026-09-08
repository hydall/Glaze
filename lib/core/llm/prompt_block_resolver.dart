import '../models/character.dart';
import '../models/chat_message.dart';
import '../models/persona.dart';
import 'macro_engine.dart';
import 'preset_macro_attribution.dart';

class NotifyObj {
  Map<String, String> sessionVars = {};
  Map<String, String> globalVars = {};
  bool varsChanged = false;
}

class ResolvedContent {
  final String role;
  /// Fully expanded content — this is what actually gets sent to the LLM
  /// (all macros resolved: {{summary}}, {{memory}}, {{lorebooks}}, etc.).
  final String content;
  /// Preset-only content for token accounting: external injections (character,
  /// persona, memory, lorebooks, summary, guidance) are blanked; in-preset
  /// setvar/getvar/globalvars still count. See docs/INVARIANTS.md INV-PS5.
  final String contentForAccounting;
  const ResolvedContent({
    required this.role,
    required this.content,
    required this.contentForAccounting,
  });
}

ResolvedContent? resolveBlockContent({
  required String id,
  required String rawContent,
  required String role,
  required Character char,
  required Persona? persona,
  required MacroContext macroCtx,
  required Map<String, String> sessionVars,
  required Map<String, String> globalVars,
  required NotifyObj notifyObj,
  required String? summaryContent,
  required String? summaryPrefix,
  AuthorsNote? authorsNote,
}) {
  String content;
  String resolvedRole = role;

  switch (id) {
    case 'char_card':
      content = rawContent.isNotEmpty ? rawContent : (char.description ?? '');
    case 'char_personality':
      content = char.personality ?? '';
    case 'scenario':
      content = char.scenario ?? '';
    case 'example_dialogue':
      content = char.mesExample ?? '';
    case 'user_persona':
      content = _userPersonaContent(persona);
    case 'chat_history':
      return ResolvedContent(role: resolvedRole, content: '', contentForAccounting: '');
    case 'summary':
      if (summaryContent != null && summaryContent.isNotEmpty) {
        final prefix = summaryPrefix ?? 'Summary: ';
        content = '[$prefix$summaryContent]';
      } else {
        return null;
      }
    case 'guided_generation':
      if (macroCtx.guidanceText == null || macroCtx.guidanceText!.trim().isEmpty) {
        return null;
      }
      content = rawContent;
    case 'authors_note':
      if (authorsNote == null || !authorsNote.enabled || authorsNote.content.isEmpty) {
        return null;
      }
      // Only content + enabled are session-scoped. Role/depth/insertion mode
      // belong to the preset block, so keep [resolvedRole] = the block's role.
      content = authorsNote.content;
    case 'memory':
      // Dedicated Memory Book hard block. Acts as the sink for memory content
      // exactly like the {{memory}} macro: macroCtx.memoryContent is the
      // deferred placeholder while memory is finalized after the context
      // cutoff, then PromptBuilder swaps in the real packed memory. When no
      // memory is selected the content is null and the block is skipped.
      final memory = macroCtx.memoryContent;
      if (memory == null || memory.isEmpty) return null;
      content = memory;
    default:
      content = rawContent;
  }

  if (content.isEmpty) return null;

  // Fully-expanded content (everything resolved, what the LLM actually sees).
  final macroResult = replaceMacros(content, macroCtx);
  if (macroResult.varsChanged) {
    notifyObj.sessionVars = macroResult.sessionVars;
    notifyObj.globalVars = macroResult.globalVars;
    notifyObj.varsChanged = true;
  }

  if (macroResult.text.trim().isEmpty) {
    final setvarPayload = setvarDefinitionsForAccounting(content);
    if (setvarPayload.isEmpty) return null;
    return ResolvedContent(
      role: resolvedRole,
      content: macroResult.text,
      contentForAccounting: setvarPayload,
    );
  }

  // Preset-only accounting: blank external injections; keep in-preset vars.
  final accountingSource =
      isPresetExternalInjectionBlock(id) ? rawContent : content;
  final accountingResult =
      replaceMacros(accountingSource, macroCtx.forPresetAccounting());

  return ResolvedContent(
    role: resolvedRole,
    content: macroResult.text,
    contentForAccounting: accountingResult.text,
  );
}

String _userPersonaContent(Persona? persona) {
  final buf = StringBuffer();
  buf.writeln('User Name: ${persona?.name ?? 'User'}');
  if (persona?.prompt != null && persona!.prompt!.isNotEmpty) {
    buf.writeln('User Description: ${persona.prompt}');
  }
  return buf.toString().trimRight();
}
