import '../models/studio_regex.dart';
import 'macro_engine.dart';
import 'regex_service.dart';

List<Map<String, dynamic>> applyStudioRegexes({
  required List<Map<String, dynamic>> messages,
  required Iterable<String> stages,
  required List<StudioRegex> entries,
  required MacroContext macroContext,
}) {
  final activeStages = stages.toSet();
  final scripts = entries
      .where((entry) => entry.stages.any(activeStages.contains))
      .map((entry) => entry.script)
      .toList();
  if (scripts.isEmpty) return messages;

  final context = RegexApplyContext(
    sessionVars: macroContext.sessionVars,
    globalVars: macroContext.globalVars,
    macroContext: macroContext,
  );
  return messages.map((message) {
    final content = message['content'];
    if (content is! String) return Map<String, dynamic>.from(message);
    final role = message['role'];
    final placement = role == 'user'
        ? 1
        : ((role == 'assistant' || role == 'tool') ? 2 : 4);
    return <String, dynamic>{
      ...message,
      'content': applyRegexes(
        content,
        placement,
        2,
        scripts,
        context,
        isPrompt: true,
      ),
    };
  }).toList();
}

String applyStudioRegexesToText({
  required String text,
  required String stage,
  required List<StudioRegex> entries,
  required MacroContext macroContext,
  String role = 'user',
}) {
  if (text.isEmpty) return text;
  return applyStudioRegexes(
        messages: [
          <String, dynamic>{'role': role, 'content': text},
        ],
        stages: {stage},
        entries: entries,
        macroContext: macroContext,
      ).single['content']
      as String;
}

String applyStudioOutputRegexesToText({
  required String text,
  required List<StudioRegex> entries,
  required MacroContext macroContext,
}) {
  if (text.isEmpty) return text;
  final scripts = entries
      .where((entry) => entry.stages.contains('output'))
      .map((entry) => entry.script)
      .toList();
  if (scripts.isEmpty) return text;

  return applyRegexes(
    text,
    2,
    1,
    scripts,
    RegexApplyContext(
      sessionVars: macroContext.sessionVars,
      globalVars: macroContext.globalVars,
      macroContext: macroContext,
    ),
  );
}
