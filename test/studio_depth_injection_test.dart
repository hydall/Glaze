import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context.dart';
import 'package:glaze_flutter/core/llm/studio_brief_deduper.dart';
import 'package:glaze_flutter/core/llm/studio_brief_parser.dart';
import 'package:glaze_flutter/core/llm/studio_message_builder.dart';
import 'package:glaze_flutter/core/llm/studio_prompt_text.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

/// Depth-anchored instruction blocks (`insertionMode: 'depth'`) mirror the
/// classic (non-Studio) preset pipeline's Author's Note depth field: they are
/// interleaved INSIDE the chat-history array instead of being concatenated
/// via ordinary `order` sequencing. See `StudioMessageBuilder.buildAgentMessages`
/// and `interleaveDepthWithHistory` in `history_assembler.dart`.
StudioContext _context(List<PromptMessage> history) => StudioContext(
  slots: const {},
  history: history,
  sessionVars: const {},
  globalVars: const {},
  macroContext: const MacroContext(
    charName: 'Lucy',
    charId: 'char',
    sessionId: 'session',
  ),
  diagnostics: const StudioContextDiagnostics(),
);

void main() {
  final builder = StudioMessageBuilder(
    const StudioPromptText(),
    StudioBriefDeduper(StudioBriefParser((_) {})),
  );
  const config = StudioConfig(sessionId: 'session');

  group('Studio depth-anchored instruction placement', () {
    test('depth 0 lands right before generation (after all history)', () {
      final context = _context(const [
        PromptMessage(role: 'user', content: 'First', isHistory: true),
        PromptMessage(role: 'assistant', content: 'Second', isHistory: true),
      ]);

      final messages = builder.buildAgentMessages(
        agent: const StudioAgent(id: 'final'),
        context: context,
        config: config,
        studioPreset: const StudioPreset(
          id: 'depth0',
          blocks: [
            StudioPresetBlock(
              id: 'chat_history',
              type: StudioBlockType.history,
              injectionPoint: 'final',
              order: 0,
            ),
            StudioPresetBlock(
              id: 'depth_instr',
              content: 'DEPTH0',
              insertionMode: 'depth',
              depth: 0,
              injectionPoint: 'final',
              order: 1,
            ),
          ],
        ),
        priorBriefs: const [],
        isFinalResponse: true,
      );

      expect(messages.map((m) => m['content']), [
        'First',
        'Second',
        'DEPTH0',
      ]);
    });

    test('depth partway through history interleaves at the right spot', () {
      final context = _context(const [
        PromptMessage(role: 'user', content: 'First', isHistory: true),
        PromptMessage(role: 'assistant', content: 'Second', isHistory: true),
        PromptMessage(role: 'user', content: 'Third', isHistory: true),
        PromptMessage(role: 'assistant', content: 'Fourth', isHistory: true),
      ]);

      final messages = builder.buildAgentMessages(
        agent: const StudioAgent(id: 'final'),
        context: context,
        config: config,
        studioPreset: const StudioPreset(
          id: 'depth-mid',
          blocks: [
            StudioPresetBlock(
              id: 'chat_history',
              type: StudioBlockType.history,
              injectionPoint: 'final',
              order: 0,
            ),
            StudioPresetBlock(
              id: 'depth_instr',
              content: 'DEPTH2',
              insertionMode: 'depth',
              depth: 2,
              injectionPoint: 'final',
              order: 1,
            ),
          ],
        ),
        priorBriefs: const [],
        isFinalResponse: true,
      );

      expect(messages.map((m) => m['content']), [
        'First',
        'Second',
        'DEPTH2',
        'Third',
        'Fourth',
      ]);
    });

    test(
      'depth >= history length is prepended before all history messages',
      () {
        final context = _context(const [
          PromptMessage(role: 'user', content: 'First', isHistory: true),
          PromptMessage(
            role: 'assistant',
            content: 'Second',
            isHistory: true,
          ),
          PromptMessage(role: 'user', content: 'Third', isHistory: true),
          PromptMessage(
            role: 'assistant',
            content: 'Fourth',
            isHistory: true,
          ),
        ]);

        final messages = builder.buildAgentMessages(
          agent: const StudioAgent(id: 'final'),
          context: context,
          config: config,
          studioPreset: const StudioPreset(
            id: 'depth-front',
            blocks: [
              StudioPresetBlock(
                id: 'chat_history',
                type: StudioBlockType.history,
                injectionPoint: 'final',
                order: 0,
              ),
              StudioPresetBlock(
                id: 'depth_instr',
                content: 'DEPTH_FAR',
                insertionMode: 'depth',
                depth: 10,
                injectionPoint: 'final',
                order: 1,
              ),
            ],
          ),
          priorBriefs: const [],
          isFinalResponse: true,
        );

        expect(messages.map((m) => m['content']), [
          'DEPTH_FAR',
          'First',
          'Second',
          'Third',
          'Fourth',
        ]);
      },
    );

    test('depth exactly equal to history length also lands at the front', () {
      final context = _context(const [
        PromptMessage(role: 'user', content: 'First', isHistory: true),
        PromptMessage(role: 'assistant', content: 'Second', isHistory: true),
      ]);

      final messages = builder.buildAgentMessages(
        agent: const StudioAgent(id: 'final'),
        context: context,
        config: config,
        studioPreset: const StudioPreset(
          id: 'depth-eq-length',
          blocks: [
            StudioPresetBlock(
              id: 'chat_history',
              type: StudioBlockType.history,
              injectionPoint: 'final',
              order: 0,
            ),
            StudioPresetBlock(
              id: 'depth_instr',
              content: 'DEPTH_EQ',
              insertionMode: 'depth',
              depth: 2,
              injectionPoint: 'final',
              order: 1,
            ),
          ],
        ),
        priorBriefs: const [],
        isFinalResponse: true,
      );

      expect(messages.map((m) => m['content']), [
        'DEPTH_EQ',
        'First',
        'Second',
      ]);
    });

    test('multiple depth blocks at different depths all interleave', () {
      final context = _context(const [
        PromptMessage(role: 'user', content: 'First', isHistory: true),
        PromptMessage(role: 'assistant', content: 'Second', isHistory: true),
        PromptMessage(role: 'user', content: 'Third', isHistory: true),
        PromptMessage(role: 'assistant', content: 'Fourth', isHistory: true),
      ]);

      final messages = builder.buildAgentMessages(
        agent: const StudioAgent(id: 'final'),
        context: context,
        config: config,
        studioPreset: const StudioPreset(
          id: 'depth-multi',
          blocks: [
            StudioPresetBlock(
              id: 'chat_history',
              type: StudioBlockType.history,
              injectionPoint: 'final',
              order: 0,
            ),
            StudioPresetBlock(
              id: 'depth0',
              content: 'DEPTH0',
              insertionMode: 'depth',
              depth: 0,
              injectionPoint: 'final',
              order: 1,
            ),
            StudioPresetBlock(
              id: 'depth2',
              content: 'DEPTH2',
              insertionMode: 'depth',
              depth: 2,
              injectionPoint: 'final',
              order: 2,
            ),
          ],
        ),
        priorBriefs: const [],
        isFinalResponse: true,
      );

      expect(messages.map((m) => m['content']), [
        'First',
        'Second',
        'DEPTH2',
        'Third',
        'Fourth',
        'DEPTH0',
      ]);
    });

    test(
      'depth interleaving keeps reasoning_content on the correct original '
      'history message after indices shift',
      () {
        final context = _context(const [
          PromptMessage(
            role: 'assistant',
            content: 'A1',
            reasoningContent: 'R1',
            isHistory: true,
          ),
          PromptMessage(role: 'user', content: 'U1', isHistory: true),
          PromptMessage(
            role: 'assistant',
            content: 'A2',
            reasoningContent: 'R2',
            isHistory: true,
          ),
          PromptMessage(role: 'user', content: 'U2', isHistory: true),
        ]);

        final messages = builder.buildAgentMessages(
          agent: const StudioAgent(id: 'final'),
          context: context,
          config: config,
          studioPreset: const StudioPreset(
            id: 'depth-reasoning',
            blocks: [
              StudioPresetBlock(
                id: 'chat_history',
                type: StudioBlockType.history,
                injectionPoint: 'final',
                order: 0,
              ),
              StudioPresetBlock(
                id: 'depth1',
                content: 'DEPTH1',
                insertionMode: 'depth',
                depth: 1,
                injectionPoint: 'final',
                order: 1,
              ),
            ],
          ),
          priorBriefs: const [],
          isFinalResponse: true,
          reasoningHistoryCount: 1,
        );

        // reasoningHistoryCount: 1 selects only the nearest assistant turn
        // with non-empty reasoning (A2), scanned against the RAW pre-interleave
        // history — so it must still be A2 that carries reasoning_content
        // after DEPTH1 shifts every later index by one.
        expect(messages.map((m) => m['content']), [
          'A1',
          'U1',
          'A2',
          'DEPTH1',
          'U2',
        ]);
        final a1 = messages.firstWhere((m) => m['content'] == 'A1');
        final a2 = messages.firstWhere((m) => m['content'] == 'A2');
        final depthMsg = messages.firstWhere(
          (m) => m['content'] == 'DEPTH1',
        );
        expect(a1, isNot(contains('reasoning_content')));
        expect(a2['reasoning_content'], 'R2');
        expect(depthMsg, isNot(contains('reasoning_content')));
        expect(
          messages.where((m) => m.containsKey('reasoning_content')),
          hasLength(1),
        );
      },
    );

    test(
      'a depth insertionMode on the history-type block itself is ignored',
      () {
        final context = _context(const [
          PromptMessage(role: 'user', content: 'First', isHistory: true),
          PromptMessage(
            role: 'assistant',
            content: 'Second',
            isHistory: true,
          ),
        ]);

        final messages = builder.buildAgentMessages(
          agent: const StudioAgent(id: 'final'),
          context: context,
          config: config,
          studioPreset: const StudioPreset(
            id: 'depth-on-history-block',
            blocks: [
              StudioPresetBlock(
                id: 'chat_history',
                type: StudioBlockType.history,
                insertionMode: 'depth',
                depth: 1,
                injectionPoint: 'final',
                order: 0,
              ),
            ],
          ),
          priorBriefs: const [],
          isFinalResponse: true,
        );

        // Only instruction-type blocks are eligible for depth extraction, so
        // a history block carrying insertionMode/depth is a no-op: it is
        // resolved as an ordinary chat-history splice, unaffected.
        expect(messages.map((m) => m['content']), ['First', 'Second']);
      },
    );

    test(
      'a depth block whose expanded content is empty is skipped entirely',
      () {
        final context = _context(const [
          PromptMessage(role: 'user', content: 'First', isHistory: true),
          PromptMessage(
            role: 'assistant',
            content: 'Second',
            isHistory: true,
          ),
        ]);

        final messages = builder.buildAgentMessages(
          agent: const StudioAgent(id: 'final'),
          context: context,
          config: config,
          studioPreset: const StudioPreset(
            id: 'depth-empty-content',
            blocks: [
              StudioPresetBlock(
                id: 'chat_history',
                type: StudioBlockType.history,
                injectionPoint: 'final',
                order: 0,
              ),
              StudioPresetBlock(
                id: 'depth_empty',
                // {{arc}} expands to an empty string with no arc context var
                // seeded — matches the empty-macro pattern already exercised
                // by the group-boundary tests in studio_typed_message_builder_test.dart.
                content: '{{arc}}',
                insertionMode: 'depth',
                depth: 0,
                injectionPoint: 'final',
                order: 1,
              ),
            ],
          ),
          priorBriefs: const [],
          isFinalResponse: true,
        );

        expect(messages.map((m) => m['content']), ['First', 'Second']);
      },
    );
  });
}
