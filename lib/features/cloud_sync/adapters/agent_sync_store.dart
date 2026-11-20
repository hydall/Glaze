import '../../../core/db/repositories/agent_binding_repo.dart';
import '../../../core/db/repositories/agent_repo.dart';
import '../../../core/models/agent_binding.dart';
import '../../../core/models/agent_definition.dart';
import '../sync_repo_interfaces.dart';

/// Agents and their bindings, read and written as the `agents` singleton.
class AgentSyncStore implements SyncAgentStore {
  final AgentRepo _agents;
  final AgentBindingRepo _bindings;

  AgentSyncStore(this._agents, this._bindings);

  @override
  Future<Map<String, dynamic>> read() async {
    final agents = await _agents.getAll();
    final bindings = await _bindings.getAll()
      ..sort(
        (a, b) => '${a.agentId}|${a.scope}|${a.targetId}'.compareTo(
          '${b.agentId}|${b.scope}|${b.targetId}',
        ),
      );
    return {
      'agents': [for (final agent in agents) agent.toJson()],
      'bindings': [for (final binding in bindings) bindingToJson(binding)],
    };
  }

  @override
  Future<void> apply(Map<String, dynamic> data) async {
    final agents = <AgentDefinition>[];
    for (final raw in data['agents'] as List? ?? const []) {
      if (raw is! Map) continue;
      try {
        agents.add(AgentDefinition.fromJson(Map<String, dynamic>.from(raw)));
      } catch (_) {
        // An agent this version cannot read is left out, not the whole set.
      }
    }
    final bindings = <AgentBinding>[
      for (final raw in data['bindings'] as List? ?? const [])
        if (raw is Map) ?bindingFromJson(Map<String, dynamic>.from(raw)),
    ];
    await _agents.replaceAll(agents, bindings);
  }

  static Map<String, dynamic> bindingToJson(AgentBinding binding) => {
    'agentId': binding.agentId,
    'scope': binding.scope,
    'targetId': binding.targetId,
    'enabled': binding.enabled,
  };

  static AgentBinding? bindingFromJson(Map<String, dynamic> json) {
    final agentId = json['agentId'];
    final scope = json['scope'];
    final targetId = json['targetId'];
    final enabled = json['enabled'];
    if (agentId is! String || scope is! String || targetId is! String) {
      return null;
    }
    return AgentBinding(
      agentId: agentId,
      scope: scope,
      targetId: targetId,
      enabled: enabled == true,
    );
  }
}
