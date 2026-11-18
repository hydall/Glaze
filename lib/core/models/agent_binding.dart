import 'agent_definition.dart';

/// The two levels below the global flag an agent can be switched at.
abstract final class AgentBindingScope {
  static const character = 'character';
  static const chat = 'chat';
}

/// Whether one agent runs for one character or one chat.
class AgentBinding {
  final String agentId;
  final String scope;
  final String targetId;
  final bool enabled;

  const AgentBinding({
    required this.agentId,
    required this.scope,
    required this.targetId,
    required this.enabled,
  });
}

/// Where an agent's current on/off state in a chat comes from.
enum AgentStateSource { global, character, chat }

/// An agent's effective state in a chat and the level that decided it.
class AgentChatState {
  final bool enabled;
  final AgentStateSource source;

  const AgentChatState(this.enabled, this.source);
}

/// Resolves whether [agent] runs in the chat [sessionId] of character
/// [charId]: the chat binding wins, then the character binding, then the
/// agent's global flag — the same priority as preset bindings.
AgentChatState resolveAgentState(
  AgentDefinition agent,
  Iterable<AgentBinding> bindings, {
  required String? charId,
  required String? sessionId,
}) {
  bool? chat;
  bool? character;
  for (final binding in bindings) {
    if (binding.agentId != agent.id) continue;
    if (binding.scope == AgentBindingScope.chat &&
        sessionId != null &&
        binding.targetId == sessionId) {
      chat = binding.enabled;
    } else if (binding.scope == AgentBindingScope.character &&
        charId != null &&
        binding.targetId == charId) {
      character = binding.enabled;
    }
  }
  if (chat != null) return AgentChatState(chat, AgentStateSource.chat);
  if (character != null) {
    return AgentChatState(character, AgentStateSource.character);
  }
  return AgentChatState(agent.enabledGlobally, AgentStateSource.global);
}

/// The agents of [library] that run in a chat, in library order.
List<AgentDefinition> agentsEnabledFor(
  List<AgentDefinition> library,
  Iterable<AgentBinding> bindings, {
  required String? charId,
  required String? sessionId,
}) => [
  for (final agent in library)
    if (resolveAgentState(
      agent,
      bindings,
      charId: charId,
      sessionId: sessionId,
    ).enabled)
      agent,
];
