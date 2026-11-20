import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/agent_binding_repo.dart';
import 'package:glaze_flutter/core/db/repositories/agent_repo.dart';
import 'package:glaze_flutter/core/models/agent_binding.dart';
import 'package:glaze_flutter/core/models/agent_definition.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/features/cloud_sync/adapters/agent_sync_store.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_serialization.dart';

void main() {
  late AppDatabase source;
  late AppDatabase target;

  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() {
    source = AppDatabase.forTesting(NativeDatabase.memory());
    target = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() async {
    await source.close();
    await target.close();
  });

  AgentSyncStore storeOf(AppDatabase db) =>
      AgentSyncStore(AgentRepo(db), AgentBindingRepo(db));

  test('agents and bindings travel to another device', () async {
    await AgentRepo(source).put(
      const AgentDefinition(
        id: 'a',
        name: 'A',
        blocks: [PresetBlock(id: 'b', name: 'b', role: 'system', content: 'x')],
      ),
    );
    await AgentBindingRepo(source).set(
      agentId: 'a',
      scope: AgentBindingScope.chat,
      targetId: 's',
      enabled: true,
    );
    // The target has an agent the source deleted; the pull removes it.
    await AgentRepo(target).put(const AgentDefinition(id: 'gone', name: 'G'));

    final payload = await storeOf(source).read();
    await storeOf(target).apply(payload);

    final agents = await AgentRepo(target).getAll();
    expect(agents.map((a) => a.id), ['a']);
    expect(agents.single.blocks.single.content, 'x');
    final bindings = await AgentBindingRepo(target).getAll();
    expect(bindings.single.targetId, 's');
    expect(
      SyncSerialization.computeSyncHash(await storeOf(target).read()),
      SyncSerialization.computeSyncHash(payload),
    );
  });

  test('bindings of an agent missing from the payload are dropped', () async {
    await storeOf(target).apply({
      'agents': const <Map<String, dynamic>>[],
      'bindings': [
        {'agentId': 'x', 'scope': 'chat', 'targetId': 's', 'enabled': true},
      ],
    });
    expect(await AgentBindingRepo(target).getAll(), isEmpty);
  });
}
