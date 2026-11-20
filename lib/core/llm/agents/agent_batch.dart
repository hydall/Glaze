import '../../models/agent_definition.dart';
import '../../models/chat_message.dart';
import '../macro_engine.dart';
import 'agent_prompt_builder.dart';

/// Agents that may share one request: same phase, same resolved connection
/// and model, none asking to run alone. One agent alone is not a batch.
List<List<AgentDefinition>> groupForBatching(
  List<AgentDefinition> agents,
  String Function(AgentDefinition agent) connectionKey,
) {
  final groups = <String, List<AgentDefinition>>{};
  final singles = <List<AgentDefinition>>[];
  for (final agent in agents) {
    if (agent.runAlone) {
      singles.add([agent]);
      continue;
    }
    groups
        .putIfAbsent('${agent.phase}|${connectionKey(agent)}', () => [])
        .add(agent);
  }
  return [...groups.values, ...singles];
}

/// The one request of a batch: a shared instruction and the chat transcript
/// once, then every agent's own task, and the answer format that keeps the
/// answers apart (`<result agent="id">…</result>`). Shared, stable text comes
/// first so a provider prompt cache can reuse it across turns.
List<Map<String, String>> buildBatchMessages({
  required List<AgentDefinition> agents,
  required MacroContext macroContext,
  required List<ChatMessage> history,
}) {
  final contextSize = agents
      .map((agent) => agent.contextSize)
      .fold<int>(1, (a, b) => a > b ? a : b);
  final transcript = AgentPromptBuilder.transcriptOf(
    history,
    limit: contextSize,
    userName: macroContext.userName,
    charName: macroContext.macroName ?? macroContext.charName,
  );
  final tasks = StringBuffer();
  for (final agent in agents) {
    final parts = <String>[];
    for (final block in agent.activeBlocks) {
      if (!block.enabled) continue;
      final content = replaceMacros(
        block.content.replaceAll(
          AgentPromptBuilder.historyMacro,
          '(the chat is in <chat_history> above)',
        ),
        macroContext,
      ).text.trim();
      if (content.isNotEmpty) parts.add(content);
    }
    tasks
      ..writeln('<agent_task agent="${agent.id}" name="${agent.displayName}">')
      ..writeln(parts.join('\n\n'))
      ..writeln('</agent_task>');
  }
  final ids = agents.map((agent) => agent.id).join(', ');
  final system = StringBuffer()
    ..writeln(
      'You are several independent helper agents working on one roleplay '
      'chat. Each <agent_task> is a separate agent with its own instructions. '
      'Do every task on its own; do not mix their answers.',
    )
    ..writeln()
    ..writeln('<chat_history>')
    ..writeln(transcript.isEmpty ? '(no messages yet)' : transcript)
    ..writeln('</chat_history>')
    ..writeln()
    ..writeln('<agents>')
    ..write(tasks)
    ..writeln('</agents>')
    ..writeln()
    ..writeln(
      'Answer with exactly one block per agent, in this form and nothing '
      'else:\n<result agent="AGENT_ID">the agent\'s answer</result>\n'
      'Agents: $ids',
    );
  return [
    {'role': 'system', 'content': system.toString().trim()},
    {'role': 'user', 'content': 'Complete every agent task now.'},
  ];
}

/// Splits a batch answer into each agent's text. Tolerates a missing closing
/// tag (the block then runs to the next `<result` or the end); agents with no
/// block or an empty one are absent from the map.
Map<String, String> parseBatchAnswer(String text, Iterable<String> agentIds) {
  final ids = agentIds.toSet();
  final result = <String, String>{};
  final open = RegExp(r'''<result\s+agent\s*=\s*["']([^"']+)["']\s*>''');
  final matches = open.allMatches(text).toList();
  for (var i = 0; i < matches.length; i++) {
    final id = matches[i].group(1)!.trim();
    if (!ids.contains(id) || result.containsKey(id)) continue;
    final start = matches[i].end;
    final next = i + 1 < matches.length ? matches[i + 1].start : text.length;
    var body = text.substring(start, next);
    final close = body.indexOf('</result>');
    if (close >= 0) body = body.substring(0, close);
    body = body.trim();
    if (body.isNotEmpty) result[id] = body;
  }
  return result;
}
