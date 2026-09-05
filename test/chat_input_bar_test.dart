import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart'
    show maxMessageAttachments;
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
    late List<List<String>> sentAttachments;

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
      sentAttachments = [];
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
              onSendWithImages: (text, guidance, imageDataUrls) async {
                sentMessages.add(text);
                sentAttachments.add(imageDataUrls);
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

    group('clipboard attachments', () {
      // A 1x1 PNG, so the thumbnail really decodes and the data URL really
      // round-trips through the send callback.
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
        'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      );

      /// What the platform side of `pasteboard` hands back for `image` on this
      /// host: bytes everywhere except Windows, which passes a path to a file
      /// the plugin reads and deletes.
      Object clipboardImagePayload(Uint8List bytes) {
        if (!Platform.isWindows) return bytes;
        final file = File(
          '${Directory.systemTemp.createTempSync('glaze_pb').path}/clip.png',
        )..writeAsBytesSync(bytes);
        return file.path;
      }

      /// Puts an image and/or text on the fake clipboard. No image is what
      /// makes a paste fall through to the ordinary text paste.
      void mockClipboard({
        Uint8List? image,
        List<String> files = const [],
        String? text,
      }) {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(const MethodChannel('pasteboard'), (
          call,
        ) async {
          switch (call.method) {
            case 'image':
              return image == null ? null : clipboardImagePayload(image);
            case 'files':
              return files;
          }
          return null;
        });
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          if (call.method == 'Clipboard.getData') {
            return text == null ? null : <String, dynamic>{'text': text};
          }
          return null;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(
            const MethodChannel('pasteboard'),
            null,
          );
          messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        });
      }

      Future<void> pressPaste(WidgetTester tester) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
      }

      testWidgets('Ctrl+V attaches the clipboard image and sends it', (
        tester,
      ) async {
        mockClipboard(image: png);
        final focusNode = FocusNode();
        addTearDown(focusNode.dispose);
        await tester.pumpWidget(buildChatInputBar(focusNode: focusNode));
        focusNode.requestFocus();
        await tester.pump();

        await pressPaste(tester);

        expect(
          find.byType(Image),
          findsOneWidget,
          reason: 'the pasted image must show as a composer thumbnail',
        );

        await tester.tap(find.byIcon(Icons.send_rounded));
        await tester.pump();

        expect(sentAttachments, hasLength(1));
        expect(sentAttachments.single, hasLength(1));
        expect(
          sentAttachments.single.single,
          'data:image/png;base64,${base64Encode(png)}',
        );
      });

      testWidgets('Ctrl+V with no image on the clipboard pastes the text', (
        tester,
      ) async {
        mockClipboard(text: 'pasted');
        final focusNode = FocusNode();
        addTearDown(focusNode.dispose);
        await tester.pumpWidget(
          buildChatInputBar(focusNode: focusNode, initialDraft: 'a'),
        );
        focusNode.requestFocus();
        await tester.pump();

        await pressPaste(tester);

        final textField = tester.widget<TextField>(find.byType(TextField));
        expect(textField.controller!.text, 'apasted');
        expect(find.byType(Image), findsNothing);
      });

      testWidgets('a fifth paste is refused, not silently swallowed', (
        tester,
      ) async {
        mockClipboard(image: png);
        final focusNode = FocusNode();
        addTearDown(focusNode.dispose);
        await tester.pumpWidget(buildChatInputBar(focusNode: focusNode));
        focusNode.requestFocus();
        await tester.pump();

        for (var i = 0; i < 5; i++) {
          await pressPaste(tester);
        }
        // The fifth paste raises the limit toast; let it expire so the test
        // does not end on a pending timer.
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();

        expect(find.byType(Image), findsNWidgets(maxMessageAttachments));

        await tester.tap(find.byIcon(Icons.send_rounded));
        await tester.pump();

        expect(sentAttachments.single, hasLength(maxMessageAttachments));
      });
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

    testWidgets('the empty slot takes an Actions drop and refuses a tool', (
      tester,
    ) async {
      // Stands in for the drawer's grids, which drag this very payload type.
      Widget handle(String label, ComposerPin pin) => Draggable<ComposerPin>(
        key: ValueKey(label),
        data: pin,
        feedback: const SizedBox(width: 20, height: 20),
        // Painted, not a bare SizedBox: an empty box does not hit-test, so the
        // gesture would never reach the [Draggable] and the drag would never
        // start — a green test proving nothing.
        child: const ColoredBox(
          color: Color(0xFF00FF00),
          child: SizedBox(width: 20, height: 20),
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  handle('tool', ComposerPin.tool('char-card')),
                  handle('reply', ComposerPin.action(ComposerAction.guidance)),
                  ChatInputBar(
                    isGenerating: false,
                    isDrawerOpen: true,
                    onMagicDrawer: () {},
                    onSend: (_) async => true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatInputBar)),
      );
      container.read(chatDrawerEditingProvider.notifier).state = true;
      await tester.pumpAndSettle();

      Future<void> dragOntoSendButton(String label) async {
        final target = tester.getCenter(
          find.byIcon(Icons.account_circle_rounded),
        );
        final origin = tester.getCenter(find.byKey(ValueKey(label)));
        final gesture = await tester.startGesture(origin);
        // Past the drag slop first, so the [Draggable] is actually up before
        // the pointer reaches the button.
        await gesture.moveTo(origin + const Offset(0, 24));
        await tester.pump();
        await gesture.moveTo(target);
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
      }

      // A Tools card opens a sheet about the chat — not what a thumb resting
      // on the send button is reaching for.
      await dragOntoSendButton('tool');
      expect(container.read(composerEmptyActionProvider).value, isNull);
      expect(find.byIcon(Icons.account_circle_rounded), findsOneWidget);

      await dragOntoSendButton('reply');
      expect(
        container.read(composerEmptyActionProvider).value,
        ComposerPin.action(ComposerAction.guidance),
      );
      expect(find.byIcon(Icons.account_circle_rounded), findsNothing);
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
