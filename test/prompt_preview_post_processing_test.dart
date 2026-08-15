import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/converters/prompt_post_processing.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/features/chat/services/prompt_preview_post_processor.dart';

void main() {
  const built = [
    PromptMessage(
      role: 'system',
      content: 'main prompt',
      blockName: 'Main Prompt',
    ),
    PromptMessage(
      role: 'system',
      content: 'lore entry',
      blockName: 'Lorebook',
      isLorebook: true,
    ),
    PromptMessage(role: 'user', content: 'hi', isHistory: true),
    PromptMessage(role: 'assistant', content: 'hello', isHistory: true),
  ];

  List<String> rolesOf(List<PreviewMessage> rows) => [
    for (final row in rows) row.message.role,
  ];

  List<String> contentsOf(List<PreviewMessage> rows) => [
    for (final row in rows) row.message.content,
  ];

  test('none leaves every built block as its own row', () {
    final rows = buildPreviewMessages(built, PromptPostProcessing.none);

    expect(rows, hasLength(built.length));
    expect(contentsOf(rows), ['main prompt', 'lore entry', 'hi', 'hello']);
    expect(rows.every((r) => !r.isMerged), isTrue);
  });

  test('none keeps empty blocks the request would drop', () {
    final rows = buildPreviewMessages(const [
      PromptMessage(role: 'system', content: ''),
    ], PromptPostProcessing.none);

    expect(rows, hasLength(1));
  });

  test('merge folds consecutive same-role blocks into one row', () {
    final rows = buildPreviewMessages(built, PromptPostProcessing.merge);

    expect(rolesOf(rows), ['system', 'user', 'assistant']);
    expect(rows.first.message.content, 'main prompt\n\nlore entry');
    expect(rows.first.isMerged, isTrue);
    expect(rows.first.sources, hasLength(2));
    // The merged row inherits every source's classification, so the section
    // filters still find it.
    expect(rows.first.message.isLorebook, isTrue);
    expect(rows.first.message.blockName, 'Main Prompt + Lorebook');
    expect(rows[1].isMerged, isFalse);
    expect(rows[1].message.blockName, isNull);
  });

  test('merge drops the empty blocks the request drops', () {
    final rows = buildPreviewMessages(const [
      PromptMessage(role: 'system', content: 'kept'),
      PromptMessage(role: 'system', content: ''),
    ], PromptPostProcessing.merge);

    expect(rows, hasLength(1));
    expect(rows.single.message.content, 'kept');
    expect(rows.single.sources, hasLength(1));
  });

  test('merge drops a whitespace-only block by default', () {
    final rows = buildPreviewMessages(const [
      PromptMessage(role: 'system', content: 'kept'),
      PromptMessage(role: 'system', content: '   '),
    ], PromptPostProcessing.merge);

    expect(rows, hasLength(1));
    expect(rows.single.message.content, 'kept');
    expect(rows.single.sources, hasLength(1));
  });

  test('merge keeps an explicitly enabled empty block', () {
    final rows = buildPreviewMessages(const [
      PromptMessage(role: 'system', content: 'kept'),
      PromptMessage(role: 'system', content: '', sendEmptyBlock: true),
    ], PromptPostProcessing.merge);

    expect(rows, hasLength(1));
    expect(rows.single.sources, hasLength(2));
  });

  test('semi relabels every system block after the first', () {
    final rows = buildPreviewMessages(const [
      PromptMessage(role: 'system', content: 'main'),
      PromptMessage(role: 'user', content: 'hi'),
      PromptMessage(role: 'system', content: 'jailbreak'),
    ], PromptPostProcessing.semi);

    expect(rolesOf(rows), ['system', 'user']);
    expect(rows[1].message.content, 'hi\n\njailbreak');
    expect(rows[1].sources, hasLength(2));
  });

  test('strict surfaces the filler turn as a row with no source block', () {
    final rows = buildPreviewMessages(const [
      PromptMessage(role: 'system', content: 'main'),
      PromptMessage(role: 'assistant', content: 'opening line'),
    ], PromptPostProcessing.strict);

    expect(rolesOf(rows), ['system', 'user', 'assistant']);
    expect(rows[1].message.content, promptPostProcessingPlaceholder);
    expect(rows[1].sources, isEmpty);
    expect(rows[1].isMerged, isFalse);
  });

  test('single collapses the whole prompt into one user row', () {
    final rows = buildPreviewMessages(
      built,
      PromptPostProcessing.single,
      charName: 'Character',
      userName: 'User',
    );

    expect(rows, hasLength(1));
    expect(rows.single.message.role, 'user');
    expect(rows.single.sources, hasLength(built.length));
    expect(
      rows.single.message.content,
      'main prompt\n\nlore entry\n\nUser: hi\n\nCharacter: hello',
    );
  });

  test('the tool-preserving half of a family behaves like the family', () {
    expect(
      contentsOf(buildPreviewMessages(built, PromptPostProcessing.mergeTools)),
      contentsOf(buildPreviewMessages(built, PromptPostProcessing.merge)),
    );
  });

  test('an unknown mode is treated as no post-processing', () {
    final rows = buildPreviewMessages(built, 'not-a-mode');

    expect(rows, hasLength(built.length));
  });

  test('merged rows keep every attachment folded into them', () {
    const png = 'data:image/png;base64,AAAA';
    const jpg = 'data:image/jpeg;base64,BBBB';
    final rows = buildPreviewMessages(const [
      PromptMessage(role: 'user', content: 'look', imagePath: png),
      PromptMessage(role: 'user', content: '', imagePath: jpg),
    ], PromptPostProcessing.merge);

    expect(rows, hasLength(1));
    expect(rows.single.imagePaths, [png, jpg]);
    // The image-only block contributes no text, so nothing dangles behind the
    // merge separator.
    expect(rows.single.message.content, 'look');
  });

  // The preview must not drift from the transport: the rows it lists are the
  // messages the request actually carries.
  for (final mode in const [
    PromptPostProcessing.merge,
    PromptPostProcessing.semi,
    PromptPostProcessing.strict,
    PromptPostProcessing.single,
  ]) {
    test('$mode rows match what the request body carries', () {
      final rows = buildPreviewMessages(
        built,
        mode,
        charName: 'Character',
        userName: 'User',
      );
      final sent = postProcessPrompt(
        buildApiMessages(built),
        mode,
        charName: 'Character',
        userName: 'User',
      );

      expect(rolesOf(rows), [for (final m in sent) m['role']]);
      expect(contentsOf(rows), [for (final m in sent) m['content']]);
    });
  }
}
