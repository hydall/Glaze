String formatTimeAgo(int epochMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inHours < 1) return '${diff.inMinutes}m';
  if (diff.inDays < 1) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';
  return '${dt.day}/${dt.month}';
}

String formatRelativeTimeFromSeconds(int updatedAtSeconds) {
  final updated = DateTime.fromMillisecondsSinceEpoch(updatedAtSeconds * 1000);
  final diff = DateTime.now().difference(updated);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inHours < 1) return '${diff.inMinutes}m';
  if (diff.inDays < 1) return '${diff.inHours}h';
  return '${diff.inDays}d';
}

String formatTimeAgoFromMs(int ts) {
  final diff = (DateTime.now().millisecondsSinceEpoch - ts) ~/ 1000;
  if (diff < 60) return 'just now';
  if (diff < 3600) return '${diff ~/ 60}m ago';
  if (diff < 86400) return '${diff ~/ 3600}h ago';
  return '${diff ~/ 86400}d ago';
}

/// Absolute "HH:MM, Mon D, YYYY" used for the "Created on …" / "Branched on …"
/// origin markers (chat separator label + session-list preview). Mirrors the
/// WebView renderer's origin label so both surfaces read the same.
String formatOriginDate(int epochMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final hh = d.hour.toString().padLeft(2, '0');
  final mm = d.minute.toString().padLeft(2, '0');
  return '$hh:$mm, ${months[d.month - 1]} ${d.day}, ${d.year}';
}

/// Preview line for a session whose most recent event is its origin: e.g.
/// "Branched on 14:30, Jul 15, 2026".
String formatOriginPreview(String kind, int epochMs) {
  final verb = kind == 'branched' ? 'Branched on' : 'Created on';
  return '$verb ${formatOriginDate(epochMs)}';
}

String formatDuration(int seconds) {
  if (seconds == 0) return '0s';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m ${s}s';
  return '${s}s';
}
