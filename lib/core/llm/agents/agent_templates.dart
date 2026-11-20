import '../../models/agent_definition.dart';
import '../../models/preset.dart';
import '../default_aux_prompt_blocks.dart';

/// A ready-made agent to start from. Templates are not special in any way:
/// creating one writes an ordinary agent the user then owns and edits.
class AgentTemplate {
  final String id;

  /// Translation keys of the template's name and one-line pitch.
  final String nameKey;
  final String descriptionKey;
  final AgentDefinition Function() build;

  const AgentTemplate({
    required this.id,
    required this.nameKey,
    required this.descriptionKey,
    required this.build,
  });
}

/// The template gallery, in display order.
final List<AgentTemplate> agentTemplates = [
  AgentTemplate(
    id: 'post_clean',
    nameKey: 'agents_template_post_clean',
    descriptionKey: 'agents_template_post_clean_desc',
    build: () => AgentDefinition(
      id: '',
      phase: AgentPhase.postProcessing,
      resultType: AgentResultType.textRewrite,
      blocks: defaultCleanerBlocks(),
    ),
  ),
  AgentTemplate(
    id: 'tracker',
    nameKey: 'agents_template_tracker',
    descriptionKey: 'agents_template_tracker_desc',
    build: () => AgentDefinition(
      id: '',
      phase: AgentPhase.postProcessing,
      resultType: AgentResultType.ledgerUpdate,
      blocks: defaultLedgerBlocks(),
    ),
  ),
  AgentTemplate(
    id: 'card_rewriter',
    nameKey: 'agents_template_card_rewriter',
    descriptionKey: 'agents_template_card_rewriter_desc',
    build: () => const AgentDefinition(
      id: '',
      phase: AgentPhase.postProcessing,
      resultType: AgentResultType.cardUpdateProposal,
    ),
  ),
  AgentTemplate(
    id: 'continuity',
    nameKey: 'agents_template_continuity',
    descriptionKey: 'agents_template_continuity_desc',
    build: () => const AgentDefinition(
      id: '',
      phase: AgentPhase.preGeneration,
      resultType: AgentResultType.contextInjection,
      contextSize: 12,
      blocks: [
        PresetBlock(
          id: 'continuity_task',
          name: 'Task',
          role: 'system',
          content:
              'You keep a roleplay between {{user}} and {{char}} consistent. '
              'Read the recent chat and list, as 3-6 short bullet points, the '
              'facts the next reply must not contradict: where everyone is, '
              'what they hold or wear, injuries, promises, open questions, the '
              'time of day. Facts only — no advice, no prose, no story ideas.',
        ),
      ],
      injection: AgentInjection(depth: 1),
    ),
  ),
  AgentTemplate(
    id: 'director',
    nameKey: 'agents_template_director',
    descriptionKey: 'agents_template_director_desc',
    build: () => const AgentDefinition(
      id: '',
      phase: AgentPhase.parallel,
      resultType: AgentResultType.contextInjection,
      contextSize: 8,
      blocks: [
        PresetBlock(
          id: 'director_task',
          name: 'Task',
          role: 'system',
          content:
              'You are the quiet director of a roleplay with {{char}}. Read '
              'the recent chat and suggest, in two or three sentences, where '
              'the scene could go next: a complication, a detail to bring '
              'back, a side character to involve. Never write {{user}}\'s '
              'actions. Suggestions only — the writer may ignore them.',
        ),
      ],
      injection: AgentInjection(placement: AgentPlacement.afterMain),
    ),
  ),
];
