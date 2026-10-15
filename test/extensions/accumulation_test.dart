import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/services/accumulation/accumulation_service.dart';
import 'package:glaze_flutter/features/extensions/services/accumulation/mongo_update.dart';
import 'package:glaze_flutter/features/extensions/services/accumulation/yaml_codec.dart';
import 'package:glaze_flutter/features/extensions/services/ext_blocks_panel_builder.dart';

Map<String, Object?> _update(Map<String, Object?> doc, String yaml) =>
    applyMongoUpdate(doc, parseYaml(yaml));

void main() {
  group('mongo update', () {
    test('runs the original editor example', () {
      final doc = <String, Object?>{
        'gold': 5,
        'inventory': ['Shield'],
        'knownLocations': [
          {'name': 'Village', 'visited': false},
          {'name': 'Cave', 'visited': false},
        ],
      };
      _update(doc, r'''
$inc:
  gold: 10
$push:
  inventory: Sword
$set:
  status.is_happy: true
  "knownLocations.$[elem].visited": true
arrayFilters:
  - "elem.name": "Village"
''');
      expect(doc['gold'], 15);
      expect(doc['inventory'], ['Shield', 'Sword']);
      expect(doc['status'], {'is_happy': true});
      expect(doc['knownLocations'], [
        {'name': 'Village', 'visited': true},
        {'name': 'Cave', 'visited': false},
      ]);
    });

    test('folds bare keys into \$set and lists into \$each', () {
      final doc = _update({}, r'''
hp: 3
$push:
  log: [a, b]
$addToSet:
  tags: [x, x, y]
''');
      expect(doc, {
        'hp': 3,
        'log': ['a', 'b'],
        'tags': ['x', 'y'],
      });
    });

    test('number, unset, rename, pop and min/max operators', () {
      final doc = <String, Object?>{
        'a': 2,
        'b': 10,
        'old': 'v',
        'list': [1, 2, 3],
        'gone': true,
      };
      _update(doc, r'''
$mul: {a: 3, fresh: 5}
$min: {b: 4}
$max: {c: 7}
$rename: {old: nested.new}
$pop: {list: -1}
$unset: {gone: ""}
''');
      expect(doc, {
        'a': 6,
        'b': 4,
        'list': [2, 3],
        'fresh': 0,
        'c': 7,
        'nested': {'new': 'v'},
      });
    });

    test('pull by value, by operator and by element query', () {
      final doc = <String, Object?>{
        'n': [1, 5, 9],
        's': ['a', 'b'],
        'items': [
          {'name': 'Sword', 'qty': 0},
          {'name': 'Bow', 'qty': 2},
        ],
      };
      _update(doc, r'''
$pull:
  n: {$gte: 5}
  s: a
  items: {qty: 0}
''');
      expect(doc['n'], [1]);
      expect(doc['s'], ['b']);
      expect(doc['items'], [
        {'name': 'Bow', 'qty': 2},
      ]);
    });

    test('push with position, sort and slice', () {
      final doc = <String, Object?>{
        'log': [3, 1],
      };
      _update(doc, r'''
$push:
  log: {$each: [2, 5], $sort: 1, $slice: -3}
''');
      expect(doc['log'], [2, 3, 5]);
    });

    test('index paths, all-elements paths and a condition', () {
      final doc = <String, Object?>{
        'party': [
          {'hp': 1},
          {'hp': 2},
        ],
        'phase': 'night',
      };
      _update(doc, r'''
$inc:
  "party.$[].hp": 1
  "party.0.hp": 10
''');
      expect(doc['party'], [
        {'hp': 12},
        {'hp': 3},
      ]);
      _update(doc, r'''
$set: {phase: day}
condition: {phase: dawn}
''');
      expect(doc['phase'], 'night');
    });

    test('refuses an unknown operator or a number op on text', () {
      expect(
        () => _update({}, r'$frobnicate: {a: 1}'),
        throwsA(isA<MongoUpdateError>()),
      );
      expect(
        () => _update({'a': 'x'}, r'$inc: {a: 1}'),
        throwsA(isA<MongoUpdateError>()),
      );
    });
  });

  group('yaml', () {
    test('dumps nested state the way js-yaml does', () {
      final yaml = dumpYaml({
        'gold': 15,
        'ratio': 2.0,
        'name': 'Ann: the brave',
        'flag': 'yes',
        'empty': <String, Object?>{},
        'inventory': ['Sword', 'Shield'],
        'party': [
          {'name': 'Bo', 'hp': 3},
        ],
        'notes': 'line one\nline two',
      });
      expect(yaml, '''
gold: 15
ratio: 2
name: 'Ann: the brave'
flag: 'yes'
empty: {}
inventory:
  - Sword
  - Shield
party:
  - name: Bo
    hp: 3
notes: |-
  line one
  line two
''');
    });

    test('reads back what it writes', () {
      final state = <String, Object?>{
        'a': [
          [1, 2],
          {'b': null, 'c': "it's"},
        ],
        'd': '  padded ',
        'e': 'tab\there',
        'f': '',
        'g': '123',
        'h': 'trailing\n',
      };
      expect(parseYaml(dumpYaml(state)), state);
    });

    test('strips a markdown fence around the YAML', () {
      expect(parseYaml('```yaml\na: 1\n```'), {'a': 1});
    });
  });

  group('accumulateYaml', () {
    test('applies an update to the previous state', () {
      final step = accumulateYaml(
        previousState: 'gold: 1\n',
        updaterText: r'$inc: {gold: 2}',
      );
      expect(step.errors, isEmpty);
      expect(step.state, 'gold: 3');
    });

    test('reads a broken state as empty, as the original does', () {
      final step = accumulateYaml(previousState: 'a: [', updaterText: 'b: 1');
      expect(step.errors.single.$1, AccumulationError.parseState);
      expect(step.state, 'b: 1');
    });

    test('leaves no state when the update cannot apply', () {
      final step = accumulateYaml(
        previousState: 'a: x',
        updaterText: r'$inc: {a: 1}',
      );
      expect(step.errors.single.$1, AccumulationError.applyUpdate);
      expect(step.state, isNull);
    });
  });

  test('only enabled accumulation blocks with an updater on that side', () {
    const base = BlockConfig(
      id: 'a',
      name: 'stats',
      type: BlockType.accumulation,
      updaterName: 'stats_update',
    );
    final preset = ExtensionPreset(
      id: 'p',
      name: 'p',
      blocks: [
        base,
        base.copyWith(id: 'off', enabled: false),
        base.copyWith(id: 'noupdater', updaterName: ' '),
        base.copyWith(id: 'user', triggerOnUser: true, triggerOnChar: false),
        const BlockConfig(id: 'g', name: 'g'),
      ],
    );
    expect(
      ExtBlocksAccumulator.blocksFor(
        preset,
        BlockTrigger.afterAssistant,
      ).map((b) => b.id),
      ['a'],
    );
    expect(
      ExtBlocksAccumulator.blocksFor(
        preset,
        BlockTrigger.afterUser,
      ).map((b) => b.id),
      ['user'],
    );
    expect(BlockType.accumulation.isRunnable, isTrue);
    expect(BlockType.accumulation.hasPanelResult, isFalse);
  });

  test('the updater prompt names both tags', () {
    final prompt = accumulationUpdaterPrompt('stats', 'stats_update');
    expect(prompt, startsWith('To update the <stats> block, use the '));
    expect(prompt, contains(r'$inc:'));
    expect(prompt, endsWith('</stats_update>'));
  });

  test('the panel shows state as escaped preformatted text', () {
    expect(
      ExtBlocksPanelBuilder.accumulationPanelHtml('a: <b>\n  c: 1'),
      '<pre class="ext-block-state">a: &lt;b&gt;\n  c: 1</pre>',
    );
    expect(ExtBlocksPanelBuilder.accumulationPanelHtml('  '), '');
  });
}
