import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/widgets/chat_input_bar.dart';
import 'package:glaze_flutter/features/chat/widgets/input_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ChatInputBar', () {
    late List<String> sentMessages;

    Widget buildChatInputBar({
      FocusNode? focusNode,
      bool virtualKeyboardSend = false,
      bool enterToSend = true,
      bool isEditingMessage = false,
      bool isGeneratingImage = false,
      String initialDraft = '',
      void Function(String? guidance)? onImpersonate,
      VoidCallback? onStop,
      bool acceptSend = true,
    }) {
      sentMessages = [];
      return ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ChatInputBar(
              onSend: (text) async {
                sentMessages.add(text);
                return acceptSend;
              },
              isGenerating: false,
              isGeneratingImage: isGeneratingImage,
              focusNode: focusNode,
              virtualKeyboardSend: virtualKeyboardSend,
              enterToSend: enterToSend,
              isEditingMessage: isEditingMessage,
              initialDraft: initialDraft,
              onImpersonate: onImpersonate,
              onStop: onStop,
            ),
          ),
        ),
      );
    }

    testWidgets('TextField has textCapitalization.sentences', (tester) async {
      await tester.pumpWidget(buildChatInputBar());
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.textCapitalization, TextCapitalization.sentences);
    });

    testWidgets('onTap unfocuses then refocuses when already focused', (
      tester,
    ) async {
      final focusNode = FocusNode();
      await tester.pumpWidget(buildChatInputBar(focusNode: focusNode));
      addTearDown(() => focusNode.dispose());

      focusNode.requestFocus();
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);

      await tester.tap(find.byType(TextField));
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
    });

    testWidgets('onTap requests focus when not focused', (tester) async {
      final focusNode = FocusNode();
      await tester.pumpWidget(buildChatInputBar(focusNode: focusNode));
      addTearDown(() => focusNode.dispose());

      expect(focusNode.hasFocus, isFalse);

      await tester.tap(find.byType(TextField));
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
    });

    testWidgets('virtualKeyboardSend uses TextInputAction.send', (
      tester,
    ) async {
      await tester.pumpWidget(buildChatInputBar(virtualKeyboardSend: true));
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.textInputAction, TextInputAction.send);
    });

    testWidgets('non-virtualKeyboardSend uses TextInputAction.newline', (
      tester,
    ) async {
      await tester.pumpWidget(buildChatInputBar(virtualKeyboardSend: false));
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.textInputAction, TextInputAction.newline);
    });

    testWidgets('editing blocks impersonate action', (tester) async {
      var impersonateCalls = 0;
      await tester.pumpWidget(
        buildChatInputBar(
          isEditingMessage: true,
          onImpersonate: (_) => impersonateCalls++,
        ),
      );

      await tester.tap(find.byIcon(Icons.account_circle_rounded));

      expect(impersonateCalls, 0);
    });

    testWidgets('editing blocks sending an existing draft', (tester) async {
      await tester.pumpWidget(
        buildChatInputBar(isEditingMessage: true, initialDraft: 'draft'),
      );

      await tester.tap(find.byIcon(Icons.send_rounded));

      expect(sentMessages, isEmpty);
    });

    testWidgets('rejected send keeps the composed text', (tester) async {
      await tester.pumpWidget(
        buildChatInputBar(initialDraft: 'keep me', acceptSend: false),
      );

      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();

      expect(sentMessages, ['keep me']);
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.controller!.text, 'keep me');
    });

    testWidgets('pending send does not clear text before durable acceptance', (
      tester,
    ) async {
      final accepted = Completer<bool>();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ChatInputBar(
                initialDraft: 'wait for db',
                isGenerating: false,
                onSend: (_) => accepted.future,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      var textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.controller!.text, 'wait for db');

      accepted.complete(true);
      await tester.pump();
      textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.controller!.text, isEmpty);
    });

    testWidgets('image generation stop button remains tappable', (
      tester,
    ) async {
      var stopCalls = 0;
      await tester.pumpWidget(
        buildChatInputBar(isGeneratingImage: true, onStop: () => stopCalls++),
      );

      final stopButton = find.ancestor(
        of: find.byIcon(Icons.stop_rounded),
        matching: find.byType(InkWell),
      );
      expect(stopButton, findsOneWidget);

      await tester.tap(stopButton);
      expect(stopCalls, 1);
    });
  });

  group('InputBar', () {
    late List<String> sentMessages;

    Widget buildInputBar() {
      sentMessages = [];
      return ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: InputBar(
              onSend: (text) => sentMessages.add(text),
              isGenerating: false,
            ),
          ),
        ),
      );
    }

    testWidgets('TextField has textCapitalization.sentences', (tester) async {
      await tester.pumpWidget(buildInputBar());
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.textCapitalization, TextCapitalization.sentences);
    });

    testWidgets('onTap unfocuses then refocuses when already focused', (
      tester,
    ) async {
      await tester.pumpWidget(buildInputBar());

      final textField = tester.widget<TextField>(find.byType(TextField));
      final focusNode = textField.focusNode!;

      focusNode.requestFocus();
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);
    });
  });
}
