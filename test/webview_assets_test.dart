// Tests that guard WebView JS/CSS assets against regressions introduced by
// upstream UI rewrites (e.g. hydall/Glaze PRs).
//
// These are intentionally static-analysis tests — they read the source files
// as strings and assert that critical CSS rules / JS patterns are present.
// This catches the class of bug where a CSS property is silently removed
// during a large refactor.

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/extensions/services/js_bridge_service.dart';

String _asset(String name) =>
    File('assets/chat_webview/$name').readAsStringSync();

String _bridgeAsset(String name) =>
    File('assets/chat_webview/bridge/$name').readAsStringSync();

String _rendererAsset(String name) =>
    File('assets/chat_webview/renderer/$name').readAsStringSync();

String _formatterAsset(String name) =>
    File('assets/chat_webview/formatter/$name').readAsStringSync();

void main() {
  late String rendererJs;
  late String rendererIndexJs;
  late String rendererMessageJs;
  late String formatterIndexJs;
  late String formatterFormatterJs;
  late String formatterTextFormatJs;
  late String bridgeIndexJs;
  late String bridgeControllerJs;
  late String virtualScrollJs;
  late String editControllerJs;
  late String genTimerJs;
  late String interactionDispatchJs;
  late String panelHostJs;
  late String htmlSanitizerJs;
  late String cssDiagnosticsJs;
  late String cssSanitizerJs;
  late String selectionManagerJs;
  late String swipeHandlerJs;
  late String glazeSdkJs;
  late String indexHtml;
  late String headlessHtml;
  late String stylessCss;

  setUpAll(() {
    rendererIndexJs = _rendererAsset('index.js');
    rendererMessageJs = _rendererAsset('message_renderer.js');
    formatterIndexJs = _formatterAsset('index.js');
    formatterFormatterJs = _formatterAsset('formatter.js');
    formatterTextFormatJs = _formatterAsset('text_format.js');
    rendererJs = [
      _rendererAsset('shadow_style.js'),
      _rendererAsset('markdown.js'),
      _rendererAsset('image_embed.js'),
      _rendererAsset('message_template.js'),
      rendererMessageJs,
    ].join('\n');
    bridgeIndexJs = _bridgeAsset('index.js');
    bridgeControllerJs = _bridgeAsset('chat_bridge_controller.js');
    virtualScrollJs = _asset('useVirtualScroll.js');
    editControllerJs = _bridgeAsset('edit_controller.js');
    genTimerJs = _bridgeAsset('gen_timer.js');
    interactionDispatchJs = _bridgeAsset('interaction_dispatch.js');
    panelHostJs = _bridgeAsset('panel_host.js');
    htmlSanitizerJs = _bridgeAsset('html_sanitizer.js');
    cssDiagnosticsJs = _rendererAsset('css_diagnostics.js');
    cssSanitizerJs = _bridgeAsset('css_sanitizer.js');
    selectionManagerJs = _bridgeAsset('selection_manager.js');
    swipeHandlerJs = _bridgeAsset('swipe_gesture_handler.js');
    glazeSdkJs = _asset('glaze_sdk.js');
    indexHtml = _asset('index.html');
    headlessHtml = _asset('headless.html');
    stylessCss = _asset('styles.css').replaceAll('\r\n', '\n');
  });

  group('message copy', () {
    test('message copy preserves source markdown', () {
      final idx = bridgeControllerJs.indexOf('_extractText(section)');
      final body = bridgeControllerJs.substring(idx, idx + 500);
      expect(body, contains("return section.dataset.rawText || '';"));
      expect(body, isNot(contains('root.innerText')));
    });

    test('selection copy serializes cloned rendered ranges', () {
      expect(
        selectionManagerJs,
        contains('selection.getRangeAt(i).cloneContents()'),
      );
      expect(selectionManagerJs, contains('content.innerText.trim()'));
    });
  });

  group('memory badge and virtual-scroll settling', () {
    test('game-time metadata can be added, updated, and removed live', () {
      final body = _extractBlockBody(
        rendererMessageJs,
        rendererMessageJs.indexOf('updateMessageMeta(sectionEl, msg)'),
      );
      expect(body, contains("querySelector('.msg-game-time')"));
      expect(body, contains(r'clock.textContent = `⏱ ${msg.gameTime}`'));
      expect(body, contains('clock?.remove()'));
      expect(body, contains("hasOwnProperty.call(msg, 'gameTime')"));
      expect(body, contains("hasOwnProperty.call(msg, 'gameTime')"));
    });

    test('late memory state patches metadata without a full render', () {
      final body = _extractBlockBody(
        bridgeControllerJs,
        bridgeControllerJs.indexOf('patchMemoryStatuses(statusesJson)'),
      );
      expect(body, contains('this.virtualList.itemMap?.get(id)'));
      expect(body, contains('this.renderer.updateMessageMeta(section'));
      expect(body, isNot(contains('renderMessage(')));
      expect(
        rendererMessageJs,
        contains("querySelector('.msg-memory-badge')?.remove()"),
      );
    });

    test('late height changes re-pin only a still-pinned viewport', () {
      expect(
        virtualScrollJs,
        contains('this.resizeObserver = new ResizeObserver'),
      );
      expect(
        virtualScrollJs,
        contains('const wasPinned = this._pinnedToBottom'),
      );
      expect(
        virtualScrollJs,
        contains(
          'if (this.mounted && this._pinnedToBottom) this.smartScroll()',
        ),
      );
      expect(virtualScrollJs, contains('if (!this._pinnedToBottom) return'));
    });

    test('the streaming follow detaches on any upward scroll', () {
      final body = _extractBlockBody(
        virtualScrollJs,
        virtualScrollJs.indexOf('_onContainerScroll() {'),
      );
      expect(
        body,
        contains('const movedUp = scrollTop < this._lastScrollTop - 1'),
        reason:
            'The pin has to be directional: with a plain isNearBottom(100) band '
            'the next streamed chunk re-pinned the list before the user could '
            'scroll out of those 100px, so scrolling up during generation was '
            'impossible.',
      );
      expect(
        body,
        contains('this.isNearBottom(BOTTOM_PIN_EPSILON)'),
        reason:
            'The follow resumes only when the list rests at the very end of the '
            'container, not anywhere inside a wide band above it.',
      );
      expect(
        body,
        isNot(contains('this._pinnedToBottom = this.isNearBottom(100)')),
      );
    });

    test('scroll-to-bottom resolves after its correction pass', () {
      final body = _extractBlockBody(
        virtualScrollJs,
        virtualScrollJs.indexOf("scrollToBottom(behavior = 'auto')"),
      );
      expect(body, contains('return new Promise'));
      expect(
        body,
        contains('this.container.scrollTop = this.container.scrollHeight'),
      );
      expect(body, contains('resolve()'));
    });
  });

  group('window.glaze SDK', () {
    test('index.html loads glaze_sdk before bridge/index.js', () {
      final sdkIdx = indexHtml.indexOf('glaze_sdk.js');
      final bridgeIdx = indexHtml.indexOf('bridge/index.js');
      expect(sdkIdx, isNonNegative);
      expect(bridgeIdx, isNonNegative);
      expect(sdkIdx < bridgeIdx, isTrue);
      expect(indexHtml, contains('type="module"'));
    });

    test('SDK exposes expected window.glaze methods', () {
      for (final method in JsBridgeMethodRegistry.methods.map((e) => e.name)) {
        expect(glazeSdkJs, contains('$method('));
      }
    });

    test(
      'sandboxed runner relays glaze requests and ignores relay messages as final output',
      () {
        expect(bridgeControllerJs, contains("data.type !== 'glaze:request'"));
        expect(bridgeControllerJs, contains("type: 'glaze:response'"));
        expect(
          bridgeControllerJs,
          contains('if (e.data && e.data.type) return;'),
        );
      },
    );

    test(
      'panel relay preserves authoritative context and bridge error codes',
      () {
        expect(panelHostJs, contains('panelId: panel.panelId'));
        expect(panelHostJs, contains('messageId: panel.messageId'));
        expect(panelHostJs, contains('code: error && error.code'));
        expect(
          panelHostJs,
          contains('_buildSrcdoc(html, options, panelId, messageId)'),
        );
        expect(panelHostJs, contains("sandbox = 'allow-scripts'"));
        expect(panelHostJs, isNot(contains('allow-same-origin')));
      },
    );
  });

  group('message script execution policy', () {
    test('renderer defaults message scripts to disabled', () {
      expect(rendererMessageJs, contains('this.allowMessageScripts = false'));
      expect(rendererJs, contains('allowMessageScripts = false'));
    });

    test('disabled path removes scripts before returning', () {
      final marker = 'export function executeInlineScripts';
      final body = _extractBlockBody(rendererJs, rendererJs.indexOf(marker));
      expect(body, contains('if (!allowMessageScripts)'));
      expect(body, contains('script.remove()'));
      expect(
        body.indexOf('script.remove()'),
        lessThan(body.indexOf('new Function(src)()')),
      );
    });

    test('every render sanitizes active HTML before innerHTML insertion', () {
      expect(
        rendererJs,
        contains(
          "import { sanitizeMessageHtml } from '../bridge/html_sanitizer.js'",
        ),
      );
      final writeBlock = _extractWriteShadowContent(rendererJs);
      final sanitize = writeBlock.indexOf('sanitizeMessageHtml(formatted, {');
      final insertion = writeBlock.indexOf('root.innerHTML =');
      expect(sanitize, isNonNegative);
      expect(insertion, isNonNegative);
      expect(writeBlock, contains('allowScripts: allowMessageScripts'));
      // No raw-insertion branch: enabling message scripts must not hand the
      // message a different HTML/CSS policy, only script execution.
      expect(writeBlock, isNot(contains('? formatted')));
    });

    test('search re-render sanitizes active HTML before insertion', () {
      expect(
        rendererMessageJs,
        contains(
          "import { sanitizeMessageHtml } from '../bridge/html_sanitizer.js'",
        ),
      );
      final searchBlock = _extractBlockBody(
        rendererMessageJs,
        rendererMessageJs.indexOf('setSearch(query, activeIndex = -1'),
      );
      final sanitize = searchBlock.indexOf(
        'sanitizeMessageHtml(highlighted, {',
      );
      final insertion = searchBlock.indexOf('root.innerHTML =');
      expect(sanitize, isNonNegative);
      expect(insertion, isNonNegative);
      expect(searchBlock, contains('allowScripts: this.allowMessageScripts'));
      expect(searchBlock, isNot(contains('? highlighted')));
    });

    test('search refresh pass can re-number without scrolling', () {
      expect(
        rendererMessageJs,
        contains('setSearch(query, activeIndex = -1, scroll = true'),
      );
      final searchBlock = _extractBlockBody(
        rendererMessageJs,
        rendererMessageJs.indexOf('setSearch(query, activeIndex = -1'),
      );
      expect(searchBlock, contains('if (!scroll) return;'));
      // The clamp retry must keep the caller's scroll choice.
      expect(searchBlock, contains('this.setSearch(query, total - 1, scroll,'));
      expect(
        bridgeControllerJs,
        contains('setSearch(query, activeIndex, scroll = true)'),
      );
    });

    test('leaving edit mode re-numbers the open search', () {
      expect(editControllerJs, contains('if (renderer.searchQuery) {'));
      expect(
        editControllerJs,
        contains(
          'renderer.setSearch(renderer.searchQuery, '
          'renderer.activeSearchIndex, false);',
        ),
      );
    });

    test('app bridge changes only the message renderer policy', () {
      expect(bridgeControllerJs, contains('setAllowMessageScripts(enabled)'));
      expect(
        bridgeControllerJs,
        contains('this.renderer.allowMessageScripts = enabled === true'),
      );
      expect(headlessHtml, contains('runSandboxedScript'));
    });

    test('blocked scripts are detected before the sanitizer strips them', () {
      final writeBlock = _extractWriteShadowContent(rendererJs);
      final detect = writeBlock.indexOf('SCRIPT_TAG.test(formatted)');
      final sanitize = writeBlock.indexOf('sanitizeMessageHtml(formatted, {');
      expect(detect, isNonNegative);
      expect(detect, lessThan(sanitize));
      expect(writeBlock, contains('!allowMessageScripts'));
      expect(rendererJs, contains('notifyMessageScriptBlocked()'));
      expect(
        rendererJs,
        contains('window.bridge?.notifyMessageScriptBlocked?.()'),
      );
    });

    test('bridge reports a blocked script to Flutter once per load', () {
      expect(bridgeControllerJs, contains('notifyMessageScriptBlocked()'));
      expect(
        bridgeControllerJs,
        contains('this._messageScriptBlockedNotified = false'),
      );
      final body = _extractBlockBody(
        bridgeControllerJs,
        bridgeControllerJs.indexOf('notifyMessageScriptBlocked() {'),
      );
      expect(body, contains('if (this._messageScriptBlockedNotified) return'));
      expect(body, contains("_sendToFlutter('onMessageScriptBlocked', [])"));
    });

    test('flipping the policy re-renders the messages already on screen', () {
      final body = _extractBlockBody(
        bridgeControllerJs,
        bridgeControllerJs.indexOf('setAllowMessageScripts(enabled)'),
      );
      expect(body, contains('this.renderer.rerenderMessageBodies()'));
      expect(rendererMessageJs, contains('rerenderMessageBodies()'));
    });
  });

  group('ordinary ExtBlocks HTML sanitizer', () {
    test('controller sanitizes every ExtBlock innerHTML insertion', () {
      expect(
        bridgeControllerJs,
        contains("import { sanitizeExtBlockHtml } from './html_sanitizer.js'"),
      );
      expect(
        RegExp(r'\.innerHTML\s*=(?!\s*sanitizeExtBlockHtml)').allMatches(
          _extractBlockBody(
            bridgeControllerJs,
            bridgeControllerJs.indexOf('_fillExtBlockBody(body, block) {'),
          ),
        ),
        isEmpty,
      );
    });

    test('sanitizer blocks active content and dangerous attributes', () {
      for (final token in [
        "'script'",
        "'iframe'",
        "'object'",
        "'embed'",
        "'form'",
        "'math'",
        "'foreignobject'",
        "'animate'",
        "'use'",
        "'feimage'",
        "'meta'",
        "'link'",
        "'base'",
        "name.startsWith('on')",
        "name === 'srcdoc'",
        "compact.startsWith('javascript:')",
        'SAFE_IMAGE_DATA_URL',
        'isSafeDataUrl',
        'sanitizeStyleDeclaration',
      ]) {
        expect(htmlSanitizerJs, contains(token));
      }
    });

    test('generated image result markup remains supported', () {
      expect(bridgeControllerJs, contains('_renderExtBlockImageHtml'));
      expect(bridgeControllerJs, contains('data-action="image-click"'));
      expect(bridgeControllerJs, contains('data-action="img-download"'));
      expect(htmlSanitizerJs, contains('SAFE_IMAGE_DATA_URL'));
    });
  });

  group('message CSS diagnostics', () {
    test('a render reports broken message CSS after the body is in place', () {
      expect(
        rendererJs,
        contains("import { reportCssErrors } from './css_diagnostics.js'"),
      );
      final writeBlock = _extractWriteShadowContent(rendererJs);
      final insertion = writeBlock.indexOf('root.innerHTML =');
      final report = writeBlock.indexOf('reportCssErrors(root)');
      expect(insertion, isNonNegative);
      expect(report, greaterThan(insertion));
      // A reply still arriving is half a stylesheet: every unclosed brace in it
      // is on its way to being closed, so only a settled message is reported.
      expect(
        writeBlock,
        contains(
          'if (!isTyping && !window.bridge?.isGenerating) '
          'reportCssErrors(root);',
        ),
      );
    });

    test('the search re-render puts the report back', () {
      final searchBlock = _extractBlockBody(
        rendererMessageJs,
        rendererMessageJs.indexOf('setSearch(query, activeIndex = -1'),
      );
      expect(searchBlock, contains('reportCssErrors(root)'));
    });

    test('the report reads the stylesheet and never rewrites it', () {
      expect(cssDiagnosticsJs, contains('inspectCss(style.textContent)'));
      // Reading only: no assignment back into a <style>, and no innerHTML
      // anywhere — the report quotes selectors the message wrote.
      expect(cssDiagnosticsJs, isNot(contains('style.textContent =')));
      expect(cssDiagnosticsJs, isNot(contains('innerHTML')));
      expect(cssDiagnosticsJs, contains('item.textContent = problem;'));
      expect(
        cssSanitizerJs,
        contains('export function withParsedSheet(css, read)'),
      );
    });

    test('the scan names the failures a generated card actually makes', () {
      for (final token in [
        'unclosed',
        'unexpected',
        'unterminated comment',
        'unterminated string',
        'rule ignored',
        'const MAX_REPORTED = 5',
      ]) {
        expect(cssDiagnosticsJs, contains(token));
      }
      // Memoized like the CSS parser cache: a streaming reply re-renders the
      // same <style> on every chunk.
      expect(
        cssDiagnosticsJs,
        contains('cache.delete(cache.keys().next().value)'),
      );
    });

    test('the report has shadow-root styling of its own', () {
      for (final selector in [
        '.glaze-message .glaze-css-error {',
        '.glaze-message .glaze-css-error-head {',
        '.glaze-message .glaze-css-error-item',
      ]) {
        expect(rendererJs, contains(selector));
      }
    });
  });

  group('CSS survives with message scripts disabled', () {
    test('message CSS reaches the shadow root untouched', () {
      // No CSS policy on the message path at all: `<style>` blocks and
      // `style="…"` attributes are inserted verbatim whether or not message
      // scripts are enabled.
      final body = _extractBlockBody(
        htmlSanitizerJs,
        htmlSanitizerJs.indexOf('function stripMessageCode('),
      );
      expect(body, isNot(contains('style')));
    });

    test('ExtBlock sanitizer keeps <style> and delegates CSS to its policy', () {
      expect(
        htmlSanitizerJs,
        contains(
          "import { sanitizeCssText, sanitizeStyleDeclaration } "
          "from './css_sanitizer.js'",
        ),
      );
      final blocked = _extractBlockBody(
        htmlSanitizerJs,
        htmlSanitizerJs.indexOf('const BLOCKED_ELEMENTS'),
        open: '[',
        close: ']',
      );
      expect(blocked, contains("'script'"));
      expect(blocked, isNot(contains("'style'")));
      expect(htmlSanitizerJs, contains('sanitizeCssText(element.textContent'));
      // Message HTML is written into a per-message shadow root (already
      // scoped); ExtBlock HTML lands in the light DOM and must stay pinned to
      // the block body.
      expect(
        htmlSanitizerJs,
        contains("const EXT_BLOCK_CSS_SCOPE = '.ext-block-content'"),
      );
      expect(
        htmlSanitizerJs,
        contains('return sanitizeHtml(html, EXT_BLOCK_CSS_SCOPE)'),
      );
    });

    test('message HTML is filtered for code only, never for markup', () {
      expect(
        htmlSanitizerJs,
        contains('sanitizeMessageHtml(html, { allowScripts = false } = {})'),
      );
      // Scripts on: the message HTML is inserted exactly as written.
      expect(
        htmlSanitizerJs,
        contains("if (allowScripts) return String(html == null ? '' : html);"),
      );
      expect(htmlSanitizerJs, contains('return stripMessageCode(html);'));
      // Scripts off: only the things that run code are removed. The strict
      // element / CSS policy is the ExtBlock path's, and must not be reached
      // from here — a card renders the same with execution on and off.
      final body = _extractBlockBody(
        htmlSanitizerJs,
        htmlSanitizerJs.indexOf('function stripMessageCode('),
      );
      expect(
        htmlSanitizerJs,
        contains(
          "const MESSAGE_CODE_ELEMENTS = new Set("
          "['script', 'iframe', 'object', 'embed']);",
        ),
      );
      expect(body, contains('MESSAGE_CODE_ELEMENTS.has('));
      expect(body, contains("name.startsWith('on') || name === 'srcdoc'"));
      expect(body, contains('isMessageCodeUrl(compact)'));
      for (final forbidden in [
        'BLOCKED_ELEMENTS',
        'sanitizeStyleElement',
        'sanitizeStyleAttribute',
        'sanitizeCssText',
        'sanitizeStyleDeclaration',
      ]) {
        expect(
          body,
          isNot(contains(forbidden)),
          reason: 'message HTML/CSS must reach the shadow root untouched',
        );
      }
    });

    test('a message may not run code while execution is off', () {
      final body = _extractBlockBody(
        htmlSanitizerJs,
        htmlSanitizerJs.indexOf('function isMessageCodeUrl('),
      );
      expect(body, contains("compact.startsWith('javascript:')"));
      expect(body, contains("compact.startsWith('vbscript:')"));
      // A `data:` document runs script on navigation; a `data:image/…` is a
      // picture and stays, like the rest of the markup.
      expect(body, contains("compact.startsWith('data:')"));
      expect(body, contains("!compact.startsWith('data:image/')"));
    });

    test('inline styles are filtered by policy, not an allowlist', () {
      expect(cssSanitizerJs, isNot(contains('EXT_BLOCK_STYLE_PROPERTIES')));
      final body = _extractBlockBody(
        htmlSanitizerJs,
        htmlSanitizerJs.indexOf('function sanitizeStyleAttribute'),
      );
      expect(body, contains('sanitizeStyleDeclaration(element.style)'));
    });

    test('CSS policy parses without applying or fetching anything', () {
      // A constructed stylesheet is never attached to a document and drops
      // @import by spec; the inert-document fallback has no browsing context.
      expect(cssSanitizerJs, contains('new CSSStyleSheet()'));
      expect(cssSanitizerJs, contains('sheet.replaceSync(css)'));
      expect(
        cssSanitizerJs,
        contains("document.implementation.createHTMLDocument('glaze-css')"),
      );
      expect(cssSanitizerJs, contains('holder.remove()'));
    });

    test('CSS policy rejects network, script and overlay primitives', () {
      final allowed = _extractBlockBody(
        cssSanitizerJs,
        cssSanitizerJs.indexOf('function isAllowedDeclaration'),
      );
      expect(allowed, contains('BLOCKED_PROPERTIES.has(name)'));
      expect(allowed, contains('isUnsafeValue(text)'));
      expect(allowed, contains("name === 'position'"));
      expect(allowed, contains(r'/\bfixed\b/i.test(text)'));
      expect(allowed, contains("name.startsWith('--')"));
      for (final token in [
        'url',
        'image-set',
        'expression',
        'javascript',
        'vbscript',
      ]) {
        expect(cssSanitizerJs, contains(token));
      }
      for (final property in ['behavior', '-moz-binding']) {
        expect(
          _extractBlockBody(
            cssSanitizerJs,
            cssSanitizerJs.indexOf('const BLOCKED_PROPERTIES'),
            open: '[',
            close: ']',
          ),
          contains("'$property'"),
        );
      }
    });

    test('only style, keyframe and grouping rules are re-emitted', () {
      final body = _extractBlockBody(
        cssSanitizerJs,
        cssSanitizerJs.indexOf('function serializeRule('),
      );
      expect(body, contains("isInstanceOf(rule, 'CSSStyleRule')"));
      expect(body, contains("isInstanceOf(rule, 'CSSKeyframesRule')"));
      expect(body, contains("isInstanceOf(rule, 'CSSGroupingRule')"));
      // Everything else (@import, @font-face, @page, @namespace) is dropped.
      expect(
        body.replaceAll('\r\n', '\n').trimRight(),
        endsWith("return '';\n}"),
      );
    });

    test('ExtBlock selectors are scoped, selector lists stay intact', () {
      final body = _extractBlockBody(
        cssSanitizerJs,
        cssSanitizerJs.indexOf('function scopeSelector'),
      );
      expect(body, contains(r'`${scope} ${selector}`'));
      expect(cssSanitizerJs, contains('function splitSelectorList'));
    });
  });

  group('edit opens the stored text, not the rendering', () {
    test('section carries sourceText when Dart sends one', () {
      expect(
        rendererMessageJs,
        contains('section.dataset.sourceText = messageData.sourceText'),
      );
    });

    test('startEdit prefers sourceText over rawText', () {
      expect(
        editControllerJs,
        contains('section.dataset.sourceText ?? section.dataset.rawText'),
      );
    });

    test('an update without sourceText clears a stale one', () {
      expect(bridgeControllerJs, contains('delete section.dataset.sourceText'));
    });
  });

  group('bridge ES module layout', () {
    test('module entrypoint exports and bootstraps Bridge', () {
      expect(
        bridgeIndexJs,
        contains("import { Bridge } from './chat_bridge_controller.js'"),
      );
      expect(
        bridgeIndexJs,
        contains("import { Renderer } from '../renderer/index.js'"),
      );
      expect(
        bridgeIndexJs,
        contains("import { Formatter } from '../formatter/index.js'"),
      );
      expect(bridgeIndexJs, contains('window.Bridge = Bridge'));
      expect(
        bridgeIndexJs,
        contains('window.bridge = new Bridge(renderer, virtualList)'),
      );
    });

    test('controller imports extracted modules', () {
      for (final module in [
        'gen_timer.js',
        'message_update_batcher.js',
        'selection_manager.js',
        'edit_controller.js',
        'swipe_gesture_handler.js',
        'interaction_dispatch.js',
        'panel_host.js',
      ]) {
        expect(bridgeControllerJs, contains("'./$module'"));
      }
    });

    test('legacy fallback snapshot is retained outside active entrypoint', () {
      final legacyJs = _asset('bridge.legacy.js');
      expect(legacyJs, contains('class Bridge'));
      expect(_asset('bridge.js'), contains('bridge.legacy.js'));
    });

    test('identity refresh can override legacy default user name', () {
      expect(
        bridgeControllerJs,
        contains("const storedPersonaName = stored === 'You' ? '' : stored"),
      );
      expect(
        _asset('bridge.legacy.js'),
        contains("const storedPersonaName = stored === 'You' ? '' : stored"),
      );
    });
  });

  group('renderer ES module layout', () {
    test('index.html loads renderer module before bridge module', () {
      final rendererIdx = indexHtml.indexOf('renderer/index.js');
      final bridgeIdx = indexHtml.indexOf('bridge/index.js');
      expect(rendererIdx, isNonNegative);
      expect(bridgeIdx, isNonNegative);
      expect(rendererIdx < bridgeIdx, isTrue);
      expect(indexHtml, contains('type="module" src="renderer/index.js"'));
    });

    test('module entrypoint exports and exposes Renderer', () {
      expect(
        rendererIndexJs,
        contains("import { Renderer } from './message_renderer.js'"),
      );
      expect(rendererIndexJs, contains('window.Renderer = Renderer'));
    });

    test('message renderer imports extracted modules', () {
      for (final module in [
        'icon_library.js',
        'image_embed.js',
        'markdown.js',
        'message_template.js',
        'shadow_style.js',
      ]) {
        expect(rendererMessageJs, contains("'./$module'"));
      }
    });

    test('legacy renderer shim points at active module entrypoint', () {
      expect(_asset('renderer.js'), contains('renderer/index.js'));
    });
  });

  group('formatter ES module layout', () {
    test('index.html loads formatter module before renderer module', () {
      final formatterIdx = indexHtml.indexOf('formatter/index.js');
      final rendererIdx = indexHtml.indexOf('renderer/index.js');
      expect(formatterIdx, isNonNegative);
      expect(rendererIdx, isNonNegative);
      expect(formatterIdx < rendererIdx, isTrue);
      expect(indexHtml, contains('type="module" src="formatter/index.js"'));
    });

    test('module entrypoint exports and exposes Formatter', () {
      expect(
        formatterIndexJs,
        contains("import { Formatter } from './formatter.js'"),
      );
      expect(formatterIndexJs, contains('window.Formatter = Formatter'));
    });

    test('formatter imports extracted text formatting modules', () {
      expect(formatterFormatterJs, contains("'./macros.js'"));
      expect(formatterFormatterJs, contains("'./text_format.js'"));
      expect(formatterFormatterJs, contains('renderStyledSegment('));
    });

    test('legacy formatter shim points at active module entrypoint', () {
      expect(_asset('formatter.js'), contains('formatter/index.js'));
    });

    test('inline markdown does not keep a generated paragraph wrapper', () {
      expect(
        formatterTextFormatJs,
        contains(r'const paragraph = rich.match(/^\s*<p>([\s\S]*)<\/p>\s*$/i)'),
      );
      expect(
        formatterTextFormatJs,
        contains(r'!/<\/?p(?:\s|>)/i.test(paragraph[1])'),
        reason: 'only a single outer paragraph may be unwrapped',
      );
      expect(formatterTextFormatJs, contains('return paragraph[1]'));
    });

    test('unmatched emphasis markers cannot consume a later line', () {
      expect(
        formatterFormatterJs,
        contains(r'(?<!\*)\*(?=[^*\n]*[^ \t*\n])[^*\n]+?\*(?!\*)'),
      );
      expect(
        formatterFormatterJs,
        contains(r'html = html.replace(/\*([^*\n]+?)\*/g'),
      );
    });

    test('orphan emphasis markers cannot consume the next action segment', () {
      expect(
        formatterFormatterJs,
        contains(
          "html = html.replace(/\\*([ \\t]+)(?=\\x01S_\\d+\\x01)/g, '\$1');",
        ),
      );
    });

    test('nested guillemets cannot consume styled-segment placeholders', () {
      expect(
        formatterFormatterJs,
        contains(r'(«)([^»\x01]*?(?:«[^»\x01]*?»[^»\x01]*?)*?)(»)'),
        reason:
            'a malformed outer quote must not cross a styled segment while '
            'searching for its closing guillemet',
      );
    });
  });

  // ─── markdown image options button ────────────────────────────────────────
  group('generated image (formatter/formatter.js, renderer/markdown.js)', () {
    test('the result image loads eagerly', () {
      // A lazy image at the bottom edge of the WebView can be evaluated while
      // the row is still off-screen and never fetched, leaving the picture the
      // user waited for as a broken tag.
      final imgIdx = formatterFormatterJs.indexOf('class="imggen-result"');
      expect(imgIdx, isNot(-1));
      final chunk = formatterFormatterJs.substring(
        formatterFormatterJs.lastIndexOf('<img', imgIdx),
        formatterFormatterJs.indexOf('>', imgIdx),
      );
      expect(chunk, contains('loading="eager"'));
      expect(chunk, isNot(contains('loading="lazy"')));
    });

    test('the block switcher renders only for more than one image', () {
      // The count is `variants.length > 1` on both the switcher and the data
      // attributes, so a single-image block keeps its historical markup.
      expect(formatterFormatterJs, contains('imggen-variants'));
      expect(
        formatterFormatterJs,
        contains("data-action=\"img-variant-prev\""),
      );
      expect(
        formatterFormatterJs,
        contains("data-action=\"img-variant-next\""),
      );
      expect(
        RegExp(r'variants\.length > 1').allMatches(formatterFormatterJs).length,
        greaterThanOrEqualTo(3),
      );
      expect(formatterFormatterJs, contains('data-variants='));
      expect(formatterFormatterJs, contains('data-variant-index='));
    });

    test('the payload parser mirrors the Dart codec', () {
      expect(
        formatterFormatterJs,
        contains('export function parseImageResultPayload('),
      );
      expect(formatterFormatterJs, contains("IMG_VARIANT_SEPARATOR = ';;'"));
      expect(formatterFormatterJs, contains("IMG_VARIANT_ACTIVE_MARKER = '*'"));
    });

    test('the stored <img data-iig-…> block renders as an image block', () {
      // INV-IG9: the form every finished block is written in. It is pulled out
      // with the other image tags in step 5c, so it gets the options button,
      // the switcher and its data-img-index — not the bare <img> that step 6
      // would leave.
      expect(
        formatterFormatterJs,
        contains('export function parseImageResultElement('),
      );
      expect(formatterFormatterJs, contains('IIG_ELEMENT_REGEX'));
      expect(formatterFormatterJs, contains("data-iig-variants"));
      expect(formatterFormatterJs, contains("data-iig-index"));
      expect(
        RegExp(
          r'html = html\.replace\(IIG_ELEMENT_REGEX[\s\S]*?'
          r"imgBlocks\.push\(\{\s*type: 'result'",
        ).hasMatch(formatterFormatterJs),
        isTrue,
      );
      // An element with no image yet is a *pending* block and must fall
      // through to the [IMG:GEN] handling instead.
      expect(
        formatterFormatterJs,
        contains("if (!src || src.startsWith('[IMG:GEN')) return null;"),
      );
    });

    test('an ext block renders the stored element with its own controls', () {
      expect(
        bridgeControllerJs,
        contains('_extBlockLegacyImageTokens(block.content)'),
      );
      expect(
        bridgeControllerJs,
        contains(
          "import { parseImageResultElement } from "
          "'../formatter/formatter.js';",
        ),
      );
    });

    test('paging a block swaps the picture in the page', () {
      expect(interactionDispatchJs, contains('_stepImageVariant('));
      expect(interactionDispatchJs, contains("'img-variant-prev'"));
      expect(interactionDispatchJs, contains("'img-variant-next'"));
      // The lightbox and the download button read data-src, so it moves too.
      expect(interactionDispatchJs, contains('img.dataset.src = src'));
      expect(interactionDispatchJs, contains("_sendToFlutter('onImgVariant'"));
    });

    test('the switcher is small and see-through', () {
      final css = rendererJs;
      final start = css.indexOf('.imggen-variants {');
      expect(start, isNot(-1));
      final rule = css.substring(start, css.indexOf('}', start));
      expect(rule, contains('position: absolute'));
      expect(rule, contains('height: 18px'));
      expect(rule, contains('opacity: 0.45'));
      expect(rule, contains('rgba(0, 0, 0, 0.38)'));
    });

    test('a failed generated image re-requests itself', () {
      expect(rendererJs, contains('export function retryFailedLocalImages('));
      expect(rendererJs, contains('retryFailedLocalImages(root)'));
      expect(rendererJs, contains("querySelectorAll('img.imggen-result')"));
      // A fresh query string keeps a cached failure from being replayed.
      expect(rendererJs, contains('__glaze_retry='));
    });
  });

  group('markdown image card (formatter/formatter.js)', () {
    test('the card is stashed whole, not emitted as raw HTML mid-pipeline', () {
      // Raw HTML emitted before the tag extraction gets torn apart: <img>,
      // <svg> and <path> are *block* tags, so the paragraph step isolates each
      // of them and the wrapper <span>, the image and the options <button> end
      // up in three different <p> elements. The button then loses its
      // positioned wrapper and its `position: absolute` resolves against the
      // message container — the 3-dot menu jumps to the top of the message.
      expect(formatterFormatterJs, contains('const mdImages = []'));
      expect(formatterFormatterJs, contains('mdImages.push('));

      final pushIdx = formatterFormatterJs.indexOf('mdImages.push(');
      final tagExtractIdx = formatterFormatterJs.indexOf(
        '// 6. Extract HTML Tags',
      );
      expect(tagExtractIdx, isNot(-1));
      expect(
        pushIdx < tagExtractIdx,
        isTrue,
        reason: 'the image card must be stashed before tag extraction runs',
      );
    });

    test('wrapper, image and options button live in one atomic chunk', () {
      final pushIdx = formatterFormatterJs.indexOf('mdImages.push(');
      final chunk = formatterFormatterJs.substring(
        pushIdx,
        formatterFormatterJs.indexOf('\n', pushIdx),
      );
      expect(chunk, contains('janitor-img-wrapper'));
      expect(chunk, contains('class="janitor-img"'));
      expect(chunk, contains('janitor-options-btn'));
      expect(chunk, contains(r'data-action="img-options"'));
    });

    test('the card is restored after paragraph splitting', () {
      final restoreIdx = formatterFormatterJs.indexOf(
        r'html = html.replace(/\x01MI_(\d+)\x01/g',
      );
      expect(
        restoreIdx,
        isNot(-1),
        reason: 'markdown image placeholders must be restored',
      );
      final paragraphIdx = formatterFormatterJs.indexOf('// 11. Paragraphs');
      expect(paragraphIdx, isNot(-1));
      expect(
        restoreIdx > paragraphIdx,
        isTrue,
        reason:
            'restoring before the paragraph step would expose the card to the '
            'block-placeholder isolation again',
      );
    });

    test('options button is positioned against the image wrapper', () {
      final wrapperIdx = rendererJs.indexOf('.janitor-img-wrapper {');
      expect(wrapperIdx, isNot(-1));
      final wrapperBlock = rendererJs.substring(
        wrapperIdx,
        rendererJs.indexOf('}', wrapperIdx) + 1,
      );
      expect(
        wrapperBlock,
        contains('position: relative'),
        reason: 'the wrapper is the containing block of the options button',
      );

      final btnIdx = rendererJs.indexOf('.janitor-options-btn,');
      expect(btnIdx, isNot(-1));
      final btnBlock = rendererJs.substring(
        btnIdx,
        rendererJs.indexOf('}', btnIdx) + 1,
      );
      expect(btnBlock, contains('position: absolute'));
      expect(btnBlock, contains('top: 8px'));
      expect(btnBlock, contains('right: 8px'));
    });
  });

  // ─── Headless engine (Phase 6.1) ────────────────────────────────────────────
  group('headless engine (headless.html)', () {
    test('loads glaze_sdk.js', () {
      expect(headlessHtml, contains('glaze_sdk.js'));
    });

    test('exposes window.headlessBridge.runSandboxedScript', () {
      expect(headlessHtml, contains('window.headlessBridge'));
      expect(headlessHtml, contains('runSandboxedScript'));
    });

    test('sandbox uses allow-scripts iframe', () {
      expect(headlessHtml, contains("sandbox"));
      expect(headlessHtml, contains('allow-scripts'));
      // Must not opt into same-origin execution.
      expect(headlessHtml, isNot(contains('allow-same-origin')));
    });
  });

  // ─── Interactive panels (Phase 6.2) ─────────────────────────────────────
  group('interactive panels (PanelHost in bridge.js)', () {
    test('PanelHost class is defined', () {
      expect(panelHostJs, contains('class PanelHost'));
    });

    test('Bridge exposes openPanel/closePanel/postToPanel helpers', () {
      expect(
        bridgeControllerJs,
        contains('openPanel(messageId, html, optionsJson)'),
      );
      expect(bridgeControllerJs, contains('closePanel(panelId)'));
      expect(
        bridgeControllerJs,
        contains('postToPanel(panelId, method, paramsJson)'),
      );
    });

    test(
      'panel iframe uses sandbox=allow-scripts without allow-same-origin',
      () {
        // The construction site inside PanelHost.open() must set the strict
        // sandbox so the panel's null-origin cannot reach window.parent or
        // window.flutter_inappwebview directly.
        final marker = "iframe.sandbox = 'allow-scripts'";
        final idx = panelHostJs.indexOf(marker);
        expect(
          idx,
          isNot(-1),
          reason: 'panel iframe must use sandbox="allow-scripts"',
        );
        final block = _extractBlockBody(panelHostJs, idx);
        expect(
          block,
          isNot(contains('allow-same-origin')),
          reason: 'panel iframe must NOT enable allow-same-origin',
        );
      },
    );

    test('parent->panel iframe is appended inside the message section', () {
      expect(
        panelHostJs,
        contains("section.querySelector('.msg-content') || section"),
        reason: 'panel must be attached to the message section, not the body',
      );
    });

    test('clearAll() also closes all panels', () {
      final marker = 'clearAll() {';
      final idx = bridgeControllerJs.indexOf(marker);
      expect(idx, isNot(-1));
      final body = _extractBlockBody(bridgeControllerJs, idx);
      expect(
        body,
        contains('_panelHost?.closeAll()'),
        reason:
            'Bridge.clearAll must close all panels before clearing messages',
      );
    });

    test('setMessages() closes panels before rendering a new batch', () {
      final marker = 'setMessages(messagesJson';
      final idx = bridgeControllerJs.indexOf(marker);
      expect(idx, isNot(-1));
      final body = _extractBlockBody(bridgeControllerJs, idx);
      expect(
        body,
        contains('_panelHost?.closeAll()'),
        reason: 'setMessages must drop all panels before mounting the new list',
      );
    });

    test('removeMessage() closes panels attached to that message', () {
      final marker = 'removeMessage(messageId) {';
      final idx = bridgeControllerJs.indexOf(marker);
      expect(idx, isNot(-1));
      final body = _extractBlockBody(bridgeControllerJs, idx);
      expect(
        body,
        contains('_panelHost.close(panelId)'),
        reason: 'removeMessage must close panels of the removed message',
      );
    });

    test('panel relays glaze:request back through the bridge', () {
      expect(panelHostJs, contains("_relayGlazeRequest(panel, data)"));
      // The PanelHost listener branches on `glaze:request` and forwards
      // to _relayGlazeRequest. We don't extract a sub-block here because
      // the call site is nested inside a for-of loop, which makes
      // brace-matching fragile.
      expect(
        panelHostJs,
        contains("data.type === 'glaze:request'"),
        reason: 'panel listener must branch on glaze:request type',
      );
    });

    test('panel iframe receives a glaze SDK copy via __glazeSdkSource', () {
      expect(
        panelHostJs,
        contains("JSON.stringify(window.__glazeSdkSource || '')"),
      );
    });

    test('panel iframe cannot impersonate the parent (source check)', () {
      final marker = '_setupListener() {';
      final idx = panelHostJs.indexOf(marker);
      expect(idx, isNot(-1));
      final body = _extractBlockBody(panelHostJs, idx);
      expect(
        body,
        contains('e.source !== panel.iframe.contentWindow'),
        reason:
            'PanelHost message listener must verify e.source to prevent spoofing',
      );
    });

    test('panel resize observer pushes glaze:panel-resize events', () {
      expect(panelHostJs, contains('ResizeObserver'));
      expect(panelHostJs, contains("'onPanelResize'"));
      expect(panelHostJs, contains("'glaze:panel-resize'"));
    });

    test('panel exposes window.glazePanel helpers to user code', () {
      expect(panelHostJs, contains('window.glazePanel'));
      expect(panelHostJs, contains('reportHeight'));
      expect(panelHostJs, contains('sendAction'));
    });
  });

  // ─── details/summary arrow ────────────────────────────────────────────────
  group('details/summary arrow (SHADOW_STYLE in renderer modules)', () {
    test('::-webkit-details-marker is hidden', () {
      expect(
        rendererJs,
        contains('::-webkit-details-marker { display: none !important; }'),
      );
    });

    test('::marker is hidden', () {
      expect(rendererJs, contains('::marker { display: none !important;'));
    });

    test('::before is disabled (arrow injected as real DOM span instead)', () {
      // display:flex on <summary> is ignored in some Android WebView versions.
      // The arrow is injected as a real .glaze-arrow <span> by fixDetailsSummaryArrows()
      // so it always participates in flex layout correctly.
      final beforeBlock = _extractSummaryBeforeBlock(rendererJs);
      expect(
        beforeBlock,
        contains('display: none !important'),
        reason:
            '::before must be hidden — real DOM .glaze-arrow span is used instead',
      );
    });

    test('.glaze-arrow span is styled', () {
      expect(
        rendererJs,
        contains('.glaze-arrow {'),
        reason: 'Real DOM arrow span must have CSS styles',
      );
      expect(
        rendererJs,
        contains('transition: transform 0.2s'),
        reason: '.glaze-arrow must have rotation transition',
      );
    });

    test('.glaze-arrow-open rotates 90deg when details is open', () {
      expect(
        rendererJs,
        contains('.glaze-arrow.glaze-arrow-open { transform: rotate(90deg); }'),
      );
    });

    test('fixDetailsSummaryArrows injects .glaze-arrow into every summary', () {
      expect(rendererJs, contains('fixDetailsSummaryArrows'));
      expect(rendererJs, contains("arrow.className = 'glaze-arrow'"));
    });

    test('writeShadowContent calls fixDetailsSummaryArrows after innerHTML', () {
      // Must be called AFTER root.innerHTML so it sees the inserted <details>.
      final writeBlock = _extractWriteShadowContent(rendererJs);
      final innerIdx = writeBlock.indexOf('root.innerHTML');
      final fixIdx = writeBlock.indexOf('fixDetailsSummaryArrows');
      expect(innerIdx, isNot(-1), reason: 'root.innerHTML must be present');
      expect(
        fixIdx,
        isNot(-1),
        reason: 'fixDetailsSummaryArrows must be called',
      );
      expect(
        fixIdx > innerIdx,
        isTrue,
        reason:
            'fixDetailsSummaryArrows must be called AFTER root.innerHTML = formatted',
      );
    });
  });

  // ─── edit textarea scroll speed ───────────────────────────────────────────
  group('edit textarea wheel scroll (bridge.js)', () {
    test('wheel listener on textarea uses preventDefault (not passive)', () {
      // passive:true prevents preventDefault — the scroll speed multiplier
      // requires preventDefault so we can set scrollTop manually.
      final wheelSection = _extractTextareaWheelListener(editControllerJs);
      expect(
        wheelSection,
        contains('preventDefault'),
        reason:
            'textarea wheel listener must call preventDefault to control scroll speed',
      );
      expect(
        wheelSection,
        isNot(contains("{ passive: true }")),
        reason:
            'passive:true prevents preventDefault; listener must be passive:false '
            'or omit the option to allow manual scrollTop control',
      );
    });

    test('wheel listener delegates scaling to shared helper', () {
      final wheelSection = _extractTextareaWheelListener(editControllerJs);
      expect(wheelSection, contains('_scaledWheelDelta(e, textarea)'));
      expect(
        editControllerJs,
        contains('if (e.deltaMode === 0) return e.deltaY * 0.3'),
      );
      expect(
        editControllerJs,
        contains('if (e.deltaMode === 1) return e.deltaY * 16'),
      );
    });

    test('wheel bubbles to chat when textarea cannot scroll itself', () {
      final wheelSection = _extractTextareaWheelListener(editControllerJs);
      expect(wheelSection, contains('canScrollSelf'));
      expect(wheelSection, contains('if (!canScrollSelf)'));
      expect(wheelSection, contains('return;'));
    });

    test('touch-drag on textarea scrolls the chat via scrollTopFn', () {
      // The auto-growing textarea never scrolls itself, so a finger drag must
      // be forwarded to the chat container instead of being swallowed.
      expect(
        editControllerJs,
        contains("textarea.addEventListener('touchstart'"),
      );
      expect(
        editControllerJs,
        contains("textarea.addEventListener('touchmove'"),
      );
      // touchmove must be passive:false so preventDefault() can suppress the
      // native caret/selection drag and hand the gesture to the chat scroll.
      expect(editControllerJs, contains('scrollTopFn(scrollTopFn() - dy)'));
    });

    test('touch-drag on textarea keeps gliding with inertia after release', () {
      // The manual scrollTop drive has no native momentum, so releasing the
      // finger would stop the chat dead. touchend must launch a decaying glide.
      expect(
        editControllerJs,
        contains("textarea.addEventListener('touchend'"),
      );
      expect(editControllerJs, contains('requestAnimationFrame(step)'));
      // Velocity is tracked during the drag and decays each frame.
      expect(editControllerJs, contains('touchVelocity'));
      expect(editControllerJs, contains('Math.pow(0.95'));
      // A fresh touch or a cancel must abort an in-flight glide.
      expect(editControllerJs, contains('cancelInertia'));
      expect(
        editControllerJs,
        contains("textarea.addEventListener('touchcancel'"),
      );
    });

    test(
      'wheel listener calls stopPropagation to prevent chat container from also scrolling',
      () {
        final wheelSection = _extractTextareaWheelListener(editControllerJs);
        expect(wheelSection, contains('stopPropagation'));
      },
    );

    test('textarea pointer/click events do not reach document dispatcher', () {
      expect(
        editControllerJs,
        contains("textarea.addEventListener('pointerdown'"),
      );
      expect(
        editControllerJs,
        contains("textarea.addEventListener('mousedown'"),
      );
      expect(editControllerJs, contains("textarea.addEventListener('click'"));
      expect(
        editControllerJs,
        contains("textarea.addEventListener('dblclick'"),
      );
      expect(editControllerJs, contains('stopEditEventPropagation'));
    });

    test('textarea reports focus to Dart edit focus handler', () {
      expect(editControllerJs, contains("textarea.addEventListener('focus'"));
      expect(editControllerJs, contains("textarea.addEventListener('blur'"));
      expect(
        editControllerJs,
        contains("this._sendToFlutter('onEditFocusChange'"),
      );
    });
  });

  group('swipe gesture axis lock (SwipeGestureHandler)', () {
    test('touchmove listener is passive:false so it can preventDefault', () {
      expect(
        swipeHandlerJs,
        contains("addEventListener('touchmove', onMove, { passive: false })"),
      );
    });

    test(
      'gesture axis is only committed after a deliberate travel threshold',
      () {
        // Until the finger moves past the slop, the handler stays hands-off so
        // the WebView's native vertical scroll can engage — grabbing a message
        // with swipe variations must not trap a vertical scroll.
        expect(swipeHandlerJs, contains('AXIS_LOCK_SLOP'));
        expect(swipeHandlerJs, contains('axisLocked'));
        expect(
          swipeHandlerJs,
          contains(
            'if (absX < AXIS_LOCK_SLOP && absY < AXIS_LOCK_SLOP) return;',
          ),
        );
      },
    );

    test('a tie or vertical-dominant drag becomes a native scroll', () {
      // absY >= absX (not strict) biases equal drags toward scrolling.
      expect(swipeHandlerJs, contains('if (absY >= absX)'));
      expect(swipeHandlerJs, contains('scrollingVertical = true;'));
    });
  });

  // ─── main chat container scroll speed ────────────────────────────────────
  group('chat container wheel scroll (index.html)', () {
    test('chat container wheel listener is registered', () {
      expect(bridgeIndexJs, contains("container.addEventListener('wheel'"));
    });

    test('pixel-mode scroll uses 0.3 multiplier', () {
      expect(
        bridgeIndexJs,
        contains('deltaY * 0.3'),
        reason:
            'Chat container scroll must use 0.3 multiplier for pixel-mode events',
      );
    });

    test('line-mode scroll uses 16px multiplier', () {
      expect(
        bridgeIndexJs,
        contains('deltaY * 16'),
        reason:
            'Chat container scroll must use 16px-per-line for line-mode events',
      );
    });

    test('wheel listener is not passive (requires preventDefault)', () {
      // The chat container listener calls preventDefault to suppress native scroll
      // and replace it with the manually-scaled scrollTop assignment.
      expect(
        bridgeIndexJs,
        contains('passive: false'),
        reason:
            'Chat container wheel listener must be passive:false to allow preventDefault',
      );
    });
  });

  // ─── bottom inset split (soft keyboard) ───────────────────────────────────
  group('bottom inset vs. viewport shrink (chat_bridge_controller.js)', () {
    test('padding is the inset minus the measured viewport shrink', () {
      expect(
        bridgeControllerJs,
        contains('this._bottomInsetPx - this._viewportShrinkPx()'),
        reason:
            'Whether the soft keyboard shrinks the WebView viewport or overlays '
            'it is embedder-specific. Turning the whole Flutter inset into '
            'padding without subtracting the measured shrink double-counts the '
            'keyboard and lets the chat scroll a keyboard-height above the '
            'input bar.',
      );
    });

    test('the shrink is measured against the Flutter-reported box height', () {
      expect(
        bridgeControllerJs,
        contains('full - this.virtualList.container.clientHeight'),
        reason:
            'The shrink must be measured, not assumed — that is what keeps the '
            'same code correct on embedders that resize the WebView and on '
            'those that do not.',
      );
    });

    test('a viewport resize re-runs the reconciliation', () {
      expect(
        bridgeControllerJs,
        contains('_setupViewportShrinkListener()'),
        reason:
            'The keyboard can resize the WebView without any Flutter push, so '
            'the padding split has to be recomputed on viewport changes too.',
      );
      expect(
        bridgeControllerJs,
        contains('new ResizeObserver(onViewportChange)'),
      );
    });

    test('padding reductions are deferred, growth is immediate', () {
      expect(
        bridgeControllerJs,
        contains('_scheduleShrink(container)'),
        reason:
            'Shortening the scroll range under a list parked at the bottom '
            'makes the engine clamp scrollTop itself — an instant jump the '
            'glide cannot smooth. Reductions must wait for the viewport and '
            "Flutter's inset to agree; growth is always safe.",
      );
    });

    test('the resting offset is derived from the full box height', () {
      expect(
        bridgeControllerJs,
        contains('contentHeight + this._bottomInsetPx - full'),
        reason:
            'At rest the padding is `inset - shrink` and the viewport is '
            '`full - shrink`, so the shrink cancels: the resting offset is the '
            'same number whether the keyboard already resized the viewport or '
            'not. That is what lets the glide aim at the final position from '
            'the first frame instead of chasing a moving target.',
      );
    });

    test('scroll compensation is driven by the inset, not the padding', () {
      expect(
        bridgeControllerJs,
        contains('container.scrollTop + insetDiff'),
        reason:
            'The content must follow the input bar by the full inset delta '
            'regardless of how the inset was split between padding and shrink, '
            'or the list stops tracking the keyboard.',
      );
    });
  });

  // ─── edit textarea CSS (styles.css) ───────────────────────────────────────
  group('edit textarea CSS (styles.css)', () {
    test('overscroll-behavior:contain prevents scroll bleed to parent', () {
      expect(
        stylessCss,
        contains('overscroll-behavior: contain'),
        reason:
            'Without overscroll-behavior:contain, reaching the end of the textarea '
            'causes the parent chat container to scroll',
      );
    });

    test('the edit footer reserves its own room inside the message', () {
      expect(
        stylessCss,
        contains('.message-section.editing .msg-footer {'),
        reason:
            'The Save/Cancel row must be sized inside the edited message so the '
            'chat container clears it with its ordinary bottom inset — Flutter '
            'no longer reserves edit-only scroll room (chat_screen.dart).',
      );
      expect(
        stylessCss,
        contains('.message-section.layout-bubble.editing .edit-buttons {'),
        reason:
            'In bubble layout the footer is a wrapping flex row that follows the '
            'bubble width; the edit buttons need a row of their own or a narrow '
            'bubble squeezes them against the meta/switcher columns.',
      );
    });
  });

  // ─── InteractionDispatch extraction (Phase 3.1) ────────────────────────────
  group('InteractionDispatch (bridge.js)', () {
    test('InteractionDispatch class exists', () {
      expect(interactionDispatchJs, contains('class InteractionDispatch'));
    });

    test('handleClick method exists', () {
      expect(interactionDispatchJs, contains('handleClick(e)'));
    });

    test('action map contains all expected data-action keys', () {
      final requiredActions = [
        'memory-click',
        'inject-click',
        'toggle-hidden',
        'toggle-image-hidden',
        'swipe-left',
        'swipe-right',
        'agent-swipe-left',
        'agent-swipe-right',
        'greeting-prev',
        'greeting-next',
        'stop',
        'regenerate',
        'toggle-guided',
        'edit-save',
        'edit-cancel',
        'open-actions',
        'img-retry',
        'img-find',
        'img-regen',
        'img-stop',
        'ext-block-edit',
        'ext-block-delete',
      ];
      for (final action in requiredActions) {
        expect(
          interactionDispatchJs,
          contains("'$action':"),
          reason: 'InteractionDispatch._actionMap must contain key "$action"',
        );
      }
    });

    test('ExtBlock placeholders do not expose edit or delete buttons', () {
      expect(bridgeControllerJs, contains('if (block.id)'));
    });

    test('Bridge creates InteractionDispatch instance', () {
      expect(bridgeControllerJs, contains('new InteractionDispatch(this)'));
    });

    test('click listener delegates to InteractionDispatch.handleClick', () {
      expect(bridgeControllerJs, contains('this._interaction.handleClick(e)'));
    });
  });

  // ─── GenTimer extraction (Phase 3.5) ───────────────────────────────────────
  group('GenTimer (bridge.js)', () {
    test('GenTimer class exists', () {
      expect(genTimerJs, contains('class GenTimer'));
    });

    test('GenTimer has start method', () {
      expect(genTimerJs, contains('GenTimer'));
      expect(genTimerJs, contains('start()'));
    });

    test('GenTimer has stop method', () {
      expect(genTimerJs, contains('GenTimer'));
      expect(genTimerJs, contains('stop()'));
    });

    test('Bridge creates GenTimer instance', () {
      expect(bridgeControllerJs, contains('new GenTimer('));
    });

    test('setGenerating delegates to generation timer reconciliation', () {
      final marker = 'setGenerating(value) {';
      final idx = bridgeControllerJs.indexOf(marker);
      expect(idx, isNot(-1));
      final body = _extractBlockBody(bridgeControllerJs, idx);
      expect(body, contains('this._syncGenerationTimer()'));
    });

    test('hide-on-scroll is not frozen for the whole streaming window', () {
      final idx = bridgeControllerJs.indexOf('const updateHeader = () => {');
      expect(idx, isNot(-1));
      final body = _extractBlockBody(bridgeControllerJs, idx);
      // Gating the tracker on the generation flag suspended hide-on-scroll for
      // as long as a reply streamed — the header stopped responding to
      // scrolling entirely. Only our own scrolls may be suppressed.
      expect(body, isNot(contains('this.isGenerating')));
      expect(body, contains('this._isProgrammaticScroll()'));
    });

    test('upward scroll restores a hidden header during auto-follow', () {
      final marker = 'if (this._isProgrammaticScroll()) {';
      final updateHeaderIdx = bridgeControllerJs.indexOf(
        'const updateHeader = () => {',
      );
      expect(updateHeaderIdx, isNot(-1));
      final idx = bridgeControllerJs.indexOf(marker, updateHeaderIdx);
      expect(idx, isNot(-1));
      final body = _extractBlockBody(bridgeControllerJs, idx);
      expect(body, contains('st < this._headerLastTop - 3'));
      expect(body, contains('this._headerHidden = false'));
      expect(body, contains("this._sendToFlutter('onHeaderScroll', [false])"));
      expect(body, isNot(contains('[true]')));
    });

    test('programmatic-scroll probe reads the virtual list flag', () {
      final marker = '_isProgrammaticScroll() {';
      final idx = bridgeControllerJs.indexOf(marker);
      expect(idx, isNot(-1));
      final body = _extractBlockBody(bridgeControllerJs, idx);
      // Streaming auto-follow / scroll-to-bottom / anchor restore raise the
      // virtual list's own flag; the bottom-inset re-pin glide raises
      // `_repinAnimating`. Both are ours, neither is the user scrolling.
      expect(body, contains('this.virtualList?.isProgrammaticScrolling'));
      expect(body, contains('this._repinAnimating'));
      expect(virtualScrollJs, contains('this.isProgrammaticScrolling = true'));
    });

    test('ending a generation re-shows the header only if it is stranded', () {
      final marker = 'setGenerating(value) {';
      final idx = bridgeControllerJs.indexOf(marker);
      expect(idx, isNot(-1));
      final body = _extractBlockBody(bridgeControllerJs, idx);
      // A hide the user asked for by scrolling down mid-stream must survive the
      // end of the generation, so the falling edge no longer force-shows.
      expect(body, contains('this._ensureHeaderReachable()'));
      expect(body, isNot(contains("this._sendToFlutter('onHeaderScroll'")));

      final helperIdx = bridgeControllerJs.indexOf(
        '_ensureHeaderReachable() {',
      );
      expect(helperIdx, isNot(-1));
      final helper = _extractBlockBody(bridgeControllerJs, helperIdx);
      // Only when the list no longer has the scroll range that an upward
      // scroll would need to bring the header back.
      expect(helper, contains('if (!this._headerHidden) return'));
      expect(
        helper,
        contains('container.scrollHeight - container.clientHeight > 50'),
      );
      expect(helper, contains('this._headerHidden = false'));
      expect(
        helper,
        contains("this._sendToFlutter('onHeaderScroll', [false])"),
      );
    });

    test('a trimmed message re-checks that the header is reachable', () {
      final idx = bridgeControllerJs.indexOf('removeMessage(messageId) {');
      expect(idx, isNot(-1));
      final body = _extractBlockBody(bridgeControllerJs, idx);
      // The cancelled-generation placeholder is dropped ~340ms later, behind
      // its exit animation — long after setGenerating() ran its own check.
      expect(
        '_ensureHeaderReachable()'.allMatches(body).length,
        greaterThanOrEqualTo(2),
      );
    });

    test('showHeader re-shows the header and re-baselines the tracker', () {
      final marker = 'showHeader() {';
      final idx = bridgeControllerJs.indexOf(marker);
      expect(idx, isNot(-1));
      final body = _extractBlockBody(bridgeControllerJs, idx);
      // The WebView is kept alive across chats, so opening one has to clear
      // both halves of the carried-over state: the hidden flag and the scroll
      // baseline the next scroll event is compared against.
      expect(body, contains('this._headerHidden = false'));
      expect(body, contains('this._headerLastTop'));
      expect(body, contains('this._headerRebaselineUntil'));
      // Emitted unconditionally so Flutter's own header state is realigned.
      expect(body, contains("this._sendToFlutter('onHeaderScroll', [false])"));
    });

    test('header tracker only re-baselines inside the rebaseline window', () {
      final marker = 'const updateHeader = () => {';
      final idx = bridgeControllerJs.indexOf(marker);
      expect(idx, isNot(-1));
      final body = _extractBlockBody(bridgeControllerJs, idx);
      // The programmatic jump to the bottom right after a chat opens must not
      // be read as the user scrolling down.
      expect(body, contains('Date.now() < this._headerRebaselineUntil'));
    });

    test('post-gen activity does not keep the generation timer running', () {
      expect(bridgeControllerJs, contains('setPostGenRunning(value)'));
      final postGenIdx = bridgeControllerJs.indexOf(
        'setPostGenRunning(value) {',
      );
      expect(postGenIdx, isNot(-1));
      final postGenBody = _extractBlockBody(bridgeControllerJs, postGenIdx);
      expect(postGenBody, isNot(contains('_syncGenerationTimer')));

      final marker = '_syncGenerationTimer() {';
      final idx = bridgeControllerJs.indexOf(marker);
      expect(idx, isNot(-1));
      final body = _extractBlockBody(bridgeControllerJs, idx);
      expect(body, contains('this.isGenerating'));
      expect(body, isNot(contains('this.isPostGenRunning')));
      expect(body, contains('this._genTimer.start()'));
      expect(body, contains('this._genTimer.stop()'));
    });

    test(
      'message controls keep post-gen activity separate from stream gating',
      () {
        final marker = '_syncMessageControls(section, msg) {';
        final idx = bridgeControllerJs.indexOf(marker);
        expect(idx, isNot(-1));
        final body = _extractBlockBody(bridgeControllerJs, idx);
        expect(body, isNot(contains('hasGenerationActivity')));
        expect(body, isNot(contains('isPostGenRunning')));
      },
    );

    test('incremental controls restore the rerun-cleaner button', () {
      final marker = '_syncMessageControls(section, msg) {';
      final idx = bridgeControllerJs.indexOf(marker);
      expect(idx, isNot(-1));
      final body = _extractBlockBody(bridgeControllerJs, idx);
      expect(body, contains("rerun.className = 'msg-rerun-cleaner'"));
      expect(body, contains("rerun.dataset.action = 'rerun-cleaner'"));
      expect(body, contains('agentSwipeTotal >= 1'));
    });
  });

  // ─── renderMessage always returns array (Phase 3.6) ────────────────────────
  group('renderMessage return type (renderer modules)', () {
    test('renderMessage returns elements array (not conditional)', () {
      final marker = 'renderMessage(messageData)';
      final idx = rendererJs.indexOf(marker);
      expect(idx, isNot(-1), reason: 'renderMessage must exist');

      final body = _extractBlockBody(rendererJs, idx);
      expect(
        body,
        isNot(contains('elements.length > 1 ? elements : messageEl')),
        reason:
            'renderMessage must always return array, not conditional HTMLElement|Array',
      );
      expect(
        body,
        contains('return elements'),
        reason: 'renderMessage must return the elements array directly',
      );
    });

    test('no Array.isArray checks remain in bridge.js call sites', () {
      expect(
        bridgeControllerJs,
        isNot(contains('Array.isArray(rendered)')),
        reason:
            'All Array.isArray(rendered) checks should be removed since renderMessage always returns array',
      );
    });
  });

  // ─── selectionMode public getter (Phase 3.7) ──────────────────────────────
  group('selectionMode encapsulation (SelectionManager)', () {
    test('SelectionManager has public selectionMode getter', () {
      expect(
        selectionManagerJs,
        contains('get selectionMode()'),
        reason: 'SelectionManager must expose selectionMode as public getter',
      );
    });

    test('bridge.js does not access _selectionMode directly', () {
      expect(
        bridgeControllerJs,
        isNot(contains('renderer._selectionMode')),
        reason:
            'Bridge must use SelectionManager.selectionMode, not the private _selectionMode field',
      );
    });
  });

  group('message actions during selection', () {
    test('renderer always creates the actions button', () {
      expect(
        rendererMessageJs,
        contains("actions.className = 'msg-actions-btn'"),
      );
      expect(rendererMessageJs, isNot(contains('shouldHideActions()')));
    });

    test('selection mode hides actions without removing them', () {
      expect(
        stylessCss,
        contains(
          '.message-section.selection-mode .msg-actions-btn {\n  visibility: hidden;\n}',
        ),
      );
    });
  });

  // ─── Streaming fast path (Phase 4.1) ───────────────────────────────────────
  group('updateMessageContent fast path (renderer modules)', () {
    test('updateMessageContent has fast path for text-only updates', () {
      final marker =
          'updateMessageContent(sectionEl, text, reasoning, isUser, isTyping, animate)';
      final idx = rendererJs.indexOf(marker);
      expect(idx, isNot(-1), reason: 'updateMessageContent must exist');

      final body = _extractBlockBody(rendererJs, idx);
      expect(
        body,
        contains('!isTyping && !isError && !animate'),
        reason:
            'Fast path condition must check not-typing, not-error, not-animate',
      );
      expect(
        body,
        contains('.glaze-message'),
        reason: 'Fast path must patch existing .glaze-message element',
      );
      // Regression guard: the fast path must only reuse the bubble's OWN
      // content host (direct child of .msg-body). A plain descendant query
      // also matches the error window's nested `.message-content`, so swiping
      // from an error to a healthy variation would rewrite the new text inside
      // the red error chrome instead of rebuilding the body.
      expect(
        body,
        contains(":scope > .message-content"),
        reason:
            'Fast path host lookup must be scoped to a direct child so it '
            'never matches the error window\'s nested content host',
      );
    });
  });

  // ─── _createGenStat dedup (Phase 4.3) ──────────────────────────────────────
  group('_createGenStat dedup (renderer modules)', () {
    test('_createGenStat method exists', () {
      expect(rendererJs, contains('_createGenStat('));
    });

    test('_createGenStat creates gen-stat div', () {
      final idx = rendererJs.indexOf('_createGenStat(');
      final body = _extractBlockBody(rendererJs, idx);
      expect(body, contains("'gen-stat'"));
    });

    test('_createBubbleMeta uses _createGenStat', () {
      final idx = rendererJs.indexOf('_createBubbleMeta(m)');
      final body = _extractBlockBody(rendererJs, idx);
      expect(
        body,
        contains('_createGenStat'),
        reason:
            '_createBubbleMeta must delegate to _createGenStat instead of inline DOM construction',
      );
    });

    test('_createFooter uses _createGenStat', () {
      final idx = rendererJs.indexOf('_createFooter(m)');
      final body = _extractBlockBody(rendererJs, idx);
      expect(
        body,
        contains('_createGenStat'),
        reason:
            '_createFooter must delegate to _createGenStat instead of inline DOM construction',
      );
    });
  });
}

// ─── helpers ──────────────────────────────────────────────────────────────────

/// Extracts the summary::before CSS block from SHADOW_STYLE in renderer modules.
String _extractSummaryBeforeBlock(String src) {
  final marker = 'summary::before {';
  final idx = src.indexOf(marker);
  if (idx == -1) return '';
  final end = src.indexOf('}', idx);
  if (end == -1) return src.substring(idx);
  return src.substring(idx, end + 1);
}

/// Extracts the writeShadowContent method body from renderer modules.
/// Looks for the definition (not a call), i.e. the line that starts with the name.
String _extractWriteShadowContent(String src) {
  final marker = 'writeShadowContent({';
  int idx = src.indexOf(marker);
  if (idx == -1) return '';
  idx = src.indexOf('}) {', idx);
  if (idx == -1) return '';
  int depth = 0;
  int start = src.indexOf('{', idx);
  if (start == -1) return '';
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

/// Extracts the textarea wheel event listener block from bridge.js.
/// Returns the portion of code starting at the wheel addEventListener call
/// through the closing `}, {` options object.
String _extractTextareaWheelListener(String src) {
  final marker = "addEventListener('wheel'";
  // Find the one inside startEdit (textarea context), not the container one.
  // We look for the occurrence that is preceded by 'textarea' within ~300 chars.
  int pos = 0;
  while (true) {
    final idx = src.indexOf(marker, pos);
    if (idx == -1) break;
    final context = src.substring(idx > 300 ? idx - 300 : 0, idx);
    if (context.contains('textarea')) {
      // Extract from this point to the end of the listener (closing });)
      final end = src.indexOf('});', idx);
      if (end == -1) return src.substring(idx);
      return src.substring(idx, end + 3);
    }
    pos = idx + 1;
  }
  return '';
}

/// Extracts the body of a JS method/class block starting from [fromIndex].
/// Walks braces to find the matching close.
String _extractBlockBody(
  String src,
  int fromIndex, {
  String open = '{',
  String close = '}',
}) {
  int start = src.indexOf(open, fromIndex);
  if (start == -1) return '';
  int depth = 0;
  for (int i = start; i < src.length; i++) {
    if (src[i] == open) {
      depth++;
    } else if (src[i] == close) {
      depth--;
      if (depth == 0) return src.substring(start, i + 1);
    }
  }
  return src.substring(start);
}
