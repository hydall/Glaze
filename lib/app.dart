import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:glaze_flutter/core/llm/prompt_worker.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';
import 'core/navigation/router.dart';
import 'core/navigation/rewrite_review_navigation.dart';
import 'core/services/deep_link_service.dart';
import 'core/services/generation_notification_service.dart';
import 'features/chat/bridge/chat_webview_environment.dart';
import 'core/state/active_selection_provider.dart';
import 'core/state/character_provider.dart';
import 'core/state/db_provider.dart';
import 'core/state/lorebook_provider.dart';
import 'core/state/lorebook_embedding_provider.dart';
import 'core/services/preset_seeder.dart';
import 'features/chat_history/chat_history_provider.dart';
import 'features/settings/api_list_provider.dart';
import 'features/settings/app_settings_provider.dart';
import 'shared/theme/theme_font_provider.dart';
import 'core/services/onboarding_service.dart';
import 'core/services/update_check_coordinator.dart';
import 'features/cloud_sync/sync_provider.dart';
import 'features/cloud_sync/sync_models.dart';

import 'shared/theme/app_theme.dart';
import 'shared/theme/theme_preset.dart';
import 'shared/theme/theme_provider.dart';

import 'features/chat/widgets/chat_webview_preload.dart';
import 'features/chat/widgets/lorebook_vector_search_diagnostic_listener.dart';
import 'shared/widgets/app_launch_splash.dart';
import 'shared/widgets/build_watermark.dart';
import 'shared/widgets/glaze_toast.dart' show toastOverlayKey;
import 'shared/widgets/stretch_overscroll.dart';

class GlazeApp extends ConsumerStatefulWidget {
  final VoidCallback? restart;

  /// When true, skips the async startup hook chain (tokenizer download,
  /// prompt worker init, notifications, deep links) and renders the app
  /// shell immediately. Used by widget tests that need the route tree
  /// without waiting for network-bound initialization.
  final bool skipStartup;

  const GlazeApp({super.key, this.restart, this.skipStartup = false});

  static VoidCallback? _restart;

  static void restartApp() => _restart?.call();

  @override
  ConsumerState<GlazeApp> createState() => _GlazeAppState();
}

class _GlazeAppState extends ConsumerState<GlazeApp>
    with WidgetsBindingObserver {
  StreamSubscription<NotificationNavigationData>? _navSub;
  final List<ProviderSubscription> _warmSubs = [];
  late bool _startupReady;
  bool _startupHooksAttached = false;

  @override
  void initState() {
    super.initState();
    _startupReady =
        widget.skipStartup || const bool.fromEnvironment('FLUTTER_TEST');
    GlazeApp._restart = widget.restart;
    WidgetsBinding.instance.addObserver(this);
    ref.read(llmRequestCaptureInstallationProvider);
    _initInBackground(loadActiveSelections(ref), 'active selections');
    _initInBackground(loadLorebookActivations(ref), 'lorebook activations');
    _initInBackground(loadLorebookSettings(ref), 'lorebook settings');
    _initInBackground(seedDefaultPresets(ref), 'default preset seeding');
    _initInBackground(seedFeaturedPresets(ref), 'featured preset seeding');
    if (!widget.skipStartup) {
      _warmInitialListProviders();
    }
    if (_startupReady) return;
    unawaited(_initializeStartup());
  }

  /// Runs a fire-and-forget init task and keeps its failure contained.
  ///
  /// These are started unawaited from [initState], so without a handler any
  /// failure becomes an unhandled async error — and one that can outlive the
  /// widget: in widget tests the task is still in flight when teardown closes
  /// the database, and the late "Can't re-open a database after closing it"
  /// then lands on whichever test happens to be running.
  ///
  /// None of these tasks is needed for the first frame — they hydrate state
  /// that the UI already renders empty — so a failure is logged and dropped
  /// rather than escalated.
  void _initInBackground(Future<void> work, String what) {
    unawaited(
      work.catchError((Object e) {
        debugPrint('Glaze init: $what failed — $e');
      }),
    );
  }

  /// Starts the DB-backed providers behind the initial routes now, concurrently
  /// with the splash, so their async `build()` finishes before the route tree
  /// mounts — the list renders populated instead of flashing a spinner. Holding
  /// the subscriptions keeps the providers alive (none is `keepAlive`); they
  /// are closed in [dispose].
  ///
  /// `apiListProvider` is warmed for a different reason: its async `build()`
  /// also restores the persisted active API config from prefs. Without this,
  /// the provider stays cold/auto-disposed until the first send, where the
  /// synchronous `activeApiConfigProvider` read sees a still-loading list and
  /// falsely reports "no API selected" on every fresh launch.
  void _warmInitialListProviders() {
    _warmSubs.add(ref.listenManual(chatHistoryProvider, (_, _) {}));
    _warmSubs.add(
      ref.listenManual(
        infiniteCharactersProvider(kDefaultInfiniteCharactersKey),
        (_, _) {},
      ),
    );
    _warmSubs.add(ref.listenManual(apiListProvider, (_, _) {}));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _navSub?.cancel();
    for (final sub in _warmSubs) {
      sub.close();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_startupReady) return;
    GenerationNotificationService.instance.updateLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(sessionLorebookEmbeddingWorkerProvider).drain());
      final service = ref.read(syncServiceProvider).value;
      if (service != null && service.status != SyncStatus.syncing) {
        ref.read(syncStatusProvider.notifier).state = service.status;
      }
    }
  }

  Future<void> _initializeStartup() async {
    try {
      await _runStartupStep('dotenv', () => dotenv.load(fileName: '.env'));
      await _runStartupStep('tokenizer', preloadO200kBase);
      await _runStartupStep('prompt worker', PromptWorker.ensureInitialized);
      await _runStartupStep(
        'chat webview environment',
        initChatWebViewEnvironment,
      );
      await _runStartupStep(
        'generation notifications',
        GenerationNotificationService.instance.init,
      );
      await _runStartupStep('deep links', DeepLinkService.instance.init);
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'startup',
          context: ErrorDescription('startup initialization failed'),
        ),
      );
    }
    if (!mounted) return;
    setState(() => _startupReady = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _attachStartupHooks();
    });
  }

  Future<void> _runStartupStep(
    String name,
    Future<void> Function() step,
  ) async {
    try {
      await step();
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'startup',
          context: ErrorDescription('$name initialization failed'),
        ),
      );
    }
  }

  void _attachStartupHooks() {
    if (_startupHooksAttached) return;
    _startupHooksAttached = true;
    checkAndShowOnboarding(context);
    _listenNotificationNavigation();
    _handleColdStartNotification();
    unawaited(
      ref.read(sessionLorebookEmbeddingWorkerProvider).recoverAndDrain(),
    );
    unawaited(checkAndShowUpdateOnStartup());
  }

  void _listenNotificationNavigation() {
    _navSub = GenerationNotificationService.instance.navigationStream.listen((
      data,
    ) {
      if (mounted) _openChatFromNotification(data);
    });
  }

  void _handleColdStartNotification() {
    final data = GenerationNotificationService.instance
        .consumePendingNotificationData();
    if (data != null && mounted) {
      _openChatFromNotification(data);
    }
  }

  /// Opens the chat for a tapped notification, carrying the target message id
  /// so the chat can scroll to and flash it (mirrors Vue's openChat msgId).
  void _openChatFromNotification(NotificationNavigationData data) {
    final msgId = data.msgId;
    final uri = Uri(
      path: '/chat/${data.charId}',
      queryParameters: (msgId != null && msgId.isNotEmpty)
          ? {'msg': msgId}
          : null,
    );
    context.push(uri.toString());
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<AppSettings>>(appSettingsProvider, (prev, next) {
      final lang = next.value?.language;
      if (lang != null && lang != prev?.value?.language) {
        context.setLocale(
          Locale(supportedAppLanguages.contains(lang) ? lang : 'en'),
        );
      }
    });

    ref.listen<RewriteReviewNavigationIntent?>(
      rewriteReviewNavigationIntentProvider,
      (previous, next) {
        if (next == null || next.sequence == previous?.sequence) return;
        final authority =
            GenerationNotificationService.instance.activeChatContext;
        if (authority?.charId != next.charId ||
            authority?.sessionId != next.sessionId ||
            authority?.revision != next.authorityRevision) {
          return;
        }
        ref.read(routerProvider).push(next.location);
      },
    );

    final router = ref.watch(routerProvider);
    final themeSettings = ref.watch(themeProvider);
    final uiFont = ref.watch(uiFontFamilyProvider).value;
    final preset = themeSettings.activePreset;
    final mode = preset.themeMode == 'light'
        ? ThemeMode.light
        : preset.themeMode == 'dark'
        ? ThemeMode.dark
        : themeSettings.mode;
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        // Material You dynamic colors are sourced from the system only on
        // Android; elsewhere the theme falls back to a seeded tonal palette.
        final useDynamic = defaultTargetPlatform == TargetPlatform.android;
        final lightScheme = preset.isMaterialYou && useDynamic
            ? lightDynamic
            : null;
        final darkScheme = preset.isMaterialYou && useDynamic
            ? darkDynamic
            : null;
        return _buildApp(
          context,
          router: router,
          preset: preset,
          uiFont: uiFont,
          mode: mode,
          lightScheme: lightScheme,
          darkScheme: darkScheme,
        );
      },
    );
  }

  Widget _buildApp(
    BuildContext context, {
    required GoRouter router,
    required ThemePreset preset,
    required String? uiFont,
    required ThemeMode mode,
    required ColorScheme? lightScheme,
    required ColorScheme? darkScheme,
  }) {
    return MaterialApp.router(
      title: 'Glaze',
      // Stretch overscroll without an offscreen layer, so glass surfaces
      // inside scroll views keep their backdrop blur during the stretch.
      scrollBehavior: const GlazeScrollBehavior(),
      theme: AppTheme.light(
        preset,
        fontFamily: uiFont,
        dynamicScheme: lightScheme,
      ),
      darkTheme: AppTheme.dark(
        preset,
        fontFamily: uiFont,
        dynamicScheme: darkScheme,
      ),
      themeMode: mode,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      builder: (context, child) {
        final appChild = _startupReady
            ? LorebookVectorSearchDiagnosticListener(
                child: ChatWebViewPreloader(
                  child: Overlay(
                    key: toastOverlayKey,
                    initialEntries: [OverlayEntry(builder: (_) => child!)],
                  ),
                ),
              )
            : const SizedBox.expand();
        return AppLaunchSplash(
          isReady: _startupReady,
          child: Stack(
            children: [
              Positioned.fill(child: appChild),
              const BuildWatermark(),
            ],
          ),
        );
      },
    );
  }
}
