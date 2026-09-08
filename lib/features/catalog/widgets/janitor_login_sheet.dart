import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../chat/bridge/chat_webview_environment.dart';
import '../catalog_provider.dart';
import '../janitor_account_provider.dart';
import '../services/janitor_webview_proxy.dart';

/// Entry point for the menu's "JanitorAI Account" item. When a session already
/// exists, shows a small log-out / cancel sheet instead of the login WebView;
/// otherwise opens the WebView so the user can sign in.
Future<void> openJanitorAccountSheet(BuildContext context, WidgetRef ref) async {
  if (!ref.read(janitorAccountProvider).isLoggedIn) {
    await showJanitorLoginSheet(context);
    return;
  }
  await GlazeBottomSheet.show<void>(
    context,
    title: 'janitor_login_menu'.tr(),
    items: [
      BottomSheetItem(
        label: 'janitor_auth_logout'.tr(),
        icon: Icons.logout_rounded,
        isDestructive: true,
        onTap: () async {
          Navigator.of(context, rootNavigator: true).pop();
          // Clear the account state first so the menu reflects the logout
          // immediately — the WebView/cookie teardown below can take many
          // seconds (page reload + CF clearance wait) and must not block it.
          await ref.read(janitorAccountProvider.notifier).setUserName(null);
          await JanitorWebViewProxy.instance.logout();
          // Drop the stale (authenticated) catalog results so reopening the
          // catalog shows anonymous content without needing an app restart.
          await ref.read(catalogProvider.notifier).search(reset: true);
        },
      ),
      BottomSheetItem(
        label: 'btn_cancel'.tr(),
        icon: Icons.close_rounded,
        onTap: () => Navigator.of(context, rootNavigator: true).pop(),
      ),
    ],
  );
}

/// Opens the JanitorAI login WebView as a modal sheet. After it closes the
/// account session (if any) is active for catalog requests. On a successful
/// sign-in the sheet refreshes the catalog itself, so callers don't need to.
Future<void> showJanitorLoginSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const JanitorLoginSheet(),
  );
}

/// Full-height sheet hosting a visible WebView for logging into a JanitorAI
/// account. The WebView shares its cookie jar and `localStorage` with the
/// headless [JanitorWebViewProxy] (same origin, same app storage), so once the
/// user signs in here the account session is automatically used for catalog
/// requests. No cookies are wiped — unlike the CF challenge WebView.
class JanitorLoginSheet extends ConsumerStatefulWidget {
  const JanitorLoginSheet({super.key});

  static const _loginUrl = 'https://janitorai.com/login';

  @override
  ConsumerState<JanitorLoginSheet> createState() => _JanitorLoginSheetState();
}

class _JanitorLoginSheetState extends ConsumerState<JanitorLoginSheet> {
  InAppWebViewController? _controller;
  bool _busy = false;

  /// Guards against re-entrant close attempts: once a successful login lands we
  /// pop exactly once, even if several navigation callbacks fire in a row.
  bool _closing = false;

  Future<void> _logout() async {
    setState(() => _busy = true);
    await ref.read(janitorAccountProvider.notifier).setUserName(null);
    await JanitorWebViewProxy.instance.logout();
    await ref.read(catalogProvider.notifier).search(reset: true);
    await _controller?.loadUrl(
      urlRequest: URLRequest(url: WebUri(JanitorLoginSheet._loginUrl)),
    );
    if (mounted) setState(() => _busy = false);
  }

  /// Called on every navigation. JanitorAI redirects away from `/login` (to the
  /// site root) once sign-in succeeds — and the screenshot's success toast lands
  /// on that root page. So whenever we leave the login page for a janitorai.com
  /// URL we verify a session token was actually persisted (creds saved) and, if
  /// so, auto-close the sheet. The token check also prevents false closes when
  /// the user merely navigates to e.g. the sign-up page.
  Future<void> _maybeFinishLogin(WebUri? url) async {
    if (_closing || url == null) return;
    if (!url.host.endsWith('janitorai.com')) return;
    if (url.path.startsWith('/login')) return;
    final controller = _controller;
    if (controller == null) return;
    final loggedIn = await JanitorWebViewProxy.hasSessionToken(controller);
    if (!loggedIn || _closing || !mounted) return;
    _closing = true;
    // The page is signed in here — grab the profile name (same request the site
    // front-end makes) and persist it for the menu hint before the sheet closes.
    final userName = await JanitorWebViewProxy.fetchUserName(controller);
    if (userName != null) {
      await ref.read(janitorAccountProvider.notifier).setUserName(userName);
    }
    // Drop the anonymous catalog results so the now-authenticated character set
    // is fetched — mirrors the logout path. Fires regardless of which entry
    // point (menu or catalog) opened this sheet.
    await ref.read(catalogProvider.notifier).search(reset: true);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.92;
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: context.cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _Header(
            busy: _busy,
            onClose: () => Navigator.of(context).pop(),
            onLogout: _busy ? null : _logout,
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest:
                  URLRequest(url: WebUri(JanitorLoginSheet._loginUrl)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                cacheEnabled: true,
                thirdPartyCookiesEnabled: true,
                isInspectable: false,
                useHybridComposition: true,
                // Drop WebView2's native `Edg/…` token (rejected by Google
                // sign-in) while keeping the Chrome version aligned with the
                // client hints CF validates. Null on mobile → native UA kept.
                // See [janitorWebViewUserAgent].
                userAgent: janitorWebViewUserAgent,
              ),
              webViewEnvironment:
                  defaultTargetPlatform == TargetPlatform.windows
                      ? chatWebViewEnvironment
                      : null,
              // Claim vertical (and horizontal) drags so the WebView scrolls
              // instead of the enclosing modal sheet eating the gesture.
              gestureRecognizers: {
                Factory<VerticalDragGestureRecognizer>(
                  () => VerticalDragGestureRecognizer(),
                ),
                Factory<HorizontalDragGestureRecognizer>(
                  () => HorizontalDragGestureRecognizer(),
                ),
              },
              onWebViewCreated: (c) => _controller = c,
              // Full page loads / redirects (e.g. the post-login bounce to the
              // site root) — confirm the session and close on success.
              onLoadStop: (_, url) => _maybeFinishLogin(url),
              // JanitorAI is a SPA: a successful login can route client-side
              // without a full reload, so watch history pushes too.
              onUpdateVisitedHistory: (_, url, _) => _maybeFinishLogin(url),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final bool busy;
  final VoidCallback onClose;
  final VoidCallback? onLogout;

  const _Header({
    required this.busy,
    required this.onClose,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: onClose,
            color: context.cs.onSurface,
          ),
          Expanded(
            child: Text(
              'janitor_auth_title'.tr(),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: context.cs.onSurface,
              ),
            ),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            TextButton(
              onPressed: onLogout,
              child: Text(
                'janitor_auth_logout'.tr(),
                style: TextStyle(color: context.cs.error),
              ),
            ),
        ],
      ),
    );
  }
}
