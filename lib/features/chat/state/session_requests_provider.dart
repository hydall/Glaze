import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/prompt_capture_view_service.dart';
import 'request_timeline.dart';

/// Every LLM request this chat has made that the capture store still keeps,
/// newest first.
///
/// Captures are persisted (`llm_request_capture_rows`) and survive a restart.
/// They used to be cut off at the moment the app started, which hid every
/// request of an earlier run although it was right there in the database; the
/// rows carry their own date and time, which is enough to tell runs apart.
///
/// Reads through [promptCaptureViewsProvider], so invalidating that one (as the
/// Ledger stage and the collector tab already do) refreshes this too.
final sessionRequestsProvider = FutureProvider.autoDispose
    .family<List<PromptCaptureView>, String>((ref, sessionId) async {
      if (sessionId.isEmpty) return const [];
      return ref.watch(promptCaptureViewsProvider(sessionId).future);
    });

/// The same requests as timeline rows, newest first.
///
/// Kept next to the raw list rather than inside the widget so the folding is
/// one pure function away from a unit test (`buildRequestTimeline`).
final requestTimelineProvider = FutureProvider.autoDispose
    .family<List<RequestGroup>, String>((ref, sessionId) async {
      final captures = await ref.watch(
        sessionRequestsProvider(sessionId).future,
      );
      return buildRequestTimeline(captures);
    });
