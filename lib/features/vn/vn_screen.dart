import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/state/db_provider.dart';
import '../../core/utils/app_orientation.dart';
import '../../shared/widgets/glaze_error_block.dart';
import '../../shared/widgets/glaze_scaffold.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/list_controls.dart';
import '../chat/bridge/chat_webview_environment.dart';
import 'models/vn_document.dart';
import 'services/vn_script.dart';
import 'vn_labels.dart';
import 'vn_provider.dart';
import 'widgets/vn_cast_review.dart';
import 'widgets/vn_generating_badge.dart';
import 'widgets/vn_setup_view.dart';
import 'widgets/vn_status_sheet.dart';
import 'widgets/vn_touch_forwarder.dart';

/// One visual novel, opened from the chat list: a walkable first-person game
/// the model keeps writing as the player plays, in its own WebView.
///
/// Until the setup passes and the first chapter exist the screen shows their
/// progress; after that it plays, and each `next` the player reaches asks the
/// model for the following chapter.
class VnScreen extends ConsumerStatefulWidget {
  const VnScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<VnScreen> createState() => _VnScreenState();
}

class _VnScreenState extends ConsumerState<VnScreen> {
  /// Phones and tablets get their touches through [VnTouchForwarder]; the
  /// platform view's own forwarding scrambles multi-touch on Android.
  static final bool _forwardTouches =
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  late final Future<String> _page = _buildPage();
  late final ProviderSubscription<AsyncValue<VnState>> _sub;
  InAppWebViewController? _controller;
  bool _pageLoaded = false;
  // Set once the engine has let go of the GPU and the WebView is unmounted.
  bool _released = false;
  bool _leaving = false;
  // Bumped to replace a WebView whose page process died.
  int _webViewGeneration = 0;
  // WebView2 attaches to a window that already has a frame on screen.
  bool _mountNativeView = !Platform.isWindows;
  // The script the engine is playing; a longer one means a chapter landed.
  String? _playedScript;
  bool _setupStarted = false;
  bool _resumeChecked = false;
  // What was sent to the engine per cast id, so each set goes over once.
  final Map<String, String> _sentSprites = {};

  VnNotifier get _notifier => ref.read(vnProvider(widget.sessionId).notifier);

  String get _language =>
      context.locale.languageCode == 'en' ? 'English' : 'Russian';

  @override
  void initState() {
    super.initState();
    // The game plays in either orientation; the rest of the app keeps its lock.
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    if (!_mountNativeView) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _mountNativeView = true);
      });
    }
    _sub = ref.listenManual(
      vnProvider(widget.sessionId),
      (_, next) => _onState(next.value),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onState(_sub.read().value);
    });
  }

  @override
  void dispose() {
    _sub.close();
    // Already done by [_leave] unless the route was popped some other way
    // (the iOS edge swipe).
    if (!_released) {
      unawaited(
        SystemChrome.setPreferredOrientations(appDefaultOrientations()),
      );
    }
    super.dispose();
  }

  void _onState(VnState? s) {
    if (s == null || !mounted) return;
    if (s.doc.setup.containsKey(VnPass.characters) && s.drawing == null) {
      unawaited(_notifier.drawCast());
    }
    if (_pageLoaded) unawaited(_sendSprites(s));
    if (!s.doc.playable) {
      // Written once per visit on its own; after a failure only the retry
      // button starts it again.
      if (!_setupStarted && s.writing == null && s.error == null) {
        _setupStarted = true;
        unawaited(_notifier.writeSetup(language: _language));
      }
      return;
    }
    if (!s.ready || !_pageLoaded) return;
    if (_playedScript == null) {
      unawaited(_load(s));
    } else if (s.doc.script != _playedScript) {
      unawaited(_extend(s));
    }
  }

  /// Leaves the mode in an order that does not crash Android: the engine
  /// hands its WebGL context back, the WebView is unmounted while the route is
  /// still on screen, the orientation lock comes back, and only then the route
  /// pops. Destroying a WebView mid-frame while the screen rotates is what
  /// killed the app.
  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    final controller = _controller;
    if (controller != null && _playedScript != null) {
      try {
        final snapshot = await controller
            .evaluateJavascript(source: 'window.VN && VN.snapshot()')
            .timeout(const Duration(seconds: 1));
        if (snapshot is Map) {
          await _notifier.saveState(Map<String, dynamic>.from(snapshot));
        }
      } catch (e) {
        debugPrint('[VN3D] saving the place before leaving failed: $e');
      }
    }
    try {
      await controller
          ?.evaluateJavascript(source: 'window.VN && VN.stop();')
          .timeout(const Duration(seconds: 1));
    } catch (e) {
      debugPrint('[VN3D] stop before leaving failed: $e');
    }
    if (!mounted) return;
    setState(() {
      _released = true;
      _controller = null;
      _pageLoaded = false;
    });
    await SystemChrome.setPreferredOrientations(appDefaultOrientations());
    if (!mounted) return;
    final router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
    } else {
      router.go('/');
    }
  }

  /// The page process died (the GPU driver, memory pressure). Without a
  /// handler Android kills the whole app; with one the game just restarts
  /// from its last saved place.
  void _onPageProcessGone() {
    debugPrint('[VN3D] page process gone, rebuilding the WebView');
    if (!mounted || _released) return;
    setState(() {
      _controller = null;
      _pageLoaded = false;
      _playedScript = null;
      _sentSprites.clear();
      _webViewGeneration++;
    });
  }

  static Future<String> _buildPage() async {
    final parts = await Future.wait([
      rootBundle.loadString(kVnPageAsset),
      rootBundle.loadString(kVnThreeAsset),
      rootBundle.loadString(kVnEngineAsset),
    ]);
    return buildVnPage(shell: parts[0], three: parts[1], engine: parts[2]);
  }

  Future<void> _load(VnState s) async {
    final controller = _controller;
    if (controller == null) return;
    final script = s.doc.script;
    _playedScript = script;
    final snapshot = resumeSnapshot(s.doc, s.play);
    final lang = context.locale.languageCode == 'en' ? 'en' : 'ru';
    await controller.evaluateJavascript(
      source:
          'window.VN && VN.load(${jsonEncode(script)}, ${jsonEncode({'lang': lang, 'state': snapshot, 'parts': s.doc.chapters.length})});',
    );
    // A `next` reached before the app closed and never answered.
    if (!_resumeChecked) {
      _resumeChecked = true;
      final pending = snapshot == null ? null : VnPlayState(snapshot);
      if (pending?.pendingNext != null && s.writing == null) {
        unawaited(_continue(snapshot!));
      }
    }
  }

  Future<void> _extend(VnState s) async {
    final controller = _controller;
    if (controller == null) return;
    final script = s.doc.script;
    _playedScript = script;
    final opts = {
      'enter': s.doc.chapters.lastOrNull?.opensOn,
      'parts': s.doc.chapters.length,
    };
    await controller.evaluateJavascript(
      source:
          'window.VN && VN.extend(${jsonEncode(script)}, ${jsonEncode(opts)});',
    );
  }

  /// Hands the engine every character's sprites it does not have yet, as
  /// data URLs: the page is loaded from a string and cannot read app files.
  Future<void> _sendSprites(VnState s) async {
    final sprites = vnSpritesOf(s.session.sessionVars);
    if (sprites.isEmpty) return;
    final storage = await ref.read(imageStorageProvider.future);
    for (final e in sprites.entries) {
      final sig = jsonEncode(e.value);
      if (_sentSprites[e.key] == sig) continue;
      _sentSprites[e.key] = sig;
      final urls = <String, String>{};
      for (final f in e.value.entries) {
        final file = File(storage.absolutePath(f.value) ?? f.value);
        if (!await file.exists()) continue;
        urls[f.key] =
            'data:image/png;base64,${base64Encode(await file.readAsBytes())}';
      }
      final controller = _controller;
      if (urls.isEmpty || controller == null || !mounted) continue;
      await controller.evaluateJavascript(
        source: 'window.VN && VN.sprites(${jsonEncode({e.key: urls})});',
      );
    }
  }

  Future<void> _continue(Map<String, dynamic> snapshot) async {
    await _notifier.continueStory(language: _language, snapshot: snapshot);
  }

  void _retryContinue() {
    final raw = ref.read(vnProvider(widget.sessionId)).value?.play?.raw;
    if (raw != null) unawaited(_continue(raw));
  }

  void _onEngineEvent(List<dynamic> args) {
    if (args.isEmpty) return;
    final Map<String, dynamic> event;
    try {
      event = jsonDecode('${args.first}') as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (kDebugMode) debugPrint('[VN3D] ${event['type']}');
    final state = event['state'];
    switch (event['type']) {
      case 'state' when state is Map<String, dynamic>:
        unawaited(_notifier.saveState(state));
        // A choice made near the end of a part changes what comes next.
        if (_nearExits != null && _nearScene == state['scene']) {
          _writeAhead(state);
        } else {
          _nearExits = null;
        }
      case 'near' when state is Map<String, dynamic>:
        _nearScene = state['scene'] as String?;
        _nearExits = event['exits'] as List<dynamic>? ?? const [];
        _writeAhead(state);
      case 'next' when state is Map<String, dynamic>:
        _nearExits = null;
        unawaited(_continue(state));
    }
  }

  // The scene where the current part ends, while the player is in it.
  String? _nearScene;
  List<dynamic>? _nearExits;

  void _writeAhead(Map<String, dynamic> state) {
    unawaited(
      _notifier.writeAhead(
        language: _language,
        snapshot: {...state, 'exits': _nearExits},
      ),
    );
  }

  /// The journal, choices, inventory and chapters. Read live from the engine
  /// when it is running, else from the last saved place.
  Future<void> _openStatus() async {
    final s = ref.read(vnProvider(widget.sessionId)).value;
    if (s == null) return;
    Map<String, dynamic>? snapshot;
    final controller = _controller;
    if (controller != null && _playedScript != null) {
      try {
        final live = await controller
            .evaluateJavascript(source: 'window.VN && VN.snapshot()')
            .timeout(const Duration(seconds: 1));
        if (live is Map) snapshot = Map<String, dynamic>.from(live);
      } catch (_) {}
    }
    if (!mounted) return;
    await VnStatusSheet.show(
      context,
      doc: s.doc,
      play: snapshot == null ? s.play : VnPlayState(snapshot),
      persona: s.persona,
    );
  }

  Future<void> _sendInput(List<List<Object>> events) async {
    final controller = _controller;
    if (controller == null || !_pageLoaded) return;
    await controller.evaluateJavascript(
      source: 'window.VN && VN.input(${jsonEncode(events)});',
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(vnProvider(widget.sessionId));
    final s = async.value;
    return GlazeScaffold(
      title:
          s?.session.sessionVars['sessionName'] ??
          s?.doc.title ??
          'vn_untitled'.tr(),
      onBack: _leave,
      actions: [
        if (s != null &&
            s.ready &&
            s.doc.cast.isNotEmpty &&
            (s.drawsCast || vnSpritesOf(s.session.sessionVars).isNotEmpty))
          GlazeActionChip(
            icon: Icons.face_outlined,
            tooltip: 'vn_cast'.tr(),
            onTap: () =>
                unawaited(VnCastReview.show(context, widget.sessionId)),
          ),
        if (s != null && s.ready)
          GlazeActionChip(
            icon: Icons.menu_book_outlined,
            tooltip: 'vn_status'.tr(),
            onTap: () => unawaited(_openStatus()),
          ),
      ],
      body: switch (async) {
        AsyncValue(value: final VnState s) when s.ready => _buildGame(s),
        AsyncValue(value: final VnState s) => VnSetupView(
          state: s,
          onRetry: () => unawaited(_notifier.writeSetup(language: _language)),
        ),
        AsyncValue(error: final Object e) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: GlazeErrorBlock.fromError(e),
          ),
        ),
        _ => const Center(child: GlazeSpinner()),
      },
    );
  }

  Widget _buildGame(VnState s) {
    final writingNext = s.writing == VnPass.chapter;
    final failedNext =
        s.writing == null && s.error != null && s.play?.pendingNext != null;
    return Stack(
      children: [
        Positioned.fill(
          child: FutureBuilder<String>(
            future: _page,
            builder: (context, snapshot) {
              final html = snapshot.data;
              if (_released) return const SizedBox.shrink();
              if (html == null || !_mountNativeView) {
                return const Center(child: GlazeSpinner());
              }
              final webView = _buildWebView(html);
              return _forwardTouches
                  ? VnTouchForwarder(onEvents: _sendInput, child: webView)
                  : webView;
            },
          ),
        ),
        if (writingNext)
          VnGeneratingBadge(label: 'vn_writing_next'.tr())
        else if (failedNext)
          VnGeneratingBadge(
            label: vnErrorText(s.error!),
            onRetry: _retryContinue,
          )
        else if (s.drawing != null)
          VnGeneratingBadge(
            label: 'vn_drawing'.tr(
              args: [s.doc.cast[s.drawing]?.name ?? s.drawing!],
            ),
          )
        else if (s.artError != null)
          VnGeneratingBadge(
            label: 'vn_drawing_failed'.tr(args: [vnErrorText(s.artError!)]),
            onRetry: () => unawaited(_notifier.retryCast()),
          ),
      ],
    );
  }

  Widget _buildWebView(String html) {
    return InAppWebView(
      key: ValueKey<int>(_webViewGeneration),
      webViewEnvironment: chatWebViewEnvironment,
      initialData: InAppWebViewInitialData(data: html),
      // On desktop every pointer belongs to the game. Without this the
      // route's and the shell's drag recognizers win the arena and the page
      // only ever sees clicks.
      gestureRecognizers: _forwardTouches
          ? const <Factory<OneSequenceGestureRecognizer>>{}
          : {Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)},
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        supportZoom: false,
        disableContextMenu: true,
        mediaPlaybackRequiresUserGesture: true,
        isInspectable: kDebugMode,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
        controller.addJavaScriptHandler(
          handlerName: 'vn',
          callback: _onEngineEvent,
        );
      },
      onRenderProcessGone: (_, _) => _onPageProcessGone(),
      onWebContentProcessDidTerminate: (_) => _onPageProcessGone(),
      onLoadStop: (_, _) {
        _pageLoaded = true;
        _onState(ref.read(vnProvider(widget.sessionId)).value);
      },
    );
  }
}
