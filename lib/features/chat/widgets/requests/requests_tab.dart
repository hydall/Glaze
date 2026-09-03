import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glaze_spinner.dart';
import '../../chat_provider.dart';
import '../../services/prompt_capture_view_service.dart';
import '../../state/session_requests_provider.dart';
import '../prompt_preview_screen.dart';
import 'request_detail_view.dart';
import 'request_rows.dart';

/// Every request this chat has sent to a model since the app started, plus the
/// live preview of the one it would send next.
///
/// The tab used to *be* that preview and nothing else, which answered "what
/// will go out" but never "what did". Opening a row shows the payload that
/// actually left the device; the inspector hides its tab strip while a row is
/// open so the detail owns the sheet.
class RequestsTab extends ConsumerStatefulWidget {
  const RequestsTab({
    super.key,
    required this.charId,
    required this.onDetailChanged,
  });

  final String charId;

  /// Fires whenever this tab enters or leaves a detail view, so the inspector
  /// can hide its tab strip for the drill-down.
  final ValueChanged<bool> onDetailChanged;

  @override
  ConsumerState<RequestsTab> createState() => _RequestsTabState();
}

class _RequestsTabState extends ConsumerState<RequestsTab> {
  PromptCaptureView? _openCapture;
  bool _openPreview = false;

  void _open({PromptCaptureView? capture, bool preview = false}) {
    setState(() {
      _openCapture = capture;
      _openPreview = preview;
    });
    widget.onDetailChanged(true);
  }

  void _close() {
    setState(() {
      _openCapture = null;
      _openPreview = false;
    });
    widget.onDetailChanged(false);
  }

  @override
  void dispose() {
    // The tab is being torn down with a detail open (sheet closed, chat left):
    // leave the inspector's own state consistent for the next open.
    if (_openCapture != null || _openPreview) widget.onDetailChanged(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessionId =
        ref.watch(
          chatProvider(widget.charId).select((s) => s.value?.session?.id),
        ) ??
        '';

    // A finished generation is what adds rows, so refresh the list on the
    // falling edge of `isGenerating` instead of polling the table.
    ref.listen<bool>(
      chatProvider(widget.charId).select((s) => s.value?.isGenerating ?? false),
      (previous, next) {
        if (previous == true && next == false) {
          ref.invalidate(promptCaptureViewsProvider(sessionId));
        }
      },
    );

    final capture = _openCapture;
    if (capture != null) {
      return _inset(
        context,
        RequestDetailView(capture: capture, onBack: _close),
      );
    }
    if (_openPreview) {
      // No header of our own: the preview screen already titles itself, and a
      // second title stacked on top is the duplication this rework set out to
      // remove. It gets the back button instead.
      return _inset(
        context,
        PromptPreviewScreen(
          charId: widget.charId,
          embedded: true,
          onBack: _close,
        ),
      );
    }

    final requests = ref.watch(sessionRequestsProvider(sessionId));
    return _inset(
      context,
      requests.when(
        loading: () => const Center(child: GlazeSpinner()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '${'title_error'.tr()}: $error',
              style: TextStyle(color: context.cs.onSurfaceVariant),
            ),
          ),
        ),
        data: (items) => _list(context, sessionId, items),
      ),
    );
  }

  /// The inspector hands its floating-header height down as the body's top
  /// inset; consume it once here so nothing below adds the gap again.
  Widget _inset(BuildContext context, Widget child) => Padding(
    padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
    child: MediaQuery.removePadding(
      context: context,
      removeTop: true,
      child: child,
    ),
  );

  Widget _list(
    BuildContext context,
    String sessionId,
    List<PromptCaptureView> items,
  ) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        RequestPreviewRow(onTap: () => _open(preview: true)),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
          child: Row(
            children: [
              Text(
                'requests_since_start'.tr(),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                tooltip: 'action_refresh'.tr(),
                onPressed: () =>
                    ref.invalidate(promptCaptureViewsProvider(sessionId)),
              ),
            ],
          ),
        ),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 18),
            child: Text(
              'requests_none_since_start'.tr(),
              style: TextStyle(
                fontSize: 13,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          )
        else
          for (final item in items)
            RequestRow(capture: item, onTap: () => _open(capture: item)),
      ],
    );
  }
}
