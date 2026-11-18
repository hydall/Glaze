import '../../models/agent_definition.dart';
import '../default_aux_prompt_blocks.dart';

/// Stable ids of the built-in agents.
abstract final class BuiltinAgentIds {
  static const postClean = 'builtin_post_clean';
  static const tracker = 'builtin_tracker';
  static const cardRewriter = 'builtin_card_rewriter';
}

/// The built-in agents as first seeded: off everywhere until the user turns
/// them on. Seeding never overwrites a stored copy, so edits survive updates.
List<AgentDefinition> builtinAgentSeeds() => [
  AgentDefinition(
    id: BuiltinAgentIds.postClean,
    name: 'Post Clean',
    description:
        'Rewrites the reply after it arrives: removes repetition and clichés '
        'into a blue sub-swipe, keeping the original.',
    builtinKind: AgentBuiltin.postClean,
    phase: AgentPhase.postProcessing,
    resultType: AgentResultType.textRewrite,
    blocks: defaultCleanerBlocks(),
    order: 1000,
  ),
  AgentDefinition(
    id: BuiltinAgentIds.tracker,
    name: 'Tracker',
    description:
        'Keeps the scene state after every reply: time, place, who is present, '
        'relationships and what each character knows.',
    builtinKind: AgentBuiltin.tracker,
    phase: AgentPhase.postProcessing,
    resultType: AgentResultType.ledgerUpdate,
    blocks: defaultLedgerBlocks(),
    order: 1001,
  ),
  const AgentDefinition(
    id: BuiltinAgentIds.cardRewriter,
    name: 'Card Rewriter',
    description:
        'Proposes edits to the character card and lorebook as the story '
        'develops; every change waits for your review. Needs the Tracker.',
    builtinKind: AgentBuiltin.cardRewriter,
    phase: AgentPhase.postProcessing,
    resultType: AgentResultType.cardUpdateProposal,
    dependsOn: [BuiltinAgentIds.tracker],
    order: 1002,
  ),
];
