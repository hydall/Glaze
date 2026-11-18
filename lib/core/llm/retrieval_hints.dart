List<String> extractRetrievalHintsFrom({
  String? label,
  required List<String> keys,
  required String content,
}) {
  final hints = <String>{};

  if (label != null && label.isNotEmpty) hints.add(label);

  for (final key in keys) {
    if (key.isNotEmpty) hints.add(key);
  }

  final lines = content.split('\n');
  int lineCount = 0;
  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    hints.add(line.trim());
    lineCount++;
    if (lineCount >= 8) break;
  }

  final labelPattern = RegExp(r'^[\w\s]+:\s*(.+)$', multiLine: true);
  for (final match in labelPattern.allMatches(content)) {
    final value = match.group(1);
    if (value != null && value.isNotEmpty) {
      for (final part in value.split(RegExp(r'[;,]'))) {
        final trimmed = part.trim();
        if (trimmed.isNotEmpty) hints.add(trimmed);
      }
    }
  }

  final normalized = hints
      .map((h) => h.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '').trim())
      .toSet();
  return hints.where((h) {
    final n = h.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '').trim();
    return n.isNotEmpty && normalized.contains(n);
  }).take(32).toList();
}