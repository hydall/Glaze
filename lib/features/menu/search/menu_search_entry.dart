import 'package:flutter/material.dart';

/// One searchable destination inside the More tab.
///
/// Entries describe a row the user could reach by walking the More tab by hand
/// — a whole screen ("App Settings"), or a single switch buried two levels down
/// ("Battery saver"). [open] performs exactly the navigation that walk would
/// have produced, so a search hit and a manual tap land on the same place.
@immutable
class MenuSearchEntry {
  /// Localized row label, as it reads on the screen it lives on.
  final String title;

  /// Localized helper text under the label (the switch description or the menu
  /// item hint), when the row has one.
  final String? description;

  /// Screen path the row lives on, outermost first — e.g.
  /// `['Settings', 'Interface']`. Rendered under the title so a hit is
  /// recognisable without opening it.
  final List<String> breadcrumb;

  final IconData icon;

  /// Extra match terms that never render: synonyms and the other language's
  /// wording, so "haptic" finds "Вибрация" and vice versa.
  final List<String> keywords;

  final void Function(BuildContext context) open;

  const MenuSearchEntry({
    required this.title,
    required this.breadcrumb,
    required this.icon,
    required this.open,
    this.description,
    this.keywords = const [],
  });

  String get breadcrumbLabel => breadcrumb.join(' › ');
}

/// Score of [entry] against the already-lowercased [tokens], or `null` when any
/// token is missing (all tokens must match — an AND search).
///
/// Higher is better: a title hit outranks a description hit, and a title that
/// *starts* with the token outranks one that merely contains it, so typing
/// "lang" puts "Language" above "Interface settings".
int? _scoreEntry(MenuSearchEntry entry, List<String> tokens) {
  final title = entry.title.toLowerCase();
  final description = entry.description?.toLowerCase() ?? '';
  final breadcrumb = entry.breadcrumbLabel.toLowerCase();
  final keywords = entry.keywords.join(' ').toLowerCase();

  var total = 0;
  for (final token in tokens) {
    if (title.startsWith(token)) {
      total += 100;
    } else if (title.contains(token)) {
      total += 60;
    } else if (keywords.contains(token)) {
      total += 30;
    } else if (description.contains(token)) {
      total += 20;
    } else if (breadcrumb.contains(token)) {
      total += 10;
    } else {
      return null;
    }
  }
  return total;
}

/// Filters [entries] by [query], best match first. A blank query matches
/// nothing — the caller shows the normal menu instead of the whole index.
List<MenuSearchEntry> filterMenuSearchEntries(
  List<MenuSearchEntry> entries,
  String query,
) {
  final tokens = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();
  if (tokens.isEmpty) return const [];

  final scored = <(int, int, MenuSearchEntry)>[];
  for (var i = 0; i < entries.length; i++) {
    final score = _scoreEntry(entries[i], tokens);
    if (score != null) scored.add((score, i, entries[i]));
  }
  // Index is the tiebreaker so equally-scored rows keep their menu order.
  scored.sort((a, b) {
    final byScore = b.$1.compareTo(a.$1);
    return byScore != 0 ? byScore : a.$2.compareTo(b.$2);
  });
  return [for (final s in scored) s.$3];
}
