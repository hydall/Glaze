import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat_provider.dart';
import 'cached_token_breakdown.dart';

/// Id of the oldest message the next prompt still carries — the message the
/// chat draws its CONTEXT LIMIT rule above.
///
/// Read from the breakdown the last prompt build left behind, so it answers for
/// the trim that actually ran. Both modes land here: sliding reports the cut it
/// recomputed this turn, stepped the window its anchor holds open. Null while
/// nothing was cut (the whole chat is in the prompt, so there is no boundary to
/// draw) and null while no breakdown exists — a rule guessed from nothing is
/// worse than no rule.
final contextWindowStartProvider = Provider.autoDispose
    .family<String?, String>((ref, charId) {
      final breakdown = ref.watch(cachedTokenBreakdownProvider(charId));
      // A session switch keeps the character's cached breakdown, whose boundary
      // belongs to the session that was open when it was built. Watching the id
      // re-runs this, and the membership check below drops a boundary the open
      // chat has no message for.
      ref.watch(chatProvider(charId).select((s) => s.value?.session?.id));
      if (breakdown == null || breakdown.cutoffIndex <= 0) return null;
      final id = breakdown.windowStartMessageId;
      if (id == null) return null;
      final messages = ref.read(chatProvider(charId)).value?.messages;
      if (messages == null) return null;
      return messages.any((message) => message.id == id) ? id : null;
    });
