import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_preset_codec.dart';
import 'package:glaze_flutter/core/models/studio_preset_validation.dart';

void main() {
  test('accepts a canonical typed preset', () {
    const preset = StudioPreset(
      id: 'valid',
      blocks: [
        StudioPresetBlock(id: 'rules', content: 'Write clearly.'),
        StudioPresetBlock(
          id: 'memory',
          type: StudioBlockType.context,
          contextSlot: StudioContextSlot.memory,
        ),
        StudioPresetBlock(id: 'history', type: StudioBlockType.history),
        StudioPresetBlock(
          id: 'briefs',
          type: StudioBlockType.priorBriefs,
          section: 'final',
        ),
      ],
    );

    expect(StudioPresetValidator.validate(preset), isEmpty);
  });

  test('rejects ambiguous source and target semantics', () {
    const preset = StudioPreset(
      id: 'invalid',
      blocks: [
        StudioPresetBlock(
          id: 'context',
          type: StudioBlockType.context,
          targetAgentId: 'continuity',
        ),
        StudioPresetBlock(
          id: 'instruction',
          content: 'Rules',
          contextSlot: StudioContextSlot.summary,
          targetAgentId: 'unknown',
        ),
      ],
    );

    final issues = StudioPresetValidator.validate(preset);

    expect(StudioPresetValidator.hasErrors(issues), isTrue);
    expect(
      issues.map((issue) => issue.message),
      containsAll([
        'Context source is required.',
        'Context blocks cannot target an agent.',
        'Instruction blocks cannot select context.',
        'Unknown target agent "unknown".',
      ]),
    );
  });

  test('an exported legacy preset decodes into an importable preset', () {
    // Shape of a Studio preset exported before blocks became typed: `kind`
    // instead of `type`/`contextSlot`, runtime-injected slots with no content,
    // a title-only separator, and the retired `writeloop` section. Import used
    // to bypass the codec and then fail validation on all four.
    final decoded = StudioPresetCodec.decodePreset({
      'id': 'legacy_export',
      'name': 'Legacy export',
      'agentEnabled': <String, dynamic>{},
      'blocks': [
        {
          'id': 'note',
          'kind': 'authors_note',
          'content': '',
          'section': 'final',
        },
        {
          'id': 'history',
          'kind': 'chat_history',
          'content': '',
          'section': 'final',
        },
        {
          'id': 'header',
          'kind': 'custom_text',
          'title': '━ Final Response',
          'content': '',
          'section': 'final',
        },
        {
          'id': 'writeloop_system',
          'kind': 'instruction',
          'content': 'Retired write-loop prompt',
          'section': 'writeloop',
        },
      ],
    });

    final blocks = decoded.preset.blocks;
    expect(blocks[0].type, StudioBlockType.context);
    expect(blocks[0].contextSlot, StudioContextSlot.authorsNote);
    expect(blocks[1].type, StudioBlockType.history);

    final issues = StudioPresetValidator.validate(decoded.preset);

    expect(StudioPresetValidator.hasErrors(issues), isFalse);
    expect(
      issues.map((issue) => issue.message),
      containsAll([
        'Instruction content must not be empty.',
        'Unsupported Studio section "writeloop".',
      ]),
    );
  });

  test('warns on an unsupported insertion mode string', () {
    const preset = StudioPreset(
      id: 'bad-insertion-mode',
      blocks: [
        StudioPresetBlock(
          id: 'weird',
          content: 'Rules',
          insertionMode: 'unsupported-mode',
        ),
      ],
    );

    final issues = StudioPresetValidator.validate(preset);

    expect(
      issues.map((issue) => issue.message),
      contains('Unsupported insertion mode.'),
    );
  });

  test('warns when insertionMode is depth but depth is null', () {
    const preset = StudioPreset(
      id: 'depth-missing',
      blocks: [
        StudioPresetBlock(
          id: 'depth-block',
          content: 'Rules',
          insertionMode: 'depth',
        ),
      ],
    );

    final issues = StudioPresetValidator.validate(preset);

    expect(
      issues.map((issue) => issue.message),
      contains('Depth insertion mode is set without a depth.'),
    );
  });

  test('warns when depth is set but insertionMode is not depth', () {
    const preset = StudioPreset(
      id: 'depth-without-mode',
      blocks: [
        StudioPresetBlock(id: 'depth-block', content: 'Rules', depth: 3),
      ],
    );

    final issues = StudioPresetValidator.validate(preset);

    expect(
      issues.map((issue) => issue.message),
      contains('Depth is set but insertion mode is not "depth".'),
    );
  });

  test(
    'warns when insertionMode is depth on a non-instruction block type',
    () {
      const preset = StudioPreset(
        id: 'depth-on-history',
        blocks: [
          StudioPresetBlock(
            id: 'history',
            type: StudioBlockType.history,
            insertionMode: 'depth',
            depth: 1,
          ),
        ],
      );

      final issues = StudioPresetValidator.validate(preset);

      expect(
        issues.map((issue) => issue.message),
        contains('Depth insertion only applies to instructions.'),
      );
    },
  );

  test(
    'a well-formed depth instruction block produces no depth-related warnings',
    () {
      const preset = StudioPreset(
        id: 'depth-ok',
        blocks: [
          StudioPresetBlock(
            id: 'depth-block',
            content: 'Rules',
            insertionMode: 'depth',
            depth: 5,
          ),
        ],
      );

      final issues = StudioPresetValidator.validate(preset);

      expect(
        issues.map((issue) => issue.message),
        isNot(
          anyElement(
            anyOf(
              contains('insertion mode'),
              contains('Depth insertion'),
              contains('Depth is set'),
            ),
          ),
        ),
      );
    },
  );

  test('reports duplicate ids and ignored source-block content', () {
    const preset = StudioPreset(
      id: 'warnings',
      blocks: [
        StudioPresetBlock(id: 'same', content: 'First'),
        StudioPresetBlock(
          id: 'same',
          type: StudioBlockType.history,
          content: 'Ignored',
        ),
      ],
    );

    final issues = StudioPresetValidator.validate(preset);

    expect(
      issues.where(
        (issue) => issue.severity == StudioPresetValidationSeverity.error,
      ),
      hasLength(1),
    );
    expect(
      issues.where(
        (issue) => issue.severity == StudioPresetValidationSeverity.warning,
      ),
      hasLength(1),
    );
  });
}
