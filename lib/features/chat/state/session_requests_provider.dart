import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_runtime.dart';
import '../services/prompt_capture_view_service.dart';
import 'request_timeline.dart';

/// Every LLM request this chat has made **since the app started**, newest first.
///
/// Captures are persisted (`llm_request_capture_rows`) and survive a restart,
/// so the Requests tab would otherwise open on traffic from a previous run with
/// no way to tell the two apart. [AppRuntime.startedAt] is that dividing line.
///
/// Reads through [promptCaptureViewsProvider], so invalidating that one (as the
/// Ledger stage and the collector tab already do) refreshes this too.
final sessionRequestsProvider = FutureProvider.autoDispose
    .family<List<PromptCaptureView>, String>((ref, sessionId) async {
      if (sessionId.isEmpty) return const [];
      final views = await ref.watch(
        promptCaptureViewsProvider(sessionId).future,
      );
      final since = AppRuntime.startedAtMs;
      return [
        for (final view in views)
          if (view.row.createdAtMs >= since) view,
      ];
    });

/// The same requests folded into turns and background jobs, newest first.
///
/// Kept next to the raw list rather than inside the widget so the grouping is
/// one pure function away from a unit test (`buildRequestTimeline`).
final requestTimelineProvider = FutureProvider.autoDispose
    .family<List<RequestGroup>, String>((ref, sessionId) async {
      final captures = await ref.watch(
        sessionRequestsProvider(sessionId).future,
      );
      return buildRequestTimeline(captures);
    });
