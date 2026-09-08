import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

String _bridgeAsset(String name) =>
    File('assets/chat_webview/bridge/$name').readAsStringSync();

String _extractBlockBody(String src, int fromIndex) {
  int start = src.indexOf('{', fromIndex);
  if (start == -1) return '';
  int depth = 0;
  for (int i = start; i < src.length; i++) {
    if (src[i] == '{') {
      depth++;
    } else if (src[i] == '}') {
      depth--;
      if (depth == 0) return src.substring(start, i + 1);
    }
  }
  return src.substring(start);
}

void main() {
  late String bridgeJs;
  late String bridgeAllJs;
  late String editControllerJs;
  late String interactionDispatchJs;
  late String messageUpdateBatcherJs;
  late String selectionManagerJs;
  late String swipeGestureHandlerJs;

  setUpAll(() {
    bridgeJs = _bridgeAsset('chat_bridge_controller.js');
    editControllerJs = _bridgeAsset('edit_controller.js');
    interactionDispatchJs = _bridgeAsset('interaction_dispatch.js');
    messageUpdateBatcherJs = _bridgeAsset('message_update_batcher.js');
    selectionManagerJs = _bridgeAsset('selection_manager.js');
    swipeGestureHandlerJs = _bridgeAsset('swipe_gesture_handler.js');
    bridgeAllJs = [
      bridgeJs,
      editControllerJs,
      interactionDispatchJs,
      messageUpdateBatcherJs,
      selectionManagerJs,
      swipeGestureHandlerJs,
    ].join('\n');
  });

  // ─── Phase 3.2: SelectionManager ────────────────────────────────────────
  group('Selection behavior (Phase 3.2 characterization)', () {
    test('setSelectionMode exists on Bridge', () {
      expect(bridgeJs, contains('setSelectionMode(enabled)'));
    });

    test('setSelectionMode delegates to SelectionManager', () {
      expect(bridgeJs, contains('_selectionManager.setSelectionMode(enabled)'));
    });

    test('SelectionManager class exists in bridge.js', () {
      expect(selectionManagerJs, contains('class SelectionManager'));
    });

    test('SelectionManager has setSelectionMode method', () {
      expect(selectionManagerJs, contains('setSelectionMode(enabled)'));
    });

    test('SelectionManager has toggleMessageSelection method', () {
      expect(selectionManagerJs, contains('toggleMessageSelection(messageId)'));
    });

    test('SelectionManager has getSelectedIds method', () {
      expect(selectionManagerJs, contains('getSelectedIds()'));
    });

    test('SelectionManager tracks _selectedIds as Set', () {
      expect(selectionManagerJs, contains('_selectedIds'));
    });

    test('contextmenu listener delegates to SelectionManager', () {
      final marker = "addEventListener('contextmenu'";
      expect(bridgeJs, contains(marker));
      final idx = bridgeJs.indexOf(marker);
      expect(idx, isNot(-1));
      final context = bridgeJs.substring(idx, idx + 2000);
      expect(context, contains('_selectionManager.handleContextMenu'));
    });

    test('selectionchange listener delegates to SelectionManager', () {
      expect(bridgeJs, contains('selectionchange'));
      expect(bridgeJs, contains('_selectionManager.handleSelectionChange'));
    });

    test('_showSelectionBar creates Copy and Quote buttons', () {
      final idx = selectionManagerJs.indexOf('_showSelectionBar(text)');
      final body = _extractBlockBody(selectionManagerJs, idx);
      expect(body, contains('Copy'));
      expect(body, contains('Quote'));
    });

    test('onSelectionChange callback sends selected IDs to Flutter', () {
      expect(selectionManagerJs, contains('onSelectionChange'));
    });

    test('onSelectionAction callback sends action + text to Flutter', () {
      expect(selectionManagerJs, contains('onSelectionAction'));
    });

    test('range selection reads the active virtual list item order', () {
      final idx = bridgeJs.indexOf('  _orderedMessageIds() {');
      final body = _extractBlockBody(bridgeJs, idx);
      expect(body, contains('list?.items'));
      expect(body, contains('items.map(item => item.id)'));
      expect(body, contains("!id.startsWith('__date_')"));
    });

    test('selected text is serialized from rendered ranges', () {
      expect(selectionManagerJs, contains('_renderedSelectionText(selection)'));
      expect(selectionManagerJs, contains('cloneContents()'));
      expect(selectionManagerJs, contains('content.innerText.trim()'));
      expect(
        selectionManagerJs,
        isNot(contains('selText = sel.toString().trim()')),
      );
    });

    test(
      'click in selection mode delegated to SelectionManager.handleClick',
      () {
        final idx = interactionDispatchJs.indexOf('class InteractionDispatch');
        final classBody = _extractBlockBody(interactionDispatchJs, idx);
        expect(classBody, contains('_selectionManager.handleClick'));
      },
    );

    test(
      'SelectionManager exits selection mode when no messages remain selected',
      () {
        expect(selectionManagerJs, contains('exitIfEmpty'));
      },
    );

    test('selection-mode CSS class is toggled by SelectionManager', () {
      final idx = selectionManagerJs.indexOf('class SelectionManager');
      final classBody = _extractBlockBody(selectionManagerJs, idx);
      expect(classBody, contains("'selection-mode'"));
    });
  });

  // ─── Phase 3.3: EditController ──────────────────────────────────────────
  group('Edit behavior (Phase 3.3 characterization)', () {
    test('Bridge has startEdit method that delegates to EditController', () {
      expect(bridgeJs, contains('startEdit(messageId)'));
      expect(bridgeJs, contains('_editController.startEdit'));
    });

    test('Bridge has stopEdit method that delegates to EditController', () {
      expect(bridgeJs, contains('stopEdit(messageId)'));
      expect(bridgeJs, contains('_editController.stopEdit'));
    });

    test('EditController class exists in bridge.js', () {
      expect(editControllerJs, contains('class EditController'));
    });

    test('EditController startEdit creates edit-textarea', () {
      final idx = editControllerJs.indexOf('class EditController');
      final classBody = _extractBlockBody(editControllerJs, idx);
      final startIdx = classBody.indexOf('startEdit(messageId');
      expect(startIdx, isNot(-1));
      final body = _extractBlockBody(classBody, startIdx);
      expect(body, contains('edit-textarea'));
    });

    test('EditController startEdit saves originalHtml in dataset', () {
      final idx = editControllerJs.indexOf('class EditController');
      final classBody = _extractBlockBody(editControllerJs, idx);
      final startIdx = classBody.indexOf('startEdit(messageId');
      final body = _extractBlockBody(classBody, startIdx);
      expect(body, contains('dataset.originalHtml'));
    });

    test('EditController startEdit adds editing class to section', () {
      final idx = editControllerJs.indexOf('class EditController');
      final classBody = _extractBlockBody(editControllerJs, idx);
      final startIdx = classBody.indexOf('startEdit(messageId');
      final body = _extractBlockBody(classBody, startIdx);
      expect(body, contains("'editing'"));
    });

    test(
      'EditController startEdit creates Cancel and Save buttons in footer',
      () {
        final idx = editControllerJs.indexOf('class EditController');
        final classBody = _extractBlockBody(editControllerJs, idx);
        final startIdx = classBody.indexOf('startEdit(messageId');
        final body = _extractBlockBody(classBody, startIdx);
        expect(body, contains('edit-cancel'));
        expect(body, contains('edit-save'));
      },
    );

    test('EditController stopEdit restores originalHtml from dataset', () {
      final idx = editControllerJs.indexOf('class EditController');
      final classBody = _extractBlockBody(editControllerJs, idx);
      final stopIdx = classBody.indexOf('stopEdit(messageId');
      final body = _extractBlockBody(classBody, stopIdx);
      expect(body, contains('dataset.originalHtml'));
    });

    test('EditController stopEdit removes editing class', () {
      final idx = editControllerJs.indexOf('class EditController');
      final classBody = _extractBlockBody(editControllerJs, idx);
      final stopIdx = classBody.indexOf('stopEdit(messageId');
      final body = _extractBlockBody(classBody, stopIdx);
      expect(body, contains("'editing'"));
    });

    test('edit-save action delegates to EditController.handleSave', () {
      final idx = interactionDispatchJs.indexOf("'edit-save':");
      expect(idx, isNot(-1));
      final block = interactionDispatchJs.substring(idx, idx + 300);
      expect(block, contains('_editController.handleSave'));
    });

    test('EditController handleSave sends onEditSave with textarea value', () {
      expect(editControllerJs, contains('handleSave(el)'));
      final idx = editControllerJs.indexOf('handleSave(el)');
      final body = _extractBlockBody(editControllerJs, idx);
      expect(body, contains('onEditSave'));
      expect(body, contains('edit-textarea'));
    });

    test('edit-cancel action delegates to EditController.handleCancel', () {
      final idx = interactionDispatchJs.indexOf("'edit-cancel':");
      expect(idx, isNot(-1));
      final block = interactionDispatchJs.substring(idx, idx + 200);
      expect(block, contains('_editController.handleCancel'));
    });

    test('EditController handleCancel sends onEditCancel', () {
      expect(editControllerJs, contains('handleCancel(el)'));
      final idx = editControllerJs.indexOf('handleCancel(el)');
      final body = _extractBlockBody(editControllerJs, idx);
      expect(body, contains('onEditCancel'));
    });

    test('textarea has auto-resize input listener', () {
      final idx = editControllerJs.indexOf('class EditController');
      final classBody = _extractBlockBody(editControllerJs, idx);
      expect(classBody, contains("addEventListener('input'"));
    });

    test('textarea has wheel listener with scroll speed multiplier', () {
      final idx = editControllerJs.indexOf('class EditController');
      final classBody = _extractBlockBody(editControllerJs, idx);
      expect(classBody, contains("addEventListener('wheel'"));
      expect(classBody, contains('0.3'));
    });

    test(
      'startEdit handles think blocks — separates reasoning from content',
      () {
        final idx = editControllerJs.indexOf('class EditController');
        final classBody = _extractBlockBody(editControllerJs, idx);
        final hasThink =
            classBody.contains('</think') || classBody.contains('<think');
        expect(hasThink, isTrue);
      },
    );
  });

  // ─── Phase 3.4: SwipeGestureHandler ─────────────────────────────────────
  group('Swipe gesture behavior (Phase 3.4 characterization)', () {
    test('SwipeGestureHandler class exists in bridge.js', () {
      expect(swipeGestureHandlerJs, contains('class SwipeGestureHandler'));
    });

    test('Bridge creates SwipeGestureHandler and calls setup', () {
      expect(bridgeJs, contains('_swipeHandler = new SwipeGestureHandler'));
      expect(bridgeJs, contains('_swipeHandler.setup()'));
    });

    test(
      'swipe setup registers touchstart, touchmove, touchend, touchcancel',
      () {
        final idx = swipeGestureHandlerJs.indexOf('class SwipeGestureHandler');
        final classBody = _extractBlockBody(swipeGestureHandlerJs, idx);
        expect(classBody, contains('touchstart'));
        expect(classBody, contains('touchmove'));
        expect(classBody, contains('touchend'));
        expect(classBody, contains('touchcancel'));
      },
    );

    test('swipe uses a horizontal threshold', () {
      final idx = swipeGestureHandlerJs.indexOf('class SwipeGestureHandler');
      final classBody = _extractBlockBody(swipeGestureHandlerJs, idx);
      expect(classBody, contains('THRESHOLD'));
    });

    test('swipe cancels when vertical scroll is detected', () {
      final idx = swipeGestureHandlerJs.indexOf('class SwipeGestureHandler');
      final classBody = _extractBlockBody(swipeGestureHandlerJs, idx);
      expect(classBody, contains('scrollingVertical'));
    });

    test('swipe applies translateX transform during drag', () {
      final idx = swipeGestureHandlerJs.indexOf('class SwipeGestureHandler');
      final classBody = _extractBlockBody(swipeGestureHandlerJs, idx);
      expect(classBody, contains('translateX'));
    });

    test('left swipe on last message triggers regeneration', () {
      final idx = swipeGestureHandlerJs.indexOf('class SwipeGestureHandler');
      final classBody = _extractBlockBody(swipeGestureHandlerJs, idx);
      expect(classBody, contains('onRegenerate'));
    });

    test('swipe past threshold triggers onSwipe', () {
      final idx = swipeGestureHandlerJs.indexOf('class SwipeGestureHandler');
      final classBody = _extractBlockBody(swipeGestureHandlerJs, idx);
      expect(classBody, contains('onSwipe'));
    });

    test('greeting swipe triggers onChangeGreeting', () {
      final idx = swipeGestureHandlerJs.indexOf('class SwipeGestureHandler');
      final classBody = _extractBlockBody(swipeGestureHandlerJs, idx);
      expect(classBody, contains('onChangeGreeting'));
    });

    test('swipe reads swipe context', () {
      final idx = swipeGestureHandlerJs.indexOf('class SwipeGestureHandler');
      final classBody = _extractBlockBody(swipeGestureHandlerJs, idx);
      final hasSwipeContext =
          classBody.contains('swipeId') || classBody.contains('data-swipe-id');
      expect(hasSwipeContext, isTrue);
    });

    test('swipe is disabled while generating', () {
      final idx = swipeGestureHandlerJs.indexOf('class SwipeGestureHandler');
      final classBody = _extractBlockBody(swipeGestureHandlerJs, idx);
      final hasGenerating =
          classBody.contains('isGenerating') ||
          classBody.contains('generating');
      expect(hasGenerating, isTrue);
    });

    test('swipe is disabled during editing', () {
      final idx = swipeGestureHandlerJs.indexOf('class SwipeGestureHandler');
      final classBody = _extractBlockBody(swipeGestureHandlerJs, idx);
      expect(classBody, contains('editing'));
    });

    test('swipe blocks horizontal translation at boundaries', () {
      final idx = swipeGestureHandlerJs.indexOf('class SwipeGestureHandler');
      final classBody = _extractBlockBody(swipeGestureHandlerJs, idx);
      final hasDx =
          classBody.contains('dx') || classBody.contains('translateX');
      expect(hasDx, isTrue);
    });

    test('reset animation uses CSS transition', () {
      final idx = swipeGestureHandlerJs.indexOf('class SwipeGestureHandler');
      final classBody = _extractBlockBody(swipeGestureHandlerJs, idx);
      expect(classBody, contains('transition'));
    });

    test(
      'guided swipe toggles inline panel with textarea and sends onGuidedSwipe',
      () {
        expect(swipeGestureHandlerJs, contains('toggleGuidedSwipe'));
        expect(swipeGestureHandlerJs, contains('guided-swipe-textarea'));
        expect(swipeGestureHandlerJs, contains("'onGuidedSwipe'"));
      },
    );

    test('toggle-guided action delegates to SwipeGestureHandler', () {
      final idx = interactionDispatchJs.indexOf("'toggle-guided':");
      expect(idx, isNot(-1));
      final block = interactionDispatchJs.substring(idx, idx + 200);
      expect(block, contains('_swipeHandler.toggleGuidedSwipe'));
    });
  });

  // ─── Phase 4.2: Message batching ────────────────────────────────────────
  group('Flutter→WebView message dispatch (Phase 4.2 characterization)', () {
    test('bridge has updateMessage method for streaming', () {
      expect(bridgeJs, contains('updateMessage('));
    });

    test('bridge has setMessages batch method', () {
      expect(bridgeJs, contains('setMessages('));
    });

    test('bridge has appendMessages batch method', () {
      expect(bridgeJs, contains('appendMessages('));
    });

    test('bridge has prependMessages batch method', () {
      expect(bridgeJs, contains('prependMessages('));
    });

    test('updateMessage method exists in bridge.js', () {
      expect(bridgeJs, contains('updateMessage(messageJson)'));
    });

    test('no MessageChannel batching exists in current bridge.js', () {
      expect(bridgeJs, isNot(contains('MessageChannel')));
    });

    test('requestAnimationFrame is used for header scroll throttling', () {
      expect(bridgeJs, contains('requestAnimationFrame(updateHeader)'));
    });
  });

  // ─── Phase 4.4: Callback structure ──────────────────────────────────────
  group('WebView callback interface (Phase 4.4 characterization)', () {
    test('all JS→Flutter callback names are sent via _sendToFlutter', () {
      final expectedHandlers = [
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
          bridgeAllJs,
          contains("'$name'"),
          reason:
              'Callback "$name" must be sent via _sendToFlutter in bridge modules',
        );
      }
    });

    test('callbacks use flutter_inappwebview.callHandler', () {
      expect(bridgeJs, contains('flutter_inappwebview.callHandler'));
    });

    test('onMessageContext sends JSON object with id and isUser', () {
      final idx = interactionDispatchJs.indexOf('onMessageContext');
      expect(idx, isNot(-1));
      final end = idx + 300 > interactionDispatchJs.length
          ? interactionDispatchJs.length
          : idx + 300;
      final context = interactionDispatchJs.substring(
        idx > 100 ? idx - 100 : 0,
        end,
      );
      expect(context, contains('id'));
      expect(context, contains('isUser'));
    });

    test('onSwipe sends id and direction', () {
      final idx = swipeGestureHandlerJs.indexOf('onSwipe');
      expect(idx, isNot(-1));
      final context = swipeGestureHandlerJs.substring(idx - 50, idx + 200);
      expect(context, contains('direction'));
    });

    test(
      'image callbacks (retry/find/regen) send instruction and messageId',
      () {
        for (final action in ['onImgRetry', 'onImgFind', 'onImgRegen']) {
          expect(
            interactionDispatchJs,
            contains("'$action'"),
            reason: '$action must be sent via _sendToFlutter in bridge modules',
          );
          final idx = interactionDispatchJs.indexOf("'$action'");
          final end = idx + 200 > interactionDispatchJs.length
              ? interactionDispatchJs.length
              : idx + 200;
          final context = interactionDispatchJs.substring(idx, end);
          expect(context, contains('instr'));
          expect(context, contains('messageId'));
        }
      },
    );

    test('edit callbacks delegate to EditController', () {
      final saveIdx = interactionDispatchJs.indexOf("'edit-save':");
      expect(saveIdx, isNot(-1));
      final saveBlock = interactionDispatchJs.substring(saveIdx, saveIdx + 300);
      expect(saveBlock, contains('_editController.handleSave'));

      final cancelIdx = interactionDispatchJs.indexOf("'edit-cancel':");
      expect(cancelIdx, isNot(-1));
      final cancelBlock = interactionDispatchJs.substring(
        cancelIdx,
        cancelIdx + 200,
      );
      expect(cancelBlock, contains('_editController.handleCancel'));

      expect(editControllerJs, contains('onEditSave'));
      expect(editControllerJs, contains('onEditCancel'));
    });
  });

  // ─── Phase 4.2: MessageUpdateBatcher ──────────────────────────────────────
  group('MessageUpdateBatcher (Phase 4.2 characterization)', () {
    test('MessageUpdateBatcher class exists', () {
      expect(messageUpdateBatcherJs, contains('class MessageUpdateBatcher'));
    });

    test('has enqueue method', () {
      expect(messageUpdateBatcherJs, contains('enqueue(id, updateFn)'));
    });

    test('has flush method', () {
      final idx = messageUpdateBatcherJs.indexOf('class MessageUpdateBatcher');
      final classBody = messageUpdateBatcherJs.substring(idx, idx + 500);
      expect(classBody, contains('flush()'));
    });

    test('has hasPending method', () {
      final idx = messageUpdateBatcherJs.indexOf('class MessageUpdateBatcher');
      final classBody = _extractBlockBody(messageUpdateBatcherJs, idx);
      expect(classBody, contains('hasPending()'));
    });

    test('uses requestAnimationFrame for batching', () {
      final idx = messageUpdateBatcherJs.indexOf('class MessageUpdateBatcher');
      final classBody = messageUpdateBatcherJs.substring(idx, idx + 500);
      expect(classBody, contains('requestAnimationFrame'));
    });

    test('Bridge creates _updateBatcher', () {
      expect(bridgeJs, contains('new MessageUpdateBatcher()'));
    });

    test('updateMessage delegates to _updateBatcher.enqueue', () {
      final idx = bridgeJs.indexOf('updateMessage(messageJson)');
      final methodBody = bridgeJs.substring(idx, idx + 200);
      expect(methodBody, contains('_updateBatcher.enqueue'));
    });

    test('_executeUpdateMessage contains update logic', () {
      expect(bridgeJs, contains('_executeUpdateMessage(msg)'));
      final idx = bridgeJs.indexOf('_executeUpdateMessage(msg) {');
      final methodBody = bridgeJs.substring(idx, idx + 1200);
      expect(methodBody, contains('updateMessageContent'));
    });

    test('flush() called before setMessages', () {
      final idx = bridgeJs.indexOf('setMessages(messagesJson');
      final methodBody = bridgeJs.substring(idx, idx + 100);
      expect(methodBody, contains('this.flush()'));
    });

    test('flush() called before appendMessage', () {
      final idx = bridgeJs.indexOf('appendMessage(messageJson)');
      final methodBody = bridgeJs.substring(idx, idx + 100);
      expect(methodBody, contains('this.flush()'));
    });

    test('flush() called before appendMessages', () {
      final idx = bridgeJs.indexOf('appendMessages(messagesJson)');
      final methodBody = bridgeJs.substring(idx, idx + 100);
      expect(methodBody, contains('this.flush()'));
    });

    test('flush() called before prependMessages', () {
      final idx = bridgeJs.indexOf('prependMessages(messagesJson)');
      final methodBody = bridgeJs.substring(idx, idx + 100);
      expect(methodBody, contains('this.flush()'));
    });

    test('flush() called before removeMessage', () {
      final idx = bridgeJs.indexOf('removeMessage(messageId)');
      final methodBody = bridgeJs.substring(idx, idx + 100);
      expect(methodBody, contains('this.flush()'));
    });

    test('flush() called before clearAll', () {
      final idx = bridgeJs.indexOf('clearAll()');
      final methodBody = bridgeJs.substring(idx, idx + 100);
      expect(methodBody, contains('this.flush()'));
    });

    test('bridge has public flush method', () {
      expect(bridgeJs, contains('flush() { this._updateBatcher.flush(); }'));
    });
  });
}
