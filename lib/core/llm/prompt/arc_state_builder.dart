import '../../models/chat_message.dart';
import '../../models/tracker.dart';

/// Extracts the latest user-role message text from [history] for entity
/// mention detection. Returns empty string when history has no user message.
String latestUserTextFromHistory(List<ChatMessage> history) {
  for (final m in history.reversed) {
    if (m.role == 'user' && !m.isHidden && !m.isTyping) {
      return m.content;
    }
  }
  return '';
}

/// Extracts the latest assistant-role message text from [history] for entity
/// mention detection. Returns empty string when history has no assistant
/// message.
///
/// Including the assistant message prevents the mention filter from dropping
/// NPC canon when the user refers to a character indirectly (e.g. "белобрысая
/// нетраннерша" — the user's text alone won't match "Lucy", but the assistant's
/// last response likely names her).
String latestAssistantTextFromHistory(List<ChatMessage> history) {
  for (final m in history.reversed) {
    if (m.role == 'assistant' && !m.isHidden && !m.isTyping) {
      return m.content;
    }
  }
  return '';
}

/// Builds compact `<arc_state>` block for the `{{arc}}` macro from Studio
/// Canon `arc:*` tracker rows.
///
/// Replaces the old consolidation-summary approach with deterministic arc
/// state derived from ledger tracker rows. Selection rules (plan §{{arc}}):
///   - Completed arcs with do_not_reopen=true are always included (suppress
///     card-baseline regression).
///   - Active/seeded arcs whose entities/topics appear in [latestUserText]
///     are included.
///   - Omit unrelated completed arcs without do_not_reopen.
///   - Returns null when no arc rows exist.
String? buildArcContent(
  List<Tracker> ledgerRows, {
  String latestUserText = '',
  String latestAssistantText = '',
}) {
  // Collect arc:id.field → value
  final arcFields = <String, Map<String, String>>{};
  for (final t in ledgerRows) {
    if (!t.name.startsWith('arc:')) continue;
    if (t.value.isEmpty) continue;
    final rest = t.name.substring('arc:'.length);
    final dotIdx = rest.indexOf('.');
    if (dotIdx < 0) continue;
    final arcId = rest.substring(0, dotIdx);
    final field = rest.substring(dotIdx + 1);
    arcFields.putIfAbsent(arcId, () => {})[field] = t.value;
  }
  if (arcFields.isEmpty) return null;

  final combinedText = '$latestUserText\n$latestAssistantText';
  final lowerContext = combinedText.toLowerCase();

  final completed = <String>[];
  final active = <String>[];

  for (final arcId in arcFields.keys) {
    final f = arcFields[arcId]!;
    final status = f['status'] ?? '';
    final doNotReopen = f['do_not_reopen']?.toLowerCase() == 'true';
    final summary = f['summary'] ?? '';
    final title = f['title'] ?? arcId;

    if (status == 'completed' ||
        status == 'failed' ||
        status == 'abandoned' ||
        status == 'superseded') {
      // Include completed arcs with do_not_reopen OR if their title/summary
      // is mentioned in the latest user message.
      final mentioned =
          lowerContext.contains(title.toLowerCase()) ||
          (summary.isNotEmpty &&
              summary
                  .split(' ')
                  .take(5)
                  .any(
                    (w) =>
                        w.length > 3 && lowerContext.contains(w.toLowerCase()),
                  ));
      if (doNotReopen || mentioned) {
        completed.add(arcId);
      }
    } else {
      // active/seeded/paused — include if entities/title mentioned or
      // no filter needed (all active arcs are relevant for near-term)
      active.add(arcId);
    }
  }

  if (completed.isEmpty && active.isEmpty) return null;

  final buf = StringBuffer();
  buf.writeln('<arc_state>');
  buf.writeln(
    'Session canon overrides character-card baseline when conflicting.',
  );

  if (completed.isNotEmpty) {
    buf.writeln('\nCompleted/resolved:');
    for (final id in completed..sort()) {
      final f = arcFields[id]!;
      final title = f['title'] ?? id;
      final summary = f['summary'] ?? '';
      final doNotReopen = f['do_not_reopen']?.toLowerCase() == 'true';
      final cardOverride = f['card_override'] ?? '';
      buf.write('- $title is completed.');
      if (summary.isNotEmpty) buf.write(' $summary');
      if (doNotReopen) {
        buf.write(
          ' Treat card hooks about this as backstory, not an unresolved conflict.',
        );
      }
      if (cardOverride.isNotEmpty) buf.write(' $cardOverride');
      buf.writeln();
    }
  }

  if (active.isNotEmpty) {
    buf.writeln('\nActive:');
    for (final id in active..sort()) {
      final f = arcFields[id]!;
      final title = f['title'] ?? id;
      final summary = f['summary'] ?? '';
      buf.write('- $title');
      if (summary.isNotEmpty) buf.write(': $summary');
      buf.writeln();
    }
  }

  buf.write('</arc_state>');
  return buf.toString().trim();
}
