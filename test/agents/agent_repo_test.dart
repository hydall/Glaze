import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/agent_binding_repo.dart';
import 'package:glaze_flutter/core/db/repositories/agent_repo.dart';
import 'package:glaze_flutter/core/db/repositories/agent_run_repo.dart';
import 'package:glaze_flutter/core/llm/agents/builtin_agents.dart';
import 'package:glaze_flutter/core/models/agent_binding.dart';
import 'package:glaze_flutter/core/models/agent_definition.dart';
import 'package:glaze_flutter/core/models/agent_run.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('seeding adds built-ins once and never overwrites an edit', () async {
    final repo = AgentRepo(db);
    await repo.ensureSeeded(builtinAgentSeeds());
    final tracker = await repo.getById(BuiltinAgentIds.tracker);
    expect(tracker?.builtinKind, AgentBuiltin.tracker);

    await repo.put(tracker!.copyWith(name: 'Mine', enabledGlobally: true));
    await repo.ensureSeeded(builtinAgentSeeds());

    final again = await repo.getById(BuiltinAgentIds.tracker);
    expect(again?.name, 'Mine');
    expect(again?.enabledGlobally, isTrue);
    expect(await repo.getAll(), hasLength(builtinAgentSeeds().length));
  });

  test('deleting an agent drops its bindings', () async {
    final repo = AgentRepo(db);
    final bindings = AgentBindingRepo(db);
    await repo.put(const AgentDefinition(id: 'a', name: 'A'));
    await bindings.set(
      agentId: 'a',
      scope: AgentBindingScope.chat,
      targetId: 's',
      enabled: true,
    );
    await repo.delete('a');
    expect(await repo.getAll(), isEmpty);
    expect(await bindings.getAll(), isEmpty);
  });

  test('a null switch removes the binding', () async {
    final bindings = AgentBindingRepo(db);
    await bindings.set(
      agentId: 'a',
      scope: AgentBindingScope.character,
      targetId: 'c',
      enabled: false,
    );
    expect((await bindings.getAll()).single.enabled, isFalse);
    await bindings.set(
      agentId: 'a',
      scope: AgentBindingScope.character,
      targetId: 'c',
      enabled: null,
    );
    expect(await bindings.getAll(), isEmpty);
  });

  test('latest outputs skip failed runs and the excluded message', () async {
    final runs = AgentRunRepo(db);
    AgentRun run(String message, String output, int at, {bool ok = true}) =>
        AgentRun(
          sessionId: 's',
          messageId: message,
          agentId: 'p',
          phase: AgentPhase.parallel,
          resultType: AgentResultType.contextInjection,
          ok: ok,
          output: output,
          createdAt: at,
        );
    await runs.insert(run('m1', 'old', 1));
    await runs.insert(run('m2', 'newer', 2));
    await runs.insert(run('m3', 'failed', 3, ok: false));
    await runs.insert(run('m4', 'regen target', 4));

    expect(await runs.latestOutputs('s', ['p'], excludingMessageId: 'm4'), {
      'p': 'newer',
    });
    expect(await runs.latestOutputs('s', ['p']), {'p': 'regen target'});
    expect(await runs.latestOutputs('s', ['other']), isEmpty);
  });

  test('the run log keeps a bounded number of rows per chat', () async {
    final runs = AgentRunRepo(db);
    for (var i = 0; i < AgentRunRepo.keepPerSession + 5; i++) {
      await runs.insert(
        AgentRun(
          sessionId: 's',
          agentId: 'a',
          phase: AgentPhase.preGeneration,
          resultType: AgentResultType.contextInjection,
          createdAt: i,
        ),
      );
    }
    final kept = await runs.forSession('s', limit: 1000);
    expect(kept, hasLength(AgentRunRepo.keepPerSession));
    expect(kept.first.createdAt, AgentRunRepo.keepPerSession + 4);
  });
}
