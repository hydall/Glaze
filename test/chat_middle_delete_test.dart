import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/controllers/chat_message_selection_controller.dart';
import 'package:glaze_flutter/features/chat/widgets/chat_input_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

ChatMessage _msg(String id) =>
    ChatMessage(id: id, role: 'assistant', content: id);

List<ChatMessage> _messages(int count) =>
    List.generate(count, (i) => _msg('m$i'));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ChatMessageSelectionController.canDeleteSelection', () {
    test('rejects an empty selection', () {
      final ctrl = ChatMessageSelectionController();
      expect(
        ctrl.canDeleteSelection(_messages(3), allowMiddle: false),
        isFalse,
      );
      expect(ctrl.canDeleteSelection(_messages(3), allowMiddle: true), isFalse);
    });

    test('allows deleting only the last message', () {
      final ctrl = ChatMessageSelectionController()..updateSelection(['m2']);
      expect(ctrl.canDeleteSelection(_messages(3), allowMiddle: false), isTrue);
    });

    test('allows a trailing run that starts before the end', () {
      final ctrl = ChatMessageSelectionController()
        ..updateSelection(['m1', 'm2']);
      expect(ctrl.canDeleteSelection(_messages(3), allowMiddle: false), isTrue);
    });

    test('rejects a lone message in the middle', () {
      final ctrl = ChatMessageSelectionController()..updateSelection(['m1']);
      expect(
        ctrl.canDeleteSelection(_messages(3), allowMiddle: false),
        isFalse,
      );
    });

    test('rejects a selection with a gap after it', () {
      final ctrl = ChatMessageSelectionController()
        ..updateSelection(['m0', 'm2']);
      expect(
        ctrl.canDeleteSelection(_messages(3), allowMiddle: false),
        isFalse,
      );
    });

    test('rejects a run that stops short of the last message', () {
      final ctrl = ChatMessageSelectionController()
        ..updateSelection(['m0', 'm1']);
      expect(
        ctrl.canDeleteSelection(_messages(3), allowMiddle: false),
        isFalse,
      );
    });

    test('allowMiddle lifts the restriction', () {
      final ctrl = ChatMessageSelectionController()..updateSelection(['m1']);
      expect(ctrl.canDeleteSelection(_messages(3), allowMiddle: true), isTrue);
    });
  });

  group('ChatInputBar delete button', () {
    Widget build({required bool canDeleteSelected}) => ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: ChatInputBar(
            isGenerating: false,
            isSelectionMode: true,
            selectedCount: 2,
            canDeleteSelected: canDeleteSelected,
            onSend: (_) async => true,
          ),
        ),
      ),
    );

    testWidgets('is hidden when the selection cannot be deleted', (
      tester,
    ) async {
      await tester.pumpWidget(build(canDeleteSelected: false));
      expect(find.byIcon(Icons.delete), findsNothing);
    });

    testWidgets('is shown when the selection can be deleted', (tester) async {
      await tester.pumpWidget(build(canDeleteSelected: true));
      expect(find.byIcon(Icons.delete), findsOneWidget);
    });
  });
}
