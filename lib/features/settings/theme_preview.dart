import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/theme/app_colors.dart';
import '../../shared/theme/theme_font_provider.dart';
import '../../shared/theme/theme_preset.dart';
import '../../shared/theme/theme_provider.dart';
import '../../shared/theme/theme_settings_schema.dart';
import '../../shared/theme/ui_scale.dart';
import '../chat/bridge/chat_webview_environment.dart';
import '../chat/bridge/chat_webview_settings.dart';
import '../chat/bridge/chat_webview_theme_builder.dart';
import '../chat/chrome/chat_chrome_channel.dart';
import '../chat/chrome/chrome_json.dart';
import 'app_settings_provider.dart';

/// The preview page next to the chat page (`assets/chat_webview/`).
const String kThemePreviewPage = 'theme_preview.html';

/// Live preview of the active theme: a few sample messages and the chat's
/// header and composer, drawn in a WebView by the chat page's own renderer,
/// stylesheet and chrome — so a theme's CSS and templates show exactly as
/// they will in a chat.
///
/// Follows the active preset by itself; edits made anywhere in the theme
/// editor show up as they are made.
class ThemeChatPreview extends ConsumerStatefulWidget {
  const ThemeChatPreview({super.key});

  @override
  ConsumerState<ThemeChatPreview> createState() => _ThemeChatPreviewState();
}

class _ThemeChatPreviewState extends ConsumerState<ThemeChatPreview> {
  late final InAppWebViewSettings _settings = chatWebViewInAppSettings();
  InAppWebViewController? _controller;
  bool _ready = false;
  bool _flushQueued = false;

  /// Bumped to build a new WebView after its page process died.
  int _generation = 0;

  /// What the page holds, by section — compared before sending so a slider
  /// drag sends only what it moved.
  final Map<String, Object?> _sent = {};
  Map<String, Object?> _latest = const {};

  void _onPageGone() {
    if (!mounted) return;
    setState(() {
      _ready = false;
      _controller = null;
      _sent.clear();
      _generation++;
    });
  }

  void _onChromeIntent(List<dynamic> args) {
    if (args.length < 2 || args[1] is! String) return;
    try {
      final intent = jsonDecode(args[1] as String);
      if (intent is! Map || intent['t'] != 'layout') return;
      final data = intent['d'];
      if (data is! Map) return;
      final report = ChromeLayoutReport.fromJson(
        Map<String, dynamic>.from(data),
      );
      final top = (report.header?.bottom ?? 0) + 8;
      final bottom = report.composerHeight + 8;
      unawaited(
        _send({
          'insets': {'top': top, 'bottom': bottom},
        }),
      );
    } catch (_) {}
  }

  Future<void> _send(Map<String, Object?> msg) async {
    final controller = _controller;
    if (controller == null || !_ready || msg.isEmpty) return;
    try {
      await controller.evaluateJavascript(
        source:
            'window.__glazePreview&&window.__glazePreview.apply(${jsonEncode(jsonEncode(msg))})',
      );
    } catch (e) {
      debugPrint('[ThemePreview] apply failed: $e');
    }
  }

  void _scheduleFlush() {
    if (_flushQueued) return;
    _flushQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _flushQueued = false;
      if (!mounted) return;
      final msg = <String, Object?>{};
      _latest.forEach((section, value) {
        if (_same(_sent[section], value)) return;
        _sent[section] = value;
        msg[section] = value;
      });
      unawaited(_send(msg));
    });
  }

  /// Big strings (fonts, images as data URLs) are compared by identity
  /// first: they are the same String object until the preset changes them.
  static bool _same(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a is _Section && b is _Section) return a.key == b.key;
    return jsonEncode(a) == jsonEncode(b);
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    final preset = theme.activePreset;
    final fontStyle = ref.watch(chatFontStyleProvider);
    final fontData = ref.watch(chatFontDataProvider).value;
    final uiFontFamily = ref.watch(uiFontFamilyProvider).value;
    final uiFontData = ref.watch(uiFontDataProvider).value;
    final app = ref.watch(appSettingsProvider).value ?? const AppSettings();

    _latest = _sections(
      context,
      preset,
      fontStyle: fontStyle,
      fontData: fontData,
      uiFontFamily: uiFontFamily,
      uiFontData: uiFontData,
      app: app,
    );
    if (_ready) _scheduleFlush();

    return ColoredBox(
      color: context.cs.surface,
      child: InAppWebView(
        key: ValueKey<int>(_generation),
        webViewEnvironment: chatWebViewEnvironment,
        initialFile: chatWebViewInitialFile(kThemePreviewPage),
        initialUrlRequest: chatWebViewInitialUrlRequest(kThemePreviewPage),
        initialSettings: _settings,
        initialUserScripts: chatWebViewUserScripts(),
        onWebViewCreated: (controller) {
          _controller = controller;
          controller.addJavaScriptHandler(
            handlerName: 'onChromeIntent',
            callback: (JavaScriptHandlerFunctionData data) =>
                _onChromeIntent(data.args),
          );
        },
        onLoadStop: (controller, url) {
          if (!mounted) return;
          _ready = true;
          _sent.clear();
          _scheduleFlush();
        },
        onRenderProcessGone: (controller, detail) => _onPageGone(),
        onWebContentProcessDidTerminate: (controller) => _onPageGone(),
        shouldOverrideUrlLoading: (controller, request) async =>
            chatWebViewNavigationPolicy(
              request.request.url,
              mainFrame: request.isForMainFrame,
              page: kThemePreviewPage,
            ),
      ),
    );
  }

  Map<String, Object?> _sections(
    BuildContext context,
    ThemePreset preset, {
    required ChatFontStyle fontStyle,
    required String? fontData,
    required String? uiFontFamily,
    required String? uiFontData,
    required AppSettings app,
  }) {
    final cs = context.cs;
    final accent = cs.primary;
    final bgImage = switch (preset.chatBgMode) {
      'custom' => preset.chatBgImage,
      'color' || 'avatar' => null,
      _ => preset.bgImage,
    };
    final base = preset.chatBgMode == 'color'
        ? (preset.chatBgColorParsed ?? cs.surface)
        : cs.surface;
    final chromeTheme_ = chromeTheme(
      context,
      preset,
      batterySaver: false,
      desktop: false,
      fontFamily: uiFontFamily,
    );
    return {
      'theme': ChatWebViewThemeBuilder.build(
        context,
        ChatWebViewThemeInput(
          elementOpacity: preset.elementOpacity,
          elementBlur: preset.elementBlur,
          chatFontSize: fontStyle.fontSize,
          chatLayout: preset.chatLayout,
          bgDim: bgImage == null ? 0 : preset.bgDim,
          uiFontWeight: preset.uiFontWeight,
          userMessageFontWeight: preset.userMessageFontWeight,
          charMessageFontWeight: preset.charMessageFontWeight,
          userBubbleRadius: preset.userBubbleRadius,
          charBubbleRadius: preset.charBubbleRadius,
          showUserAvatar: preset.showUserAvatar,
          showCharAvatar: preset.showCharAvatar,
          showUserName: preset.showUserName,
          showCharName: preset.showCharName,
          avatarRoundness: preset.avatarRoundness,
          userBubbleGradient: preset.userBubbleGradientParsed,
          charBubbleGradient: preset.charBubbleGradientParsed,
          textBgOpacity: preset.textBgOpacity,
        ),
      ),
      'font': _Section(
        '${fontStyle.fontFamily}|${identityHashCode(fontData)}|'
        '${fontStyle.fontSize}|${fontStyle.letterSpacing}',
        {
          'family': fontStyle.fontFamily,
          'data': fontData,
          'size': fontStyle.fontSize,
          'letterSpacing': fontStyle.letterSpacing,
        },
      ),
      'background': _Section(
        '${base.toARGB32()}|${identityHashCode(bgImage)}|${preset.bgBlur}|'
        '${preset.bgNoiseOpacity}|${preset.bgNoiseIntensity}',
        {
          'color': _css(base),
          'url': bgImage == null
              ? null
              : chatWebViewResolveLocalFileUrl(bgImage),
          'blur': preset.bgBlur.round(),
          'noiseOpacity': preset.bgNoiseOpacity,
          'noiseIntensity': preset.bgNoiseIntensity,
        },
      ),
      'settings': {
        'hideMessageId': preset.hideMessageId ?? app.hideMessageId,
        'hideGenerationTime':
            preset.hideGenerationTime ?? app.hideGenerationTime,
        'hideTokenCount': preset.hideTokenCount ?? app.hideTokenCount,
        'studioEnabled': false,
      },
      'layout': preset.messageLayoutPayload,
      'messages': _sampleMessages(accent),
      'chrome': _Section(
        '${jsonEncode(chromeTheme_)}|${identityHashCode(uiFontData)}|'
        '${jsonEncode(preset.chromeLayoutPayload)}',
        {
          'theme': chromeTheme_,
          'skin': preset.chromeLayoutPayload,
          'font': chromeFont(
            uiFontData,
            variable: preset.uiFontMode == 'glaze',
          ),
          'layout': const {
            'safeTop': 0,
            'safeBottom': 0,
            'inset': 0,
            'keyboard': 0,
            'gutter': 0,
            'fades': true,
            'drawer': {'show': false, 'height': 0, 'progress': 0},
          },
          'header': {
            'show': true,
            'hidden': false,
            'flush': false,
            'radius': 20,
            'title': 'Rei',
            'session': 'Session #4',
            'avatar': {'color': chromeColor(accent), 'initial': 'R'},
            'search': {'kind': 'mobile', 'open': false, 'hint': ''},
          },
          'composer': {
            'show': true,
            'mode': 'compose',
            'placeholder': 'chat_placeholder'.tr(),
            'readOnly': true,
            'pins': [
              for (final (key, icon) in const [
                ('preview:spark', Icons.auto_awesome),
                ('preview:bolt', Icons.bolt),
              ])
                {'key': key, 'icon': chromeIcon(icon), 'tap': false},
            ],
            'send': {
              'icon': chromeIcon(Icons.send_rounded),
              'tap': false,
              'slot': false,
            },
          },
        },
      ),
    };
  }

  static String _css(Color c) =>
      'rgba(${(c.r * 255).round()}, ${(c.g * 255).round()}, '
      '${(c.b * 255).round()}, ${c.a.toStringAsFixed(3)})';

  static List<Map<String, Object?>> _sampleMessages(Color accent) {
    final hex =
        '#${(accent.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    final start = DateTime(2026, 3, 24, 10, 8).millisecondsSinceEpoch;
    return [
      {
        'id': 'preview_1',
        'role': 'assistant',
        'text':
            '*Rei looks up from the book and smiles.* "You made it. The tea\'s still warm."',
        'timestamp': start,
        'displayName': 'Rei',
        'avatarColor': hex,
        'messageIndex': 0,
        'isHidden': false,
        'isError': false,
      },
      {
        'id': 'preview_2',
        'role': 'user',
        'text':
            '*I drop into the chair across the table.* "Sorry, the train was late."',
        'timestamp': start + 60 * 1000,
        'displayName': 'You',
        'messageIndex': 1,
        'isHidden': false,
        'isError': false,
      },
      {
        'id': 'preview_3',
        'role': 'assistant',
        'text':
            'She slides a cup toward you. "**Careful**, it\'s hot — and `oolong`, your favourite."',
        'timestamp': start + 2 * 60 * 1000,
        'displayName': 'Rei',
        'avatarColor': hex,
        'messageIndex': 2,
        'swipeIndex': 0,
        'swipeTotal': 3,
        'genTime': '4.2s',
        'tokens': 128,
        'isLast': true,
        'isHidden': false,
        'isError': false,
      },
    ];
  }
}

/// [ThemeChatPreview] in a rounded frame of a fixed [height], the way the
/// theme editor and its colour picker show it.
class ThemePreviewCard extends StatelessWidget {
  final double height;

  const ThemePreviewCard({super.key, required this.height});

  @override
  Widget build(BuildContext context) {
    final radius = context.glazeBorderRadius(20);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: SizedBox(
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ThemeChatPreview(),
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(
                      color: context.cs.outlineVariant.withValues(alpha: 0.75),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A section whose payload is too big to compare as JSON on every rebuild;
/// [key] stands for it.
class _Section {
  const _Section(this.key, this.value);
  final String key;
  final Object? value;

  Object? toJson() => value;
}
