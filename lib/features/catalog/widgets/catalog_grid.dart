import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../chat/bridge/chat_webview_environment.dart';
import '../../settings/app_settings_provider.dart';
import '../catalog_models.dart';
import '../catalog_provider.dart';
import '../services/cf_challenge_service.dart';
import '../services/janitor_webview_proxy.dart';
import '../services/chub_provider.dart';
import '../services/datacat_provider.dart';
import '../services/janitor_provider.dart';
import 'catalog_card_grid.dart';
import 'catalog_controls.dart';
import 'catalog_detail_launcher.dart';
import 'janitor_login_sheet.dart';

/// Persisted flag so the JanitorAI login info sheet is shown at most once ever.
const _janitorInfoShownKey = 'janitor_login_info_shown';

/// In-memory guard so the (async) check fires at most once per app session,
/// regardless of how many times the catalog state updates.
bool _janitorInfoCheckStarted = false;

/// On the first successful JanitorAI catalog load, offer the user to sign in so
/// the full (authenticated) character set is available. Shown once per install,
/// and skipped entirely for users who are already logged in.
Future<void> _maybeShowJanitorLoginInfo(
  BuildContext context,
  WidgetRef ref,
) async {
  if (_janitorInfoCheckStarted) return;
  _janitorInfoCheckStarted = true;

  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_janitorInfoShownKey) ?? false) return;

  final loggedIn = await JanitorWebViewProxy.instance.isLoggedIn();
  // Mark as shown regardless so it never reappears.
  await prefs.setBool(_janitorInfoShownKey, true);
  if (loggedIn || !context.mounted) return;

  await GlazeBottomSheet.show<void>(
    context,
    // Cannot be dragged or tapped-out to dismiss; the content widget also blocks
    // the back button for the first 5s so it isn't closed by accident.
    locked: true,
    isDismissible: false,
    child: _JanitorLoginInfoContent(
      onLogin: () async {
        Navigator.of(context, rootNavigator: true).pop();
        // The login sheet itself refreshes the catalog on a successful sign-in.
        await showJanitorLoginSheet(context);
      },
    ),
  );
}

/// Body of the JanitorAI login info sheet. Stays locked (back button blocked,
/// login button disabled with a countdown) for [_lockSeconds] so it can't be
/// dismissed accidentally right as it appears.
class _JanitorLoginInfoContent extends StatefulWidget {
  final Future<void> Function() onLogin;

  const _JanitorLoginInfoContent({required this.onLogin});

  @override
  State<_JanitorLoginInfoContent> createState() =>
      _JanitorLoginInfoContentState();
}

class _JanitorLoginInfoContentState extends State<_JanitorLoginInfoContent> {
  static const _lockSeconds = 5;
  int _remaining = _lockSeconds;
  Timer? _timer;

  bool get _locked => _remaining > 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() {
        _remaining--;
        if (_remaining <= 0) t.cancel();
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = 'janitor_login_button'.tr();
    return PopScope(
      canPop: !_locked,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          children: [
            Icon(
              Icons.person_outline_rounded,
              size: 64,
              color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'janitor_login_info_desc'.tr(),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                color: context.cs.onSurface,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _locked ? null : () => widget.onLogin(),
                child: Text(_locked ? '$label ($_remaining)' : label),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CatalogGrid extends ConsumerWidget {
  final double topPadding;
  final double bottomPadding;

  const CatalogGrid({
    super.key,
    this.topPadding = 0,
    this.bottomPadding = 16,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(catalogProvider);
    final notifier = ref.read(catalogProvider.notifier);

    ref.listen<CatalogState>(catalogProvider, (prev, next) {
      if (next.activeProvider == CatalogProvider.janitor &&
          !next.loading &&
          next.error == null &&
          next.results.isNotEmpty) {
        _maybeShowJanitorLoginInfo(context, ref);
      }
    });

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.extentAfter < 600 &&
            !state.loading &&
            state.hasMore) {
          notifier.loadMore();
        }
        return false;
      },
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: CustomScrollView(
        slivers: [
          if (topPadding > 0)
            SliverToBoxAdapter(child: SizedBox(height: topPadding)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: CatalogControls(state: state, notifier: notifier),
            ),
          ),
          if (state.filters.nsfw ||
              state.filters.tagIds.isNotEmpty ||
              state.filters.tagNames.isNotEmpty)
            SliverToBoxAdapter(
              child: _ActiveTagsRow(state: state, notifier: notifier),
            ),
          if (state.activeProvider == CatalogProvider.janitor)
            const SliverToBoxAdapter(child: _JanitorProxyLifecycle()),
          if (state.activeProvider == CatalogProvider.janitor)
            SliverToBoxAdapter(
              child: ValueListenableBuilder<bool>(
                valueListenable: CfChallengeService.instance.isPending,
                builder: (context, pending, _) {
                  if (!pending) return const SizedBox.shrink();
                  return SizedBox(
                    height: MediaQuery.of(context).size.height * 0.72,
                    child: const _CfChallengeWebView(),
                  );
                },
              ),
            ),
          if (state.error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: Text(
                    state.error!,
                    style: TextStyle(
                      color: context.cs.onSurfaceVariant,
                      fontSize: 13,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          if (state.activeProvider != CatalogProvider.janny && state.activeProvider != CatalogProvider.chub)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                child: state.loading
                    ? const SizedBox(height: 11)
                    : Text(
                        '${state.total} result${state.total == 1 ? '' : 's'}',
                        style: TextStyle(
                          fontSize: 11,
                          color: context.cs.onSurfaceVariant,
                        ),
                      ),
              ),
            )
          else
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
          if (state.results.isEmpty && !state.loading && state.page > 1)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 80),
                child: Center(
                  child: Text(
                    state.error != null ? '' : 'catalog_empty'.tr(),
                    style: TextStyle(
                      color: context.cs.onSurfaceVariant,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            )
          else
            CatalogCardGridSliver(
              items: state.results,
              padding: EdgeInsets.fromLTRB(16, 0, 16, bottomPadding),
              onTap: (item) =>
                  _openDetail(context, ref, item, state.activeProvider),
            ),
          if (state.loading)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: context.cs.primary,
                    ),
                  ),
                ),
              ),
            ),
          if (!state.hasMore && state.results.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Center(
                  child: Text(
                    'End of results',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      ),
    );
  }

  Future<void> _openDetail(
    BuildContext context,
    WidgetRef ref,
    CatalogItem item,
    CatalogProvider provider,
  ) async {
    final importedCharId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CatalogDetailLauncher(item: item, provider: provider),
    );
    if (!context.mounted || importedCharId == null || importedCharId.isEmpty) {
      return;
    }

    GlazeToast.show(context, 'Imported ${item.name}');

    // Only navigate to the freshly imported character card when the user has
    // opted in (default on). Otherwise stay on the catalog so they can keep
    // browsing/importing.
    final openCard =
        ref.read(appSettingsProvider).value?.openCardAfterImport ?? true;
    if (!openCard) return;
    context.go('/characters?open=${Uri.encodeQueryComponent(importedCharId)}');
  }
}

class _CfChallengeWebView extends StatefulWidget {
  const _CfChallengeWebView();

  @override
  State<_CfChallengeWebView> createState() => _CfChallengeWebViewState();
}

class _CfChallengeWebViewState extends State<_CfChallengeWebView> {
  Timer? _poll;

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _onCreated(InAppWebViewController controller) async {
    debugPrint('[CF] WebView created');

    // Read and store the native WebView UA before any CF interaction.
    try {
      final ua = await controller.evaluateJavascript(source: 'navigator.userAgent');
      if (ua is String && ua.isNotEmpty) {
        CfChallengeService.instance.setWebViewUA(ua);
        debugPrint('[CF] WebView UA: $ua');
      }
    } catch (e) {
      debugPrint('[CF] UA read error: $e');
    }

    // Wipe the entire WebView cookie store. Targeted deletions fail because
    // cf_clearance uses Domain=.janitorai.com and all attribute-matching tricks
    // leave the cookie intact. A clean store forces CF to issue a fresh cookie
    // bound to the current UA when we navigate to janitorai.com below.
    //
    // The Supabase account session lives in `sb-<ref>-auth-token(.N)` cookies in
    // the same store, so a blanket wipe would silently log the user out every
    // time CF re-challenges (the "creds lost after a while" bug). Capture those
    // cookies first and restore them after the wipe so only CF's cookies are
    // actually reset.
    try {
      final origin = WebUri('https://janitorai.com');
      final before = await CookieManager.instance().getCookies(url: origin);
      debugPrint('[CF] Cookies before wipe: ${before.map((c) => c.name).join(', ')}');
      final authCookies = before
          .where((c) => c.name.startsWith('sb-') && c.name.contains('-auth-token'))
          .toList();
      await CookieManager.instance().deleteAllCookies();
      for (final c in authCookies) {
        try {
          await CookieManager.instance().setCookie(
            url: origin,
            name: c.name,
            value: c.value.toString(),
            domain: c.domain,
            path: c.path ?? '/',
            expiresDate: c.expiresDate,
            isSecure: c.isSecure,
            isHttpOnly: c.isHttpOnly,
            sameSite: c.sameSite,
          );
        } catch (e) {
          debugPrint('[CF] auth cookie restore error (${c.name}): $e');
        }
      }
      final after = await CookieManager.instance().getCookies(url: origin);
      debugPrint('[CF] Cookies after wipe: ${after.map((c) => c.name).join(', ')} '
          '(${after.length} left, ${authCookies.length} auth restored)');
    } catch (e) {
      debugPrint('[CF] Cookie wipe error: $e');
    }

    // Navigate to janitorai.com now that the cookie store is clean.
    // The WebView was started at about:blank to prevent a race where the page
    // fires onLoadStart before we could delete the stale cf_clearance.
    debugPrint('[CF] Navigating to janitorai.com with clean cookie store');
    await controller.loadUrl(
      urlRequest: URLRequest(url: WebUri('https://janitorai.com')),
    );

    int pollCount = 0;
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      if (!mounted) return;
      pollCount++;
      try {
        final cookies = await CookieManager.instance()
            .getCookies(url: WebUri('https://janitorai.com'));
        final names = cookies.map((c) => c.name).join(', ');
        if (pollCount % 6 == 1) {
          debugPrint('[CF] Poll #$pollCount cookies: $names');
        }
        final cf = cookies.where((c) => c.name == 'cf_clearance').firstOrNull;
        final value = cf?.value?.toString();
        if (value != null && value.isNotEmpty) {
          debugPrint('[CF] cf_clearance found on poll #$pollCount: ${value.substring(0, value.length.clamp(0, 40))}...');
          _poll?.cancel();
          CfChallengeService.instance.completeChallengeWith(value);
        }
      } catch (e) {
        debugPrint('[CF] Poll error: $e');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return InAppWebView(
      // Start at about:blank so _onCreated can wipe stale cookies before
      // the CF challenge request goes out (races with initialUrlRequest).
      initialUrlRequest: URLRequest(url: WebUri('about:blank')),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        cacheEnabled: true,
        thirdPartyCookiesEnabled: true,
        isInspectable: false,
        useHybridComposition: true,
        // Mint cf_clearance under the same Edg-stripped, version-aligned UA the
        // proxy/login WebViews use, so the catalog's in-page fetches stay
        // consistent. Null on mobile → native UA kept.
        userAgent: janitorWebViewUserAgent,
      ),
      webViewEnvironment: defaultTargetPlatform == TargetPlatform.windows
          ? chatWebViewEnvironment
          : null,
      onWebViewCreated: _onCreated,
      onLoadStart: (controller, url) {
        debugPrint('[CF] onLoadStart: $url');
      },
      onLoadStop: (controller, url) async {
        debugPrint('[CF] onLoadStop: $url');
        try {
          final cookies = await CookieManager.instance()
              .getCookies(url: WebUri('https://janitorai.com'));
          debugPrint('[CF] Cookies at onLoadStop: ${cookies.map((c) => c.name).join(', ')}');
        } catch (_) {}
      },
      onReceivedHttpError: (controller, request, response) {
        debugPrint('[CF] HTTP error ${response.statusCode} on ${request.url}');
      },
      onReceivedError: (controller, request, error) {
        debugPrint('[CF] Load error: ${error.description} on ${request.url}');
      },
    );
  }
}

/// Non-visual widget whose lifetime mirrors the JanitorAI catalog being the
/// foreground view. It is mounted only while JanitorAI is the active provider,
/// and uses [TickerMode] (disabled by the shell's `FadeBranchContainer` for
/// background bottom-nav branches) plus app lifecycle to tell the
/// [JanitorWebViewProxy] when to keep its offscreen WebView alive vs. tear it
/// down. The WebView never lingers in the background.
class _JanitorProxyLifecycle extends StatefulWidget {
  const _JanitorProxyLifecycle();

  @override
  State<_JanitorProxyLifecycle> createState() => _JanitorProxyLifecycleState();
}

class _JanitorProxyLifecycleState extends State<_JanitorProxyLifecycle>
    with WidgetsBindingObserver {
  bool _appResumed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Registers a dependency on TickerMode → didChangeDependencies re-fires when
    // the branch goes off/on screen.
    TickerMode.valuesOf(context);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    final visible =
        mounted && TickerMode.valuesOf(context).enabled && _appResumed;
    JanitorWebViewProxy.instance.setActive(visible);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    JanitorWebViewProxy.instance.setActive(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _ActiveTagsRow extends StatelessWidget {
  final CatalogState state;
  final CatalogNotifier notifier;

  const _ActiveTagsRow({required this.state, required this.notifier});

  List<String> _getActiveFilters() {
    final names = <String>[];
    if (state.filters.nsfw) {
      names.add('NSFW');
    }

    final seen = <String>{};
    for (final tagName in state.filters.tagNames) {
      if (seen.add(tagName)) {
        names.add(tagName);
      }
    }

    if (state.filters.tagIds.isNotEmpty) {
      List<CatalogTag> allTags = [];
      if (state.activeProvider == CatalogProvider.chub) {
        allTags = getCachedChubTags();
      } else if (state.activeProvider == CatalogProvider.datacat) {
        allTags = getCachedDatacatTags();
      } else {
        allTags = getCachedJanitorTags();
      }

      for (final tag in allTags) {
        if (tag.id != null &&
            state.filters.tagIds.contains(tag.id) &&
            seen.add(tag.name)) {
          names.add(tag.name);
        }
      }
    }

    return names;
  }

  void _removeFilter(String name) {
    if (name == 'NSFW') {
      notifier.setFilters(state.filters.copyWith(nsfw: false));
      return;
    }

    List<CatalogTag> allTags = [];
    if (state.activeProvider == CatalogProvider.chub) {
      allTags = getCachedChubTags();
    } else if (state.activeProvider == CatalogProvider.datacat) {
      allTags = getCachedDatacatTags();
    } else {
      allTags = getCachedJanitorTags();
    }

    final tag = allTags.firstWhere((t) => t.name == name, orElse: () => CatalogTag(name: name));

    final newNames = state.filters.tagNames.toList();
    final newIds = state.filters.tagIds.toList();

    if (tag.id != null) {
      newIds.remove(tag.id);
    } else {
      newNames.remove(name);
    }

    notifier.setFilters(state.filters.copyWith(
      tagNames: newNames,
      tagIds: newIds,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final names = _getActiveFilters();
    if (names.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: SizedBox(
        height: 28,
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          scrollDirection: Axis.horizontal,
          itemCount: names.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final name = names[index];
            final isNsfw = name.toUpperCase() == 'NSFW';
            return GestureDetector(
              onTap: () => _removeFilter(name),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: isNsfw
                      ? const Color(0x33FF4444)
                      : context.cs.primary.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isNsfw
                        ? const Color(0x4DFF4444)
                        : context.cs.primary,
                  ),
                ),
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 12,
                        color: isNsfw
                            ? const Color(0xFFFF4444)
                            : Colors.white,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.close,
                      size: 10,
                      color: isNsfw
                          ? const Color(0xFFFF4444)
                          : Colors.white,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

