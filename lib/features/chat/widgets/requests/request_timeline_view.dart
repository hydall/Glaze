import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/chat_message.dart';
import '../../../../core/state/studio_feature_provider.dart';
import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glaze_spinner.dart';
import '../../chat_provider.dart';
import '../../services/prompt_capture_view_service.dart';
import '../../state/request_timeline.dart';
import '../../state/session_requests_provider.dart';
import '../prompt_preview_screen.dart';
import '../studio_prompt_preview_tab.dart';
import 'coverage_rows.dart';
import 'next_turn_coverage_view.dart';
import 'request_detail_view.dart';
import 'request_group_card.dart';
import 'request_rows.dart';

/// Everything this chat has sent to a model since the app started, in one
/// timeline: each turn with the stages it set off, and the background jobs
/// (card rewrite, reconciliation, summary, embeddings, images) in their own
/// place in time.
///
/// Grouping lives in [buildRequestTimeline]; this widget only decides what is
/// open. Three levels: timeline → the steps of one group → the payload of one
/// step. The inspector hides its tab strip for the last two.
///
/// Coverage is not a view next to this one any more. A past request's coverage
/// is a block inside that request; only the *next* request's — a live dry-run
/// of the scan, which belongs to no captured request yet — still gets a row of
/// its own at the top.
class RequestTimelineView extends ConsumerStatefulWidget {
  const RequestTimelineView({
    super.key,
    required this.charId,
    required this.onDetailChanged,
    this.initialCoverage = false,
  });

  final String charId;

  /// Fires whenever this tab enters or leaves a detail view, so the inspector
  /// can hide its tab strip for the drill-down.
  final ValueChanged<bool> onDetailChanged;

  /// Opens straight on the next request's coverage — where the context card's
  /// lorebook layer deep-links to.
  final bool initialCoverage;

  @override
  ConsumerState<RequestTimelineView> createState() =>
      _RequestTimelineViewState();
}

class _RequestTimelineViewState extends ConsumerState<RequestTimelineView> {
  PromptCaptureView? _openCapture;
  bool _openPreview = false;
  late bool _openCoverage = widget.initialCoverage;
  final Set<String> _expandedGroups = {};

  bool get _inDetail => _openCapture != null || _openPreview || _openCoverage;

  @override
  void initState() {
    super.initState();
    // A deep link opens on a drill-down, so the inspector has to be told to
    // step its tab strip aside — after the frame that mounts us, never during
    // the parent's own build.
    if (_openCoverage) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _openCoverage) widget.onDetailChanged(true);
      });
    }
  }

  void _open({
    PromptCaptureView? capture,
    bool preview = false,
    bool coverage = false,
  }) {
    setState(() {
      _openCapture = capture;
      _openPreview = preview;
      _openCoverage = coverage;
    });
    widget.onDetailChanged(true);
  }

  void _close() {
    setState(() {
      _openCapture = null;
      _openPreview = false;
      _openCoverage = false;
    });
    widget.onDetailChanged(false);
  }

  @override
  void dispose() {
    // Torn down with a detail open (sheet closed, chat left): leave the
    // inspector's own state consistent for the next open.
    if (_inDetail) widget.onDetailChanged(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessionId =
        ref.watch(
          chatProvider(widget.charId).select((s) => s.value?.session?.id),
        ) ??
        '';

    // A finished generation is what adds rows, so refresh on the falling edge
    // of `isGenerating` instead of polling the table.
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
        RequestDetailView(
          charId: widget.charId,
          capture: capture,
          onBack: _close,
        ),
      );
    }
    if (_openCoverage) {
      return _inset(
        NextTurnCoverageView(
          charId: widget.charId,
          sessionId: sessionId,
          onBack: _close,
        ),
      );
    }
    if (_openPreview) {
      // No header of our own: both preview screens title themselves, and a
      // second title stacked on top is the duplication this rework removed.
      // They get the back button instead.
      final agentic = ref.watch(studioFeatureEnabledProvider);
      // The preview screens read the inset themselves, so they are not wrapped.
      return agentic
          ? StudioPromptPreviewTab(charId: widget.charId, onBack: _close)
          : PromptPreviewScreen(
              charId: widget.charId,
              embedded: true,
              onBack: _close,
            );
    }

    final timeline = ref.watch(requestTimelineProvider(sessionId));
    return _inset(
      timeline.when(
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
        data: (groups) => _timeline(context, sessionId, groups),
      ),
    );
  }

  /// The inspector hands its floating-header height down as the body's top
  /// inset; consume it once here so nothing below adds the gap again.
  Widget _inset(Widget child) => Builder(
    builder: (context) => Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: MediaQuery.removePadding(
        context: context,
        removeTop: true,
        child: child,
      ),
    ),
  );

  Widget _timeline(
    BuildContext context,
    String sessionId,
    List<RequestGroup> groups,
  ) {
    final messages =
        ref.watch(chatProvider(widget.charId)).value?.messages ??
        const <ChatMessage>[];

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        RequestPreviewRow(onTap: () => _open(preview: true)),
        const SizedBox(height: 8),
        CoverageNextRow(onTap: () => _open(coverage: true)),
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
        if (groups.isEmpty)
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
          for (final group in groups)
            RequestGroupCard(
              group: group,
              expanded: _expandedGroups.contains(group.key),
              turnNumber: _turnNumber(messages, group),
              replyPreview: _replyPreview(messages, group),
              onToggle: () => setState(() {
                if (!_expandedGroups.remove(group.key)) {
                  _expandedGroups.add(group.key);
                }
              }),
              onOpenEntry: (entry) => _open(capture: entry.capture),
            ),
      ],
    );
  }

  /// Position of the turn's reply in the chat, so a row can be matched to a
  /// message on screen. Null when the message is gone (deleted, or scrolled out
  /// of the loaded window).
  int? _turnNumber(List<ChatMessage> messages, RequestGroup group) {
    final id = group.messageId;
    if (id == null || group.kind != RequestGroupKind.turn) return null;
    final index = messages.indexWhere((m) => m.id == id);
    return index < 0 ? null : index + 1;
  }

  String? _replyPreview(List<ChatMessage> messages, RequestGroup group) {
    final id = group.messageId;
    if (id == null) return null;
    final index = messages.indexWhere((m) => m.id == id);
    if (index < 0) return null;
    final text = messages[index].content.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (text.isEmpty) return null;
    return text.length <= 48 ? text : '${text.substring(0, 48)}…';
  }
}
