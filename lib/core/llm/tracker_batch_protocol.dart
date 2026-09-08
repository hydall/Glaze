import 'tracker_batcher.dart' show TrackerBatchGroup, TrackerBatchResult;

/// Pure serializer pair for the tracker batch wire format, extracted from
/// `TrackerBatcher` (plan §4). Builds the `<role>/<lore>/<agents>` batch system
/// prompt and parses the model's `<result agent="…">` reply back into one
/// [TrackerBatchResult] per agent.
///
/// No `Ref`, no state. Behavior is preserved verbatim. `TrackerBatcher` keeps
/// instance `buildBatchSystemPrompt` / `parseBatchResponse` delegators because
/// `test/characterization/tracker_batcher_test.dart` calls them on the
/// instance.
class TrackerBatchProtocol {
  const TrackerBatchProtocol();

  /// Build the batched system prompt for a group. Layout (prompt-cache-friendly
  /// order): stable `<role>` + `<lore>` prefix, then volatile per-agent
  /// `<agent_task>` tail, then the required `<result agent="…">` output format.
  String buildBatchSystemPrompt({
    required TrackerBatchGroup group,
    required List<Map<String, dynamic>> sharedMessages,
    required Map<String, String> perAgentTaskText,
    required String roleText,
  }) {
    final buf = StringBuffer();

    // <role>
    if (roleText.isNotEmpty) {
      buf.writeln('<role>');
      buf.writeln(_escapeXml(roleText));
      buf.writeln('</role>');
      buf.writeln();
    }

    // <lore> — shared context flattened
    buf.writeln('<lore>');
    for (final message in sharedMessages) {
      final role = message['role'] ?? 'system';
      final content = message['content'];
      if (content is String && content.isNotEmpty) {
        buf.writeln('[$role]');
        buf.writeln(_escapeXml(content));
        buf.writeln();
      }
    }
    buf.writeln('</lore>');
    buf.writeln();

    // <agents>
    buf.writeln('<agents>');
    for (final agent in group.agents) {
      final task = perAgentTaskText[agent.id] ?? '';
      buf.writeln(
        '  <agent_task id="${_escapeXmlAttr(agent.id)}" '
        'name="${_escapeXmlAttr(agent.name)}">',
      );
      if (task.isNotEmpty) {
        buf.writeln(_escapeXml(task));
      }
      buf.writeln('  </agent_task>');
    }
    buf.writeln('</agents>');
    buf.writeln();

    // Required output format
    buf.writeln('─── REQUIRED OUTPUT FORMAT ───');
    buf.writeln(
      'Respond with exactly one <result> block per agent_task, in the order '
      'the agent_tasks appear above.',
    );
    for (final agent in group.agents) {
      buf.writeln(
        '<result agent="${_escapeXmlAttr(agent.id)}">'
        '{${agent.name} output here}'
        '</result>',
      );
    }
    buf.writeln();
    buf.writeln('CRITICAL:');
    buf.writeln(
      '- You MUST produce a <result> block for EVERY agent_task id listed '
      'above, even if a task is empty or you have no guidance for it.',
    );
    buf.writeln(
      '- Each <result> block must contain ONLY that agent\'s output, nothing '
      'else.',
    );
    buf.writeln(
      '- Do not add commentary, summaries, or explanations outside '
      '<result> blocks.',
    );
    return buf.toString().trim();
  }

  /// Parse a batched model response into one [TrackerBatchResult] per agent in
  /// [group]. Tries `<result agent="ID">` first (tolerating a missing closing
  /// tag), then the legacy `<result_ID>` shape.
  List<TrackerBatchResult> parseBatchResponse(
    String raw,
    TrackerBatchGroup group,
  ) {
    final results = <TrackerBatchResult>[];
    for (final agent in group.agents) {
      final text = _extractResultBlock(raw, agent.id) ??
          _matchLegacyResultTag(raw, agent.id) ??
          '';
      final trimmed = text.trim();
      results.add(TrackerBatchResult(
        agentId: agent.id,
        agentName: agent.name,
        text: trimmed,
        status: trimmed.isNotEmpty ? 'ok' : 'failed',
        error: trimmed.isEmpty ? 'no <result> block in batch response' : null,
      ));
    }
    return results;
  }

  /// Find `<result agent="ID">...</result>` for [agentId]. Tolerates a missing
  /// closing tag by taking up to the next `<result` opening.
  String? _extractResultBlock(String raw, String agentId) {
    final escapedId = RegExp.escape(agentId);
    final openPattern = RegExp(
      '<result\\s+agent\\s*=\\s*["\']?$escapedId["\']?\\s*>',
      caseSensitive: false,
    );
    final openMatch = openPattern.firstMatch(raw);
    if (openMatch == null) return null;
    final bodyStart = openMatch.end;
    final tail = raw.substring(bodyStart);
    final closePattern = RegExp('</result>', caseSensitive: false);
    final nextOpenPattern = RegExp('<result\\b', caseSensitive: false);
    final closeMatch = closePattern.firstMatch(tail);
    final nextOpenMatch = nextOpenPattern.firstMatch(tail);
    final int boundary;
    if (closeMatch != null && nextOpenMatch != null) {
      boundary = closeMatch.start < nextOpenMatch.start
          ? closeMatch.start
          : nextOpenMatch.start;
    } else if (closeMatch != null) {
      boundary = closeMatch.start;
    } else if (nextOpenMatch != null) {
      boundary = nextOpenMatch.start;
    } else {
      boundary = tail.length;
    }
    return tail.substring(0, boundary);
  }

  /// Legacy fallback: `<result_ID>...</result_ID>` (some models invent this
  /// shape when they don't follow the `<result agent="...">` format).
  String? _matchLegacyResultTag(String raw, String agentId) {
    final escapedId = RegExp.escape(agentId);
    final pattern = RegExp(
      '<result_$escapedId>([\\s\\S]*?)</result_$escapedId>',
      caseSensitive: false,
    );
    final match = pattern.firstMatch(raw);
    return match?.group(1);
  }

  /// XML-escape text for use in element body. Escapes `&`, `<`, `>`.
  String _escapeXml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }

  /// XML-escape text for use in an attribute value. Also escapes `"` and `'`.
  String _escapeXmlAttr(String text) {
    return _escapeXml(text)
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}
