import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/prompt_isolate.dart';
import '../../../core/models/api_config.dart';
import '../../../core/state/studio_feature_provider.dart';
import '../../settings/api_list_provider.dart';
import '../chat_provider.dart';
import '../providers/prompt_build_providers.dart';
import 'cached_token_breakdown.dart';

/// Where the chat draws its CONTEXT LIMIT rule.
@immutable
class ContextWindowBoundary {
  /// The message the rule is drawn on.
  final String messageId;

  /// Draws the rule under [messageId] instead of above it. Set when the prompt
  /// kept none of the chat — the window left after the reply's reservation was
  /// too small for even the newest message — so the whole chat is past it.
  final bool afterMessage;

  const ContextWindowBoundary(this.messageId, {this.afterMessage = false});

  @override
  bool operator ==(Object other) =>
      other is ContextWindowBoundary &&
      other.messageId == messageId &&
      other.afterMessage == afterMessage;

  @override
  int get hashCode => Object.hash(messageId, afterMessage);

  @override
  String toString() =>
      'ContextWindowBoundary($messageId${afterMessage ? ', after' : ''})';
}

/// Where the chat draws its CONTEXT LIMIT rule: above the oldest message the
/// next prompt still carries, or under the newest one when it carries none.
///
/// Read from the breakdown the last prompt build left behind, so it answers for
/// the trim that actually ran. Both modes land here: sliding reports the cut it
/// recomputed this turn, stepped the window its anchor holds open. Null while
/// nothing was cut (the whole chat is in the prompt, so there is no boundary to
/// draw) and null while no breakdown exists — a rule guessed from nothing is
/// worse than no rule.
final contextWindowStartProvider = Provider.autoDispose
    .family<ContextWindowBoundary?, String>((ref, charId) {
      // Keeps the open chat's breakdown counted under the connection's current
      // window: a changed context size or reply budget drops the breakdown, and
      // without a recount the rule would vanish until the next generation.
      ref.watch(contextWindowRecountProvider(charId));
      final breakdown = ref.watch(cachedTokenBreakdownProvider(charId));
      // A session switch keeps the character's cached breakdown, whose boundary
      // belongs to the session that was open when it was built. Watching the id
      // re-runs this, and the membership check below drops a boundary the open
      // chat has no message for.
      ref.watch(chatProvider(charId).select((s) => s.value?.session?.id));
      if (breakdown == null || breakdown.cutoffIndex <= 0) return null;
      final messages = ref.read(chatProvider(charId)).value?.messages;
      if (messages == null || messages.isEmpty) return null;
      final id = breakdown.windowStartMessageId;
      if (id == null) {
        // Cut, yet nothing kept: the whole chat is out of the prompt. A
        // Studio-built window keeps messages without source ids instead, and
        // has no boundary to draw.
        if (breakdown.trimmedHistory.isNotEmpty) return null;
        return ContextWindowBoundary(messages.last.id, afterMessage: true);
      }
      return messages.any((message) => message.id == id)
          ? ContextWindowBoundary(id)
          : null;
    });

/// Recounts the open chat's prompt once the active connection's context budget
/// changes — a new context size or reply budget, a different trim mode, another
/// connection picked.
///
/// The app drops every cached breakdown on such a change (it no longer
/// describes the prompt the app would send); this puts the open chat's one back
/// so the CONTEXT LIMIT rule moves to where the new window cuts. Debounced, as
/// the API editor saves while a number is still being typed.
final contextWindowRecountProvider = Provider.autoDispose.family<void, String>((
  ref,
  charId,
) {
  Timer? debounce;
  ref.onDispose(() => debounce?.cancel());
  ref.listen<String>(
    activeApiConfigProvider.select(
      (config) => config?.contextBudgetSignature ?? '',
    ),
    (previous, next) {
      if (previous == null || previous.isEmpty || previous == next) return;
      debounce?.cancel();
      debounce = Timer(
        const Duration(milliseconds: 600),
        () => unawaited(_recountBreakdown(ref, charId)),
      );
    },
  );
});

Future<void> _recountBreakdown(Ref ref, String charId) async {
  if (!ref.mounted) return;
  // Studio builds its own window — from its own connection — and its breakdown
  // carries no rule; the ordinary prompt counted here would draw a false one.
  if (ref.read(studioFeatureEnabledProvider)) return;
  final chat = ref.read(chatProvider(charId)).value;
  final session = chat?.session;
  // A running turn stores the breakdown of the prompt it is building.
  if (chat == null || session == null || chat.isGenerating) return;
  try {
    final inputs = await ref
        .read(promptPayloadBuilderProvider)
        .collectInputs(charId: charId, session: session);
    final result = await buildFromInputsInIsolate(inputs);
    if (!ref.mounted) return;
    final cache = ref.read(cachedTokenBreakdownProvider(charId).notifier);
    // A generation or the inspector counted a newer prompt in the meantime.
    if (cache.state != null) return;
    if (ref.read(chatProvider(charId)).value?.session?.id != session.id) {
      return;
    }
    // The fast-path collectInputs skips vector search; reuse the count the
    // last real generation found, as the tokenizer sheet does.
    cache.state = result.breakdown.withVectorLore(
      ref.read(lastVectorLoreTokensProvider(charId)),
    );
  } catch (e) {
    debugPrint('Context window recount failed: $e');
  }
}
