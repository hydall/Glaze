import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/composer_empty_action_provider.dart';
import 'package:glaze_flutter/features/chat/composer_pins_provider.dart';
import 'package:glaze_flutter/features/chat/state/chat_drawer_editing_provider.dart';
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
      bool isDrawerOpen = false,
      VoidCallback? onMagicDrawer,
    }) {
      sentMessages = [];
      return ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ChatInputBar(
              isDrawerOpen: isDrawerOpen,
              onMagicDrawer: onMagicDrawer,
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

    testWidgets('pending send clears the composer before the durable write', (
      tester,
    ) async {
      // The append behind a send re-encodes the whole message list. Waiting
      // for that to land before emptying the box left the message sitting in
      // the composer next to its own bubble, reading as a send that never
      // registered.
      final accepted = Completer<bool>();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ChatInputBar(
                initialDraft: 'clear me now',
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
      expect(textField.controller!.text, isEmpty);

      accepted.complete(true);
      await tester.pump();
      textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.controller!.text, isEmpty);
    });

    testWidgets('a rejected pending send puts the text back', (tester) async {
      final accepted = Completer<bool>();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ChatInputBar(
                initialDraft: 'give me back',
                isGenerating: false,
                onSend: (_) => accepted.future,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );

      accepted.complete(false);
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'give me back',
      );
    });

    testWidgets('a rejected send does not overwrite newer text', (
      tester,
    ) async {
      final accepted = Completer<bool>();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ChatInputBar(
                initialDraft: 'the old one',
                isGenerating: false,
                onSend: (_) => accepted.future,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'the new one');
      await tester.pump();

      accepted.complete(false);
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'the new one',
      );
    });

    testWidgets('the empty composer impersonates when nothing is assigned', (
      tester,
    ) async {
      var impersonateCalls = 0;
      await tester.pumpWidget(
        buildChatInputBar(onImpersonate: (_) => impersonateCalls++),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.account_circle_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.account_circle_rounded));

      expect(impersonateCalls, 1);
    });

    testWidgets('an assigned action takes over the empty composer', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        ComposerEmptyActionNotifier.storageKey: 'action:guidance',
      });
      var impersonateCalls = 0;
      await tester.pumpWidget(
        buildChatInputBar(onImpersonate: (_) => impersonateCalls++),
      );
      await tester.pumpAndSettle();

      // The assignment lends the button its glyph, so the state is readable
      // without tapping it.
      expect(find.byIcon(Icons.account_circle_rounded), findsNothing);
      final sendButton = find.ancestor(
        of: find.byIcon(ComposerAction.guidance.icon),
        matching: find.byType(InkWell),
      );
      expect(sendButton, findsOneWidget);

      await tester.tap(sendButton);
      await tester.pumpAndSettle();

      expect(impersonateCalls, 0);
      // Guidance mode opened: the steering field is the composer's second box.
      expect(find.byType(TextField), findsNWidgets(2));
    });

    testWidgets('a stored action this build cannot resolve impersonates', (
      tester,
    ) async {
      // A quick reply that has since been deleted resolves to nothing. The
      // button falls back rather than going dead.
      SharedPreferences.setMockInitialValues({
        ComposerEmptyActionNotifier.storageKey: 'reply:qr-gone',
      });
      var impersonateCalls = 0;
      await tester.pumpWidget(
        buildChatInputBar(onImpersonate: (_) => impersonateCalls++),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.account_circle_rounded));

      expect(impersonateCalls, 1);
    });

    testWidgets('edit mode kills the empty tap but not send or stop', (
      tester,
    ) async {
      var impersonateCalls = 0;
      var stopCalls = 0;
      await tester.pumpWidget(
        buildChatInputBar(
          isDrawerOpen: true,
          onMagicDrawer: () {},
          onImpersonate: (_) => impersonateCalls++,
          onStop: () => stopCalls++,
        ),
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatInputBar)),
      );
      container.read(chatDrawerEditingProvider.notifier).state = true;
      await tester.pumpAndSettle();

      // A tap that both retargets the slot and fires it would be a trap.
      await tester.tap(find.byIcon(Icons.account_circle_rounded));
      await tester.pump();
      expect(impersonateCalls, 0);

      // Sending is not what the drop is aimed at, so it stays live.
      await tester.enterText(find.byType(TextField).first, 'still sends');
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();
      expect(sentMessages, ['still sends']);
      expect(stopCalls, 0);
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
