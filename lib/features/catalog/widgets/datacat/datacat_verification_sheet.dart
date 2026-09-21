import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glaze_action_button.dart';
import '../../../../shared/widgets/glaze_error_block.dart';
import '../../../../shared/widgets/glaze_spinner.dart';
import '../../../../shared/widgets/sheet_view.dart';
import '../../../chat/bridge/chat_webview_environment.dart';
import '../../services/datacat/datacat_models.dart';
import '../../services/datacat/datacat_verification.dart';

/// A transfer lease for [characterId], asking the user to verify if needed.
///
/// The entry point every protected download goes through. It answers from the
/// stored lease when one is still spendable — a batch import verifies once and
/// then runs — and only puts a challenge in front of the user when there is
/// nothing left to spend. Returns null when the user closed the sheet.
Future<String?> ensureDatacatLease(
  BuildContext context, {
  required String characterId,
}) async {
  final existing = DatacatLeaseStore.instance.leaseFor(characterId);
  if (existing != null) return existing;

  if (!context.mounted) return null;
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    // No useSafeArea: SheetView pads itself for the status bar as it grows to
    // fullscreen, so the route's own inset would be counted twice and leave
    // the header stranded a status bar's height below the sheet's top edge.
    backgroundColor: Colors.transparent,
    builder: (_) => const DatacatVerificationSheet(),
  );
}

/// Runs DataCat's hosted human-verification challenge and hands back the lease.
///
/// The challenge is a Cloudflare Turnstile page DataCat hosts itself, and the
/// supported way through it is to load that page — the app never handles the
/// site key or the widget. Two things run side by side while it is open: the
/// WebView the user interacts with, and the token exchange, which is what
/// actually decides the challenge was solved. Watching the exchange rather than
/// the page's URL means a hosted page that changes its success screen cannot
/// strand a verification that already worked.
class DatacatVerificationSheet extends StatefulWidget {
  const DatacatVerificationSheet({super.key});

  @override
  State<DatacatVerificationSheet> createState() =>
      _DatacatVerificationSheetState();
}

class _DatacatVerificationSheetState extends State<DatacatVerificationSheet> {
  DatacatDeviceFlow? _flow;
  Object? _error;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    // Stops the polling loop rather than leaving it to run out the challenge's
    // ten minutes against a sheet nobody is looking at.
    _closed = true;
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final flow = await startDatacatVerification();
      if (!mounted) return;
      setState(() => _flow = flow);

      final lease = await awaitDatacatLease(
        flow,
        isCancelled: () => _closed,
      );
      if (!mounted || _closed) return;
      Navigator.of(context).pop(lease);
    } catch (e) {
      if (!mounted || _closed) return;
      setState(() => _error = e);
    }
  }

  void _retry() {
    setState(() {
      _error = null;
      _flow = null;
    });
    _start();
  }

  @override
  Widget build(BuildContext context) {
    return SheetView(
      title: 'datacat_verify_title'.tr(),
      showBack: true,
      onBack: () => Navigator.of(context).pop(),
      startExpanded: true,
      // Built through a Builder so the body reads the header inset SheetView
      // publishes as MediaQuery.padding.top. Passing `context` from here reads
      // the padding *above* the sheet instead, which is zero, and the content
      // was drawn under the title row.
      body: Builder(builder: _buildBody),
    );
  }

  Widget _buildBody(BuildContext context) {
    final error = _error;
    if (error != null) {
      return Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.paddingOf(context).top + 16,
          16,
          24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GlazeErrorBlock.fromError(error),
            const SizedBox(height: 16),
            GlazeActionButton(
              icon: Icons.refresh_rounded,
              label: 'btn_retry'.tr(),
              tone: GlazeActionTone.primary,
              onTap: _retry,
            ),
          ],
        ),
      );
    }

    final flow = _flow;
    if (flow == null) {
      return Padding(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GlazeSpinner(color: context.cs.primary),
            const SizedBox(height: 12),
            Text(
              'datacat_verify_starting'.tr(),
              style: TextStyle(
                fontSize: 12,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              'datacat_verify_hint'.tr(),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(flow.uri)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                thirdPartyCookiesEnabled: true,
                isInspectable: false,
                useHybridComposition: true,
                // WebView2 reports an `Edg/…` token that some challenge hosts
                // treat as an unknown browser; the shared override keeps the
                // Chrome version the client hints are validated against. Null
                // on mobile, where the native UA is already a real one.
                userAgent: janitorWebViewUserAgent,
              ),
              webViewEnvironment:
                  defaultTargetPlatform == TargetPlatform.windows
                  ? chatWebViewEnvironment
                  : null,
              // Claim the drags so the challenge page scrolls instead of the
              // sheet sliding away under the user's finger.
              gestureRecognizers: {
                Factory<VerticalDragGestureRecognizer>(
                  () => VerticalDragGestureRecognizer(),
                ),
                Factory<HorizontalDragGestureRecognizer>(
                  () => HorizontalDragGestureRecognizer(),
                ),
              },
            ),
          ),
        ],
      ),
    );
  }
}
