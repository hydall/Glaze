import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/agents/agent_batch.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/models/agent_definition.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/preset.dart';

AgentDefinition _agent(
  String id, {
  String phase = AgentPhase.preGeneration,
  bool alone = false,
  String text = 'do it',
}) => AgentDefinition(
  id: id,
  name: id,
  phase: phase,
  runAlone: alone,
  blocks: [PresetBlock(id: 'b', name: 'b', role: 'system', content: text)],
);

void main() {
  test('groups by phase and connection; lone and run-alone stay single', () {
    final groups = groupForBatching([
      _agent('a'),
      _agent('b'),
      _agent('c', phase: AgentPhase.parallel),
      _agent('d', alone: true),
      _agent('e'),
    ], (agent) => agent.id == 'e' ? 'other-model' : 'same');
    final ids = {for (final g in groups) g.map((a) => a.id).join(',')};
    expect(ids, {'a,b', 'c', 'd', 'e'});
  });

  test('the batch request carries the chat once and every task', () {
    final messages = buildBatchMessages(
      agents: [
        _agent('mood', text: 'Track {{char}} mood'),
        _agent('plot', text: 'Watch the plot. {{history}}'),
      ],
      macroContext: const MacroContext(
        charName: 'Alice',
        userName: 'Bob',
        charId: 'c',
        sessionId: 's',
      ),
      history: const [
        ChatMessage(id: 'u', role: 'user', content: 'hello there'),
      ],
    );
    final system = messages.first['content']!;
    expect(RegExp('hello there').allMatches(system), hasLength(1));
    expect(system, contains('<agent_task agent="mood"'));
    expect(system, contains('Track Alice mood'));
    expect(system, contains('<agent_task agent="plot"'));
    expect(system, isNot(contains('{{history}}')));
    expect(messages.last['role'], 'user');
  });

  test('parses answers, tolerating a missing closing tag', () {
    const text =
        'noise <result agent="mood">calm</result>\n'
        '<result agent="ghost">ignored</result>\n'
        '<result agent=\'plot\'>a twist is near';
    expect(parseBatchAnswer(text, ['mood', 'plot', 'missing']), {
      'mood': 'calm',
      'plot': 'a twist is near',
    });
  });

  test('an empty answer counts as missing', () {
    expect(parseBatchAnswer('<result agent="a">  </result>', ['a']), isEmpty);
  });
}
