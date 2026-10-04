import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glaze_action_button.dart';
import '../../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../../shared/widgets/glaze_error_block.dart';
import '../../../../shared/widgets/glaze_spinner.dart';
import '../../../../shared/widgets/glaze_toast.dart';
import '../../../../shared/widgets/sheet_view.dart';
import '../../../chat/bridge/chat_webview_environment.dart';
import '../../datacat_account_provider.dart';
import '../../services/datacat/datacat_account.dart';
import '../../services/datacat/datacat_models.dart';
import '../../../../shared/widgets/glaze_sheet.dart';

/// Entry point for the "DataCat account" row. Offers to unlink when an account
/// is already linked, and starts the device flow when it is not.
Future<void> openDatacatAccountSheet(BuildContext context, WidgetRef ref) async {
  if (!ref.read(datacatAccountProvider).linked) {
    await showDatacatLinkSheet(context);
    return;
  }
  await GlazeBottomSheet.show<void>(
    context,
    title: 'datacat_account_menu'.tr(),
    items: [
      BottomSheetItem(
        label: 'datacat_account_unlink'.tr(),
        icon: Icons.link_off_rounded,
        isDestructive: true,
        onTap: () async {
          Navigator.of(context, rootNavigator: true).pop();
          await ref.read(datacatAccountProvider.notifier).unlink();
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

/// Opens the link sheet. Resolves to true once an account is linked.
Future<bool> showDatacatLinkSheet(BuildContext context) async {
  final linked = await showGlazeSheet<bool>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    // No useSafeArea: SheetView pads itself for the status bar as it grows to
    // fullscreen, so the route's own inset would be counted twice and leave
    // the header stranded a status bar's height below the sheet's top edge.
    backgroundColor: Colors.transparent,
    builder: (_) => const DatacatLinkSheet(),
  );
  return linked ?? false;
}

/// Runs DataCat's device-link flow.
///
/// The user approves the link on DataCat's own page, so the app never sees
/// their password — it shows the short code, opens the hosted page that already
/// carries it, and waits for the token exchange to succeed. The code is shown
/// as well as embedded in the URL because the two ways out of a WebView that
/// will not cooperate are reading the code aloud to another device and pasting
/// it there.
class DatacatLinkSheet extends ConsumerStatefulWidget {
  const DatacatLinkSheet({super.key});

  @override
  ConsumerState<DatacatLinkSheet> createState() => _DatacatLinkSheetState();
}

class _DatacatLinkSheetState extends ConsumerState<DatacatLinkSheet> {
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
    _closed = true;
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final flow = await startDatacatLink();
      if (!mounted) return;
      setState(() => _flow = flow);

      final status = await awaitDatacatLink(flow, isCancelled: () => _closed);
      if (!mounted || _closed) return;
      ref.read(datacatAccountProvider.notifier).applyStatus(status);
      Navigator.of(context).pop(true);
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
      title: 'datacat_account_link_title'.tr(),
      showBack: true,
      onBack: () => Navigator.of(context).pop(false),
      startExpanded: true,
      // Built through a Builder so the body reads the header inset SheetView
      // publishes as MediaQuery.padding.top. Passing `context` from here reads
      // the padding *above* the sheet instead, which is zero, and the content
      // was drawn under the title row.
      body: Builder(builder: _buildBody),
    );
  }

  Widget _buildBody(BuildContext context) {
    final topPad = MediaQuery.paddingOf(context).top;
    final error = _error;
    if (error != null) {
      return Padding(
        padding: EdgeInsets.fromLTRB(16, topPad + 16, 16, 24),
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
        padding: EdgeInsets.only(top: topPad + 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GlazeSpinner(color: context.cs.primary),
            const SizedBox(height: 12),
            Text(
              'datacat_account_link_starting'.tr(),
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
      padding: EdgeInsets.only(top: topPad),
      child: Column(
        children: [
          if (flow.userCode != null) _UserCode(code: flow.userCode!),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(flow.uri)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                cacheEnabled: true,
                thirdPartyCookiesEnabled: true,
                isInspectable: false,
                useHybridComposition: true,
                userAgent: janitorWebViewUserAgent,
              ),
              webViewEnvironment:
                  defaultTargetPlatform == TargetPlatform.windows
                  ? chatWebViewEnvironment
                  : null,
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

/// The short approval code, tappable to copy.
class _UserCode extends StatelessWidget {
  final String code;

  const _UserCode({required this.code});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Column(
        children: [
          Text(
            'datacat_account_link_hint'.tr(),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: context.cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          GlazeActionButton(
            icon: Icons.copy_rounded,
            label: code,
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: code));
              if (context.mounted) {
                GlazeToast.show(context, 'datacat_account_code_copied'.tr());
              }
            },
          ),
        ],
      ),
    );
  }
}
