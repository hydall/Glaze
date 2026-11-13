/// JanitorAI's admission queue — Cloudflare's Waiting Room in front of the
/// site.
///
/// While the room is active every request, API calls included, is answered with
/// the same HTML page (`Please wait — janitor`, `You're in line`, an
/// `Estimated wait: …` line and a `refresh` meta tag). The page reloads itself
/// every `refresh` seconds, and one of those reloads is what eventually lets the
/// visitor through. From HTTP alone it looks like a perfectly normal `200`, so
/// callers have to recognise it before treating the body as JSON.
library;

/// One reading of the waiting-room page.
class JanitorWaitingRoom {
  /// How long the page asks to wait before refreshing itself. The reload is
  /// what advances the queue, so callers that drive the page use this as their
  /// polling interval.
  final Duration refreshInterval;

  /// The page's own estimate, e.g. `4 minutes`. Null when it carries none.
  final String? estimatedWait;

  const JanitorWaitingRoom({
    this.refreshInterval = const Duration(seconds: 20),
    this.estimatedWait,
  });

  @override
  bool operator ==(Object other) =>
      other is JanitorWaitingRoom &&
      other.refreshInterval == refreshInterval &&
      other.estimatedWait == estimatedWait;

  @override
  int get hashCode => Object.hash(refreshInterval, estimatedWait);

  @override
  String toString() =>
      'JanitorWaitingRoom(refresh: ${refreshInterval.inSeconds}s, '
      'wait: ${estimatedWait ?? 'unknown'})';
}

/// Thrown when the queue did not admit Glaze within its wait budget. Unlike a
/// `JanitorRefusedException` this is transient and says nothing about the
/// character.
class JanitorQueueException implements Exception {
  final JanitorWaitingRoom? lastReading;

  const JanitorQueueException([this.lastReading]);

  @override
  String toString() => lastReading?.estimatedWait == null
      ? 'JanitorAI is still queueing requests.'
      : 'JanitorAI is still queueing requests '
            '(estimated wait: ${lastReading!.estimatedWait}).';
}

final _estimatedWait = RegExp(
  r'Estimated wait:\s*([^<\n\r]+)',
  caseSensitive: false,
);
final _refreshMeta = RegExp(
  r'''<meta[^>]*http-equiv\s*=\s*["']?refresh["']?[^>]*content\s*=\s*["']?\s*(\d+)''',
  caseSensitive: false,
);
final _refreshMetaReversed = RegExp(
  r'''<meta[^>]*content\s*=\s*["']?\s*(\d+)[^>]*http-equiv\s*=\s*["']?refresh''',
  caseSensitive: false,
);

/// Reads the waiting-room markers out of [text] (a response body or page HTML).
///
/// Returns null when [text] is not the waiting room. The markers deliberately
/// include the page's own unique sentences rather than a bare "you're in line",
/// so a character card that happens to talk about queues is not mistaken for
/// one.
JanitorWaitingRoom? parseJanitorWaitingRoom(String text) {
  if (text.isEmpty) return null;
  final lower = text.toLowerCase();
  final title =
      RegExp(
        r'<title[^>]*>([^<]*)</title>',
        caseSensitive: false,
      ).firstMatch(text)?.group(1)?.toLowerCase() ??
      '';
  final queued =
      lower.contains('janitor is managing traffic') ||
      (lower.contains('traffic is high right now') &&
          lower.contains('letting people in slowly')) ||
      (title.contains('please wait') && title.contains('janitor')) ||
      (lower.contains('this page refreshes every') &&
          lower.contains('in line'));
  if (!queued) return null;

  final wait = _cleanWait(_estimatedWait.firstMatch(text)?.group(1));
  final refresh = int.tryParse(
    (_refreshMeta.firstMatch(text) ?? _refreshMetaReversed.firstMatch(text))
            ?.group(1) ??
        '',
  );
  return JanitorWaitingRoom(
    refreshInterval: Duration(
      seconds: (refresh != null && refresh > 0) ? refresh : 20,
    ),
    estimatedWait: wait,
  );
}

String? _cleanWait(String? value) {
  if (value == null) return null;
  final cleaned = value
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return cleaned.isEmpty ? null : cleaned;
}
