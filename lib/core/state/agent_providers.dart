import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/repositories/agent_binding_repo.dart';
import '../db/repositories/agent_repo.dart';
import '../db/repositories/agent_run_repo.dart';
import '../llm/agents/builtin_agents.dart';
import '../models/agent_binding.dart';
import '../models/agent_definition.dart';
import '../models/agent_run.dart';
import 'db_provider.dart';

final agentRepoProvider = Provider<AgentRepo>(
  (ref) => AgentRepo(ref.watch(appDbProvider)),
);

final agentBindingRepoProvider = Provider<AgentBindingRepo>(
  (ref) => AgentBindingRepo(ref.watch(appDbProvider)),
);

final agentRunRepoProvider = Provider<AgentRunRepo>(
  (ref) => AgentRunRepo(ref.watch(appDbProvider)),
);

/// The agent library, built-in agents seeded on first read.
final agentLibraryProvider =
    AsyncNotifierProvider<AgentLibraryNotifier, List<AgentDefinition>>(
      AgentLibraryNotifier.new,
    );

class AgentLibraryNotifier extends AsyncNotifier<List<AgentDefinition>> {
  AgentRepo get _repo => ref.read(agentRepoProvider);

  @override
  Future<List<AgentDefinition>> build() async {
    final repo = ref.watch(agentRepoProvider);
    await repo.ensureSeeded(builtinAgentSeeds());
    return repo.getAll();
  }

  Future<void> save(AgentDefinition agent) async {
    await _repo.put(
      agent.copyWith(updatedAt: DateTime.now().millisecondsSinceEpoch),
    );
    ref.invalidateSelf();
    await future;
  }

  /// A new user agent, placed after every existing one.
  Future<AgentDefinition> create({String name = 'New agent'}) async {
    final current = state.value ?? await future;
    final now = DateTime.now().millisecondsSinceEpoch;
    final agent = AgentDefinition(
      id: 'agent_$now',
      name: name,
      order: _nextOrder(current),
      updatedAt: now,
    );
    await save(agent);
    return agent;
  }

  /// A copy of [source] as a user agent (a copied built-in keeps its engine).
  Future<AgentDefinition> duplicate(AgentDefinition source) async {
    final current = state.value ?? await future;
    final now = DateTime.now().millisecondsSinceEpoch;
    final copy = source.copyWith(
      id: 'agent_$now',
      name: '${source.displayName} (copy)',
      enabledGlobally: false,
      order: _nextOrder(current),
    );
    await save(copy);
    return copy;
  }

  /// Built-in agents can be edited but not deleted.
  Future<void> delete(String id) async {
    final agent = (state.value ?? const [])
        .where((a) => a.id == id)
        .firstOrNull;
    if (agent == null || agent.id.startsWith('builtin_')) return;
    await _repo.delete(id);
    ref.invalidateSelf();
    await future;
  }

  /// Persists [ordered] as the new library order.
  Future<void> reorder(List<AgentDefinition> ordered) async {
    for (var i = 0; i < ordered.length; i++) {
      if (ordered[i].order != i) await _repo.put(ordered[i].copyWith(order: i));
    }
    ref.invalidateSelf();
    await future;
  }

  /// Imports an exported agent. Always a new user agent; the stored id and
  /// built-in kind of the file are not trusted.
  Future<AgentDefinition> importJson(String raw) async {
    final decoded = jsonDecode(raw);
    final map = decoded is Map && decoded['agent'] is Map
        ? decoded['agent'] as Map
        : decoded as Map;
    final parsed = AgentDefinition.fromJson(Map<String, dynamic>.from(map));
    final current = state.value ?? await future;
    final now = DateTime.now().millisecondsSinceEpoch;
    final builtin = parsed.builtinKind;
    final agent = parsed.copyWith(
      id: 'agent_$now',
      // A copied built-in keeps its engine only if that engine exists.
      builtinKind: AgentBuiltin.all.contains(builtin) ? builtin : null,
      enabledGlobally: false,
      dependsOn: const [],
      seesOutputsOf: const [],
      order: _nextOrder(current),
    );
    await save(agent);
    return agent;
  }

  static String exportJson(AgentDefinition agent) =>
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'glazeAgent': 1, 'agent': agent.toJson()});

  static int _nextOrder(List<AgentDefinition> agents) => agents.isEmpty
      ? 0
      : agents.map((a) => a.order).reduce((a, b) => a > b ? a : b) + 1;
}

/// Every binding, live.
final agentBindingsProvider = StreamProvider<List<AgentBinding>>(
  (ref) => ref.watch(agentBindingRepoProvider).watchAll(),
);

/// The run log of one chat, newest first.
final agentRunsProvider = StreamProvider.family<List<AgentRun>, String>(
  (ref, sessionId) =>
      ref.watch(agentRunRepoProvider).watchForSession(sessionId),
);

/// Session variable that switches every agent off in one chat without
/// touching the bindings.
const agentsOffSessionVar = 'glaze_agents_off';

bool agentsOffInSession(Map<String, String> sessionVars) =>
    sessionVars[agentsOffSessionVar] == '1';

typedef ChatAgentsKey = ({String charId, String sessionId});

/// One agent as a chat sees it: the agent and its effective state there.
typedef ChatAgentEntry = ({AgentDefinition agent, AgentChatState state});

/// Every agent of the library with its state in one chat, live.
final chatAgentsProvider =
    Provider.family<AsyncValue<List<ChatAgentEntry>>, ChatAgentsKey>((
      ref,
      key,
    ) {
      final library = ref.watch(agentLibraryProvider);
      final bindings = ref.watch(agentBindingsProvider);
      if (library.hasError) return AsyncError(library.error!, StackTrace.empty);
      if (!library.hasValue || !bindings.hasValue) return const AsyncLoading();
      return AsyncData([
        for (final agent in library.requireValue)
          (
            agent: agent,
            state: resolveAgentState(
              agent,
              bindings.requireValue,
              charId: key.charId,
              sessionId: key.sessionId,
            ),
          ),
      ]);
    });

/// Whether the agent of [builtinKind] is switched on in a chat (ignoring the
/// chat's own off switch, which the caller checks against the session).
final chatBuiltinAgentOnProvider =
    Provider.family<bool, ({String charId, String sessionId, String kind})>((
      ref,
      key,
    ) {
      final entries =
          ref
              .watch(
                chatAgentsProvider((
                  charId: key.charId,
                  sessionId: key.sessionId,
                )),
              )
              .value ??
          const <ChatAgentEntry>[];
      return entries.any(
        (entry) => entry.agent.builtinKind == key.kind && entry.state.enabled,
      );
    });
