import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatWebViewWidget callback contract (Phase 4.4 characterization)', () {
    late String webviewWidgetSource;
    late String bridgeControllerSource;
    late String bridgeHandlersSource;

    setUpAll(() {
      webviewWidgetSource = File(
        'lib/features/chat/widgets/chat_webview_widget.dart',
      ).readAsStringSync();
      bridgeControllerSource = File(
        'lib/features/chat/bridge/chat_bridge_controller.dart',
      ).readAsStringSync();
      bridgeHandlersSource = File(
        'lib/features/chat/bridge/bridge_handlers.dart',
      ).readAsStringSync();
    });

    test('widget has 5 callback group parameters', () {
      final callbackGroups = [
        'MessageActionsCallbacks',
        'EditActionsCallbacks',
        'ImageGenCallbacks',
        'ScrollCallbacks',
        'MiscCallbacks',
      ];
      for (final name in callbackGroups) {
        expect(
          webviewWidgetSource,
          contains(name),
          reason: 'Widget must accept callback group "$name"',
        );
      }
    });

    test('all expected onXxx callbacks exist in callback classes', () {
      final callbacksSource = File(
        'lib/features/chat/widgets/webview_callbacks.dart',
      ).readAsStringSync();
      final expectedCallbacks = [
        'onMessageContext',
        'onSwipe',
        'onChangeGreeting',
        'onRegenerate',
        'onHeaderScroll',
        'onStop',
        'onSelectionAction',
        'onEditSave',
        'onEditCancel',
        'onImageClick',
        'onGuidedSwipe',
        'onMemoryClick',
        'onToggleHidden',
        'onInjectClick',
        'onImgRetry',
        'onImgFind',
        'onImgRegen',
        'onImgCancel',
        'onSelectionChange',
      ];
      for (final name in expectedCallbacks) {
        expect(
          callbacksSource,
          contains(name),
          reason: 'Callback classes must declare callback "$name"',
        );
      }
    });

    test('Bridge controller has expected callback properties', () {
      final callbackProps = [
        'onReady',
        'onLoadMore',
        'onHeaderScroll',
        'onLinkClick',
        'onImageClick',
        'onMessageContext',
        'onSwipe',
        'onRegenerate',
        'onChangeGreeting',
        'onSelectionAction',
        'onEditSave',
        'onEditCancel',
        'onGuidedSwipe',
        'onMemoryClick',
        'onToggleHidden',
        'onSelectionChange',
        'onInjectClick',
        'onImgRetry',
        'onImgFind',
        'onImgRegen',
        'onImgCancel',
        'onStop',
      ];
      for (final name in callbackProps) {
        expect(
          bridgeControllerSource,
          contains(name),
          reason: 'Bridge controller must have callback property "$name"',
        );
      }
    });

    test('onMessageContext is adapted (adds index lookup)', () {
      // The index lookup is now in `ChatWebViewCallbacks` (extracted
      // from the widget during the Phase 3 refactor).
      final callbacksAdapterSource = File(
        'lib/features/chat/widgets/chat_webview_callbacks.dart',
      ).readAsStringSync();
      expect(
        callbacksAdapterSource,
        contains('indexWhere'),
        reason: 'onMessageContext adapter must look up message index',
      );
    });

    test('onLinkClick is handled internally (url_launcher)', () {
      // The `launchUrl` call is now in `ChatWebViewCallbacks`
      // (extracted from the widget during the Phase 3 refactor).
      final callbacksAdapterSource = File(
        'lib/features/chat/widgets/chat_webview_callbacks.dart',
      ).readAsStringSync();
      expect(
        callbacksAdapterSource,
        contains('launchUrl'),
        reason: 'onLinkClick must be handled internally with url_launcher',
      );
    });

    test('onLoadMore is handled internally (chatProvider)', () {
      // The `loadOlderMessages` call is now in `ChatWebViewCallbacks`
      // (extracted from the widget during the Phase 3 refactor).
      final callbacksAdapterSource = File(
        'lib/features/chat/widgets/chat_webview_callbacks.dart',
      ).readAsStringSync();
      expect(
        callbacksAdapterSource,
        contains('loadOlderMessages'),
        reason: 'onLoadMore must be handled internally via chatProvider',
      );
    });

    test(
      'bridge _setupHandlers registers addJavaScriptHandler for each callback',
      () {
        // After C6 split, the registry of handler names lives in
        // bridge_handlers.dart (a data-driven table) and the host
        // iterates that map to register each addJavaScriptHandler. We
        // verify the registry covers every callback name and that the
        // host actually wires it up.
        final expectedHandlers = [
          'onWebViewReady',
          'onLoadMore',
          'onHeaderScroll',
          'onLinkClick',
          'onImageClick',
          'onMessageContext',
          'onSwipe',
          'onRegenerate',
          'onChangeGreeting',
          'onSelectionAction',
          'onEditSave',
          'onEditCancel',
          'onGuidedSwipe',
          'onMemoryClick',
          'onToggleHidden',
          'onSelectionChange',
          'onInjectClick',
          'onImgRetry',
          'onImgFind',
          'onImgRegen',
          'onImgCancel',
          'onStop',
        ];
        for (final name in expectedHandlers) {
          expect(
            bridgeHandlersSource,
            contains("'$name':"),
            reason: 'bridge_handlers.dart must declare handler "$name"',
          );
          expect(
            bridgeControllerSource,
            contains('addJavaScriptHandler'),
            reason: 'host must register handlers via addJavaScriptHandler',
          );
        }
        // The host must actually wire up the registry — verify the
        // setupHandlers method iterates the bridgeHandlers map.
        expect(
          bridgeControllerSource,
          contains('for (final entry in bridgeHandlers.entries)'),
          reason: 'host setupHandlers must iterate the bridgeHandlers registry',
        );
      },
    );

    test(
      'image callbacks (retry/find/regen) have (String, String) signature',
      () {
        for (final name in ['onImgRetry', 'onImgFind', 'onImgRegen']) {
          expect(
            bridgeControllerSource,
            contains(
              'void Function(String instruction, String messageId)? $name;',
            ),
            reason:
                '$name must accept (String instruction, String messageId) parameters',
          );
        }
      },
    );

    test('onImgCancel and onStop have no-arg signature', () {
      expect(
        bridgeControllerSource,
        contains('void Function()? onImgCancel;'),
        reason: 'onImgCancel must be a no-arg callback',
      );
      expect(
        bridgeControllerSource,
        contains('void Function()? onStop;'),
        reason: 'onStop must be a no-arg callback',
      );
    });

    test('non-callback data props (charId, messages, etc) exist', () {
      final expectedDataProps = [
        'charId',
        'messages',
        'isGenerating',
        'isGeneratingImage',
        'bottomInset',
        'topInset',
        'searchQuery',
        'chatLayout',
        'greetingTotal',
        'chatFontName',
        'chatFontSize',
        'memoryEntries',
        'sessionId',
        'visibleStartIndex',
        'regenTargetId',
        'isSelectionMode',
      ];
      for (final prop in expectedDataProps) {
        expect(
          webviewWidgetSource,
          contains(prop),
          reason: 'Widget must have data prop "$prop"',
        );
      }
    });
  });
}
