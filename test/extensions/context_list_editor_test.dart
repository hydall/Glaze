import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/block_context_item.dart';
import 'package:glaze_flutter/features/extensions/screens/preset_editor/block_edit_dialog.dart';
import 'package:glaze_flutter/features/extensions/services/upstream_context_codec.dart';
import 'package:glaze_flutter/shared/widgets/glaze_scaffold.dart';
import 'package:glaze_flutter/shared/widgets/menu_group.dart';

Finder _field(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(MenuFieldItem)),
  matching: find.byType(TextField),
);

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  group('context file', () {
    test('reads the original export, giving id-less items an id', () {
      final items = decodeContextItemsFile({
        'items': [
          {'name': 'Rules', 'role': 'system', 'type': 'text', 'text': 'Be.'},
          {
            'id': 'k',
            'name': 'Since',
            'type': 'last_messages_keyword',
            'keyword_stopper': '###',
          },
          'not an item',
        ],
      })!;
      expect(items, hasLength(2));
      expect(items[0].id, isNotEmpty);
      expect(items[0].role, ContextItemRole.system);
      expect(items[1].keywordStopper, '###');
      expect(items[1].messagesCount, isNull);
      expect(decodeContextItemsFile({'name': 'x'}), isNull);
      expect(decodeContextItemsFile([]), isEmpty);
    });

    test('writes what it reads', () {
      final items = [
        newContextItem(ContextItemType.lastMessages, id: 'a'),
        newContextItem(
          ContextItemType.previousBlock,
          id: 'b',
        ).copyWith(name: 'prev', blockName: 'stats', blockCount: 2),
      ];
      final file = encodeContextItemsFile(items);
      expect((file['items'] as List).first['messages_count'], 10);
      expect(decodeContextItemsFile(file), items);
    });

    test('only the last-messages item keeps a count', () {
      final item = newContextItem(ContextItemType.lastMessages);
      final keyword = withContextType(
        item.copyWith(messagesCount: 4),
        ContextItemType.lastMessagesKeyword,
      );
      expect(keyword.messagesCount, isNull);
      expect(
        withContextType(keyword, ContextItemType.lastMessages).messagesCount,
        10,
      );
    });
  });

  testWidgets('a context item is added, replaces the old settings and saves', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 5200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    BlockConfig? saved;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDbProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Scaffold(
            body: BlockEditDialog(
              block: const BlockConfig(id: 'b', name: 'Ledger'),
              onSave: (block) => saved = block,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ctx_list_header'), findsOneWidget);
    expect(find.text('ctx_list_empty'), findsOneWidget);
    expect(find.text('block_context_count_label'), findsOneWidget);

    await _tapVisible(tester, find.text('ctx_list_add'));
    expect(find.text('ctx_item_title'), findsOneWidget);

    // A nameless item is refused, as in the original.
    await _tapVisible(
      tester,
      find.widgetWithText(GlazePillButton, 'btn_save').last,
    );
    expect(find.text('ctx_item_title'), findsOneWidget);

    await tester.enterText(_field('ctx_item_name'), 'Recent');
    await _tapVisible(tester, find.text('ctx_item_type'));
    await _tapVisible(tester, find.text('ctx_type_last_messages').last);
    await tester.enterText(_field('ctx_item_char_prefix'), r'\n> ');
    await _tapVisible(
      tester,
      find.widgetWithText(GlazePillButton, 'btn_save').last,
    );

    expect(find.text('ctx_item_title'), findsNothing);
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('ctx_list_active_help'), findsOneWidget);
    expect(find.text('block_context_count_label'), findsNothing);

    await _tapVisible(
      tester,
      find.widgetWithText(GlazePillButton, 'btn_save').last,
    );
    final item = saved!.context.single;
    expect(item.name, 'Recent');
    expect(item.type, ContextItemType.lastMessages);
    expect(item.messagesCount, 10);
    expect(item.charPrefix, '\n> ');
  });
}
