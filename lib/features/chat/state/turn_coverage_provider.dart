import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/repositories/lorebook_use_manifest_repo.dart';
import '../../../core/llm/prompt/exact_lorebook_manifest.dart';
import '../../../core/state/db_provider.dart';

/// Identifies one message variation — the unit a manifest is written for.
typedef TurnCoverageKey = ({
  String sessionId,
  String messageId,
  int swipeId,
  int agentSwipeId,
});

/// What a past turn actually injected, straight from the manifest written when
/// it was generated (`chat_repo` → `insertGenerationManifest`).
///
/// This is not a re-run of the scan: re-scanning today's books against today's
/// history would answer a different question — what *would* fire now — which is
/// exactly the confusion the Coverage view exists to remove. Null means the
/// generation recorded no manifest (older turns, or a path that produced none).
final turnCoverageProvider = FutureProvider.autoDispose
    .family<ExactLorebookManifest?, TurnCoverageKey>((ref, key) async {
      if (key.sessionId.isEmpty || key.messageId.isEmpty) return null;
      final repo = ref.watch(lorebookUseManifestRepoProvider);
      final row = await repo.manifestFor(
        LorebookUseGenerationIdentity(
          sessionId: key.sessionId,
          messageId: key.messageId,
          swipeId: key.swipeId,
          agentSwipeId: key.agentSwipeId,
        ),
      );
      if (row == null) return null;
      try {
        final decoded = jsonDecode(row.manifestJson);
        if (decoded is! Map) return null;
        return ExactLorebookManifest.fromJson(Map<String, dynamic>.from(decoded));
      } catch (error, stack) {
        debugPrint('TURN COVERAGE: manifest decode failed: $error\n$stack');
        return null;
      }
    });
