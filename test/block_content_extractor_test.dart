import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/services/block_content_extractor.dart';

void main() {
  const loomConfig = BlockConfig(
    id: '1',
    name: 'loomledger',
    template: '<loomledger>\n<details><summary>Title</summary>\n\n</details>\n</loomledger>',
  );

  test('extracts inner HTML without re-wrapping outer tag', () {
    const raw = '''
<loomledger>
<details><summary>Day 1</summary>
<p>Some notes</p>
</details>
</loomledger>
''';
    final inner = extractBlockInnerContent(raw, 'loomledger');
    expect(inner, contains('<details>'));
    expect(inner, isNot(contains('<loomledger>')));
  });

  test('empty tag pair returns null for fallback', () {
    expect(extractBlockInnerContent('<loomledger></loomledger>', 'loomledger'), isNull);
    expect(extractBlockInnerContent('<loomledger>   </loomledger>', 'loomledger'), isNull);
  });

  test('resolveBlockContent rejects empty tags even when outer string is non-empty', () {
    final result = resolveBlockContent(
      rawResponse: '<loomledger></loomledger>',
      blockConfig: loomConfig,
      resolvedTemplate: loomConfig.template,
    );
    expect(result, isNull);
  });

  test('resolveBlockContent falls back to raw when tags missing', () {
    const raw = '<details><summary>X</summary><p>Body</p></details>';
    final result = resolveBlockContent(
      rawResponse: raw,
      blockConfig: loomConfig,
      resolvedTemplate: loomConfig.template,
    );
    expect(result, raw);
  });

  test('blank template stores raw response without tag parsing', () {
    const cfg = BlockConfig(id: '2', name: 'notes', template: '');
    const raw = 'Plain block output without XML.';
    final result = resolveBlockContent(
      rawResponse: raw,
      blockConfig: cfg,
      resolvedTemplate: '',
    );
    expect(result, raw);
  });

  test('tag name comes from template, not display name', () {
    const cfg = BlockConfig(
      id: '3',
      name: 'Loom Ledger',
      template: '<loomledger></loomledger>',
    );
    expect(
      extractBlockInnerContent('<loomledger>ok</loomledger>', blockTagName(cfg, cfg.template)),
      'ok',
    );
  });
}
