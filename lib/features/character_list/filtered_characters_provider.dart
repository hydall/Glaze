import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/llm/character_tokens.dart';
import '../../core/models/character.dart';
import '../../core/state/character_folder_provider.dart';
import '../../core/state/character_provider.dart';
import 'character_sort.dart';

/// Immutable description of a My-Characters query: which characters to keep
/// (search + filters + optional folder) and how to order them. Value equality
/// lets [filteredCharactersProvider] cache the result and recompute only when
/// the inputs actually change — keeping the (potentially O(n log n)) filter +
/// sort out of the widget build method.
@immutable
class CharacterQuery {
  final String search;
  final bool favOnly;
  final List<String> tags; // kept sorted by the caller
  final int minTokens;
  final int maxTokens;
  final bool hasTokenFilter;
  final SortType sortBy;
  final SortDir sortDir;
  final String? folderId;

  const CharacterQuery({
    required this.search,
    required this.favOnly,
    required this.tags,
    required this.minTokens,
    required this.maxTokens,
    required this.hasTokenFilter,
    required this.sortBy,
    required this.sortDir,
    this.folderId,
  });

  @override
  bool operator ==(Object other) =>
      other is CharacterQuery &&
      other.search == search &&
      other.favOnly == favOnly &&
      other.minTokens == minTokens &&
      other.maxTokens == maxTokens &&
      other.hasTokenFilter == hasTokenFilter &&
      other.sortBy == sortBy &&
      other.sortDir == sortDir &&
      other.folderId == folderId &&
      listEquals(other.tags, tags);

  @override
  int get hashCode => Object.hash(
    search,
    favOnly,
    minTokens,
    maxTokens,
    hasTokenFilter,
    sortBy,
    sortDir,
    folderId,
    Object.hashAll(tags),
  );
}

/// Filtered + sorted characters for a [CharacterQuery]. Depends on
/// [charactersProvider] (and [folderMembershipsProvider] when scoped to a
/// folder), so it re-runs reactively when the library changes, and is cached
/// per distinct query otherwise.
final filteredCharactersProvider = Provider.autoDispose
    .family<List<Character>, CharacterQuery>((ref, q) {
      final all = ref.watch(charactersProvider).value ?? const <Character>[];
      final showHidden = ref.watch(revealHiddenCharactersProvider);

      // Collapse variation groups to one representative card. Matching happens
      // against the whole group (union of tags, OR of `fav`, every variation
      // name), but the card itself stays the untouched representative row.
      Iterable<GroupView> list = _collapseGroups(all);
      // Hidden characters stay out of search/filter results unless revealed.
      if (!showHidden) list = list.where((g) => !g.rep.hidden);
      if (q.folderId != null) {
        final memberships =
            ref.watch(folderMembershipsProvider).value ??
            FolderMemberships.empty;
        final ids = memberships.charsIn(q.folderId!);
        list = list.where((g) => ids.contains(g.rep.id));
      }

      final result = list.where((g) => _passes(q, g)).toList();
      _sort(result, q);
      return [for (final g in result) g.rep];
    });

/// One variation group as the library query sees it: the representative card
/// plus the group-wide facts search and filters match against.
///
/// The representative is kept **unmodified** on purpose. It used to be a
/// `copyWith` carrying the group's unioned tags and OR'd `fav`, and the card
/// menus wrote that object straight back to the DB — one favorite toggle
/// permanently merged every variation's tags into the cover row.
class GroupView {
  final Character rep;
  final Set<String> tags;
  final bool fav;
  final List<String> variantNames;

  const GroupView({
    required this.rep,
    required this.tags,
    required this.fav,
    required this.variantNames,
  });
}

/// Reduces a flat character list (which contains every variation row) to one
/// [GroupView] per variation group; the representative is the lowest-ordered
/// row.
List<GroupView> _collapseGroups(List<Character> all) {
  final groups = <String, List<Character>>{};
  for (final c in all) {
    final gid = c.variantGroupId.isEmpty ? c.id : c.variantGroupId;
    groups.putIfAbsent(gid, () => <Character>[]).add(c);
  }
  final views = <GroupView>[];
  for (final members in groups.values) {
    if (members.length > 1) {
      members.sort((a, b) => a.variantOrder.compareTo(b.variantOrder));
    }
    var fav = false;
    final tags = <String>{};
    final variantNames = <String>[];
    for (final m in members) {
      fav = fav || m.fav;
      tags.addAll(m.tags);
      final variantName = m.variantName?.trim();
      if (variantName != null && variantName.isNotEmpty) {
        variantNames.add(variantName);
      }
    }
    views.add(
      GroupView(
        rep: members.first,
        tags: tags,
        fav: fav,
        variantNames: variantNames,
      ),
    );
  }
  return views;
}

bool _passes(CharacterQuery q, GroupView g) {
  final c = g.rep;
  if (q.search.isNotEmpty) {
    final query = q.search.toLowerCase();
    final displayName = c.displayName?.toLowerCase() ?? '';
    // Variation names match too, so a group is reachable by the name of any of
    // its variations — the chat list has always searched them (they were baked
    // into the row title), the library silently did not.
    final matchesSearch =
        c.name.toLowerCase().contains(query) ||
        displayName.contains(query) ||
        g.variantNames.any((n) => n.toLowerCase().contains(query));
    if (!matchesSearch) return false;
  }
  if (q.favOnly && !g.fav) return false;
  if (q.tags.isNotEmpty) {
    if (!q.tags.every(g.tags.contains)) return false;
  }
  if (q.hasTokenFilter) {
    final tokens = c.tokenCount > 0 ? c.tokenCount : estimateCharacterTokens(c);
    if (tokens < q.minTokens || tokens > q.maxTokens) return false;
  }
  return true;
}

String _displayNameOf(Character c) {
  final displayName = c.displayName?.trim();
  return (displayName != null && displayName.isNotEmpty) ? displayName : c.name;
}

void _sort(List<GroupView> list, CharacterQuery q) {
  // lastChat ordering isn't available client-side here; fall back to name.
  final effectiveSort = q.sortBy == SortType.lastChat
      ? SortType.name
      : q.sortBy;
  list.sort((ga, gb) {
    // Group-wide fav, so a favorite on any variation floats its card to the top.
    if (ga.fav != gb.fav) return ga.fav ? -1 : 1;
    final a = ga.rep, b = gb.rep;
    final cmp = switch (effectiveSort) {
      SortType.name => _displayNameOf(
        a,
      ).toLowerCase().compareTo(_displayNameOf(b).toLowerCase()),
      SortType.date => a.createdAt.compareTo(b.createdAt),
      SortType.lastChat => _displayNameOf(
        a,
      ).toLowerCase().compareTo(_displayNameOf(b).toLowerCase()),
    };
    if (cmp != 0) return q.sortDir == SortDir.desc ? -cmp : cmp;
    return a.id.compareTo(b.id);
  });
}
