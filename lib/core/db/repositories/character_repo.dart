import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_db.dart';
import '../../models/character.dart';
import '../../models/gallery_entry.dart';
import '../../llm/character_tokens.dart';
import '../../utils/time_helpers.dart';
import '../../application/sync_repo_interfaces.dart';
import 'character_deletion_repo.dart';

enum CharacterSortField { name, date, lastChat }

enum CharacterSortDir { asc, desc }

/// Group-level facts about one variation group, used by the My Characters grid
/// to render a card that stands for the whole group: how many variations it
/// holds and whether *any* of them is favorited.
///
/// The grid only ever renders the representative row (`variant_order 0`), so
/// without this the card could not tell a 5-variation group from a lone
/// character, and a favorite living on a non-cover variation stayed invisible.
class VariantGroupStats {
  final int count;
  final bool anyFav;

  const VariantGroupStats({required this.count, required this.anyFav});

  /// A group of one, unfavorited — the fallback for a character whose group has
  /// not been observed yet (stream still loading).
  static const single = VariantGroupStats(count: 1, anyFav: false);

  @override
  bool operator ==(Object other) =>
      other is VariantGroupStats &&
      other.count == count &&
      other.anyFav == anyFav;

  @override
  int get hashCode => Object.hash(count, anyFav);
}

class CharacterRepo implements SyncCharacterStore {
  final AppDatabase _db;
  CharacterRepo(this._db);

  List<OrderClauseGenerator<$CharactersTable>> _orderBy(
    CharacterSortField field,
    CharacterSortDir dir,
  ) {
    if (field == CharacterSortField.lastChat) {
      return _lastChatOrder(dir);
    }
    final mode = dir == CharacterSortDir.asc
        ? OrderingMode.asc
        : OrderingMode.desc;
    final primaryExpr = switch (field) {
      CharacterSortField.name => _db.characters.name,
      CharacterSortField.date => _db.characters.createdAt,
      CharacterSortField.lastChat => _db.characters.createdAt,
    };
    return [
      ($CharactersTable t) => OrderingTerm(expression: primaryExpr, mode: mode),
      ($CharactersTable t) =>
          OrderingTerm(expression: t.charId, mode: OrderingMode.asc),
    ];
  }

  Expression<int> _lastChatAtColumn() {
    return _db.chatSessions.updatedAt.max();
  }

  List<OrderClauseGenerator<$CharactersTable>> _lastChatOrder(
    CharacterSortDir dir,
  ) {
    final mode = dir == CharacterSortDir.asc
        ? OrderingMode.asc
        : OrderingMode.desc;
    final nullExpr = _lastChatAtColumn().isNull();
    final chatExpr = _lastChatAtColumn();
    return [
      ($CharactersTable t) =>
          OrderingTerm(expression: nullExpr, mode: OrderingMode.asc),
      ($CharactersTable t) => OrderingTerm(expression: chatExpr, mode: mode),
      ($CharactersTable t) =>
          OrderingTerm(expression: t.charId, mode: OrderingMode.asc),
    ];
  }

  List<OrderingTerm> _lastChatOrderTerms(CharacterSortDir dir) {
    final mode = dir == CharacterSortDir.asc
        ? OrderingMode.asc
        : OrderingMode.desc;
    final nullExpr = _lastChatAtColumn().isNull();
    final chatExpr = _lastChatAtColumn();
    return [
      OrderingTerm(expression: nullExpr, mode: OrderingMode.asc),
      OrderingTerm(expression: chatExpr, mode: mode),
      OrderingTerm(expression: _db.characters.charId, mode: OrderingMode.asc),
    ];
  }

  @override
  Future<List<Character>> getAll() async {
    final rows = await (_db.select(
      _db.characters,
    )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).get();
    return rows.map(_toModel).toList();
  }

  Stream<List<Character>> watchAll() {
    return (_db.select(_db.characters)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  /// Representative-row predicate for the My Characters list: only the cover
  /// (variant_order 0), and — unless [includeHidden] — only non-hidden rows.
  Expression<bool> _listPredicate(bool includeHidden) {
    final repOnly = _db.characters.variantOrder.equals(0);
    return includeHidden
        ? repOnly
        : repOnly & _db.characters.hidden.equals(false);
  }

  Future<List<Character>> getPage({
    required int limit,
    required int offset,
    required CharacterSortField sort,
    required CharacterSortDir dir,
    bool includeHidden = false,
  }) async {
    if (sort == CharacterSortField.lastChat) {
      final rows =
          await (_db.select(_db.characters).join([
                  leftOuterJoin(
                    _db.chatSessions,
                    _db.chatSessions.characterId.equalsExp(
                      _db.characters.charId,
                    ),
                  ),
                ])
                ..where(_listPredicate(includeHidden))
                ..addColumns([_lastChatAtColumn()])
                ..groupBy([_db.characters.charId])
                ..orderBy(_lastChatOrderTerms(dir))
                ..limit(limit, offset: offset))
              .get();
      return rows.map((r) => _toModel(r.readTable(_db.characters))).toList();
    }
    final rows =
        await (_db.select(_db.characters)
              ..where((t) => _listPredicate(includeHidden))
              ..orderBy(_orderBy(sort, dir))
              ..limit(limit, offset: offset))
            .get();
    return rows.map(_toModel).toList();
  }

  Stream<List<Character>> watchPage({
    required int limit,
    required int offset,
    required CharacterSortField sort,
    required CharacterSortDir dir,
    bool includeHidden = false,
  }) {
    if (sort == CharacterSortField.lastChat) {
      return (_db.select(_db.characters).join([
              leftOuterJoin(
                _db.chatSessions,
                _db.chatSessions.characterId.equalsExp(_db.characters.charId),
              ),
            ])
            ..where(_listPredicate(includeHidden))
            ..addColumns([_lastChatAtColumn()])
            ..groupBy([_db.characters.charId])
            ..orderBy(_lastChatOrderTerms(dir))
            ..limit(limit, offset: offset))
          .watch()
          .map(
            (rows) =>
                rows.map((r) => _toModel(r.readTable(_db.characters))).toList(),
          );
    }
    return (_db.select(_db.characters)
          ..where((t) => _listPredicate(includeHidden))
          ..orderBy(_orderBy(sort, dir))
          ..limit(limit, offset: offset))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  Stream<int> watchTotalCount({bool includeHidden = false}) {
    final countExp = _db.characters.charId.count();
    final query = _db.selectOnly(_db.characters)
      ..addColumns([countExp])
      ..where(_listPredicate(includeHidden));
    return query.watchSingle().map((row) => row.read(countExp) ?? 0);
  }

  @override
  Future<Character?> getById(String id) async {
    final row = await (_db.select(
      _db.characters,
    )..where((t) => t.charId.equals(id))).getSingleOrNull();
    return row != null ? _toModel(row) : null;
  }

  Future<Map<String, Character>> getByIds(Set<String> ids) async {
    if (ids.isEmpty) return {};
    final rows = await (_db.select(
      _db.characters,
    )..where((t) => t.charId.isIn(ids.toList()))).get();
    return {for (final r in rows) r.charId: _toModel(r)};
  }

  Future<void> setCurrentSessionIndex(String characterId, int index) async {
    await (_db.update(_db.characters)
          ..where((row) => row.charId.equals(characterId)))
        .write(CharactersCompanion(currentSessionIndex: Value(index)));
  }

  @override
  Future<void> put(Character character) async {
    // Cache the estimated token count on every write (import/save) so the UI
    // reads it instead of re-encoding during scroll/filter.
    final withTokens = character.copyWith(
      tokenCount: estimateCharacterTokens(character),
    );
    await _db
        .into(_db.characters)
        .insertOnConflictUpdate(_toCompanion(withTokens));
  }

  /// Writes [characters] in a single batch, so the reactive watchers emit
  /// **one** update instead of one per row.
  ///
  /// This is the mass-import path: writing a few hundred cards through [put]
  /// woke `watchAll` (and every list provider behind it) once per card, which
  /// re-read and re-decoded the whole — growing — table for every single file.
  Future<void> putAll(List<Character> characters) async {
    if (characters.isEmpty) return;
    final companions = <CharactersCompanion>[];
    for (final character in characters) {
      companions.add(
        _toCompanion(
          character.copyWith(tokenCount: estimateCharacterTokens(character)),
        ),
      );
      // Yield between encodes so a large chunk never blocks a frame.
      await Future<void>.delayed(Duration.zero);
    }
    await _db.batch((b) {
      b.insertAllOnConflictUpdate(_db.characters, companions);
    });
  }

  /// Computes and stores `tokenCount` for rows that still have the default 0
  /// (existing characters from before the column was added). Runs in one batch
  /// → a single reactive emission; safe to call unawaited at startup.
  Future<void> backfillMissingTokenCounts() async {
    final rows = await (_db.select(
      _db.characters,
    )..where((t) => t.tokenCount.equals(0))).get();
    if (rows.isEmpty) return;

    final updates = <String, int>{};
    for (final row in rows) {
      final count = estimateCharacterTokens(_toModel(row));
      if (count > 0) updates[row.charId] = count;
      // Yield between encodes so a large library doesn't jank the UI thread.
      await Future<void>.delayed(Duration.zero);
    }
    if (updates.isEmpty) return;

    await _db.batch((b) {
      updates.forEach((id, count) {
        b.update(
          _db.characters,
          CharactersCompanion(tokenCount: Value(count)),
          where: ($CharactersTable t) => t.charId.equals(id),
        );
      });
    });
  }

  Future<Map<String, dynamic>> updateExtensionsJson(
    String charId,
    Map<String, dynamic> Function(Map<String, dynamic> extensions) update,
  ) async {
    return _db.transaction(() async {
      final row = await (_db.select(
        _db.characters,
      )..where((t) => t.charId.equals(charId))).getSingleOrNull();
      if (row == null) {
        throw StateError('Character "$charId" was not found');
      }

      final current = _decodeJsonMap(row.extensionsJson);
      final updated = update(Map<String, dynamic>.from(current));
      await (_db.update(
        _db.characters,
      )..where((t) => t.charId.equals(charId))).write(
        CharactersCompanion(
          extensionsJson: Value(
            updated.isNotEmpty ? jsonEncode(updated) : null,
          ),
        ),
      );
      return updated;
    });
  }

  @override
  Future<void> delete(String id) async {
    await CharacterDeletionRepo(_db).deleteCharacters({id});
  }

  /// Membership predicate for a variation group. Legacy rows (and catalog
  /// imports predating the group backfill) can carry an empty
  /// `variant_group_id`; for a standalone character the group id is its own
  /// `char_id`, so those are matched by id too — otherwise the variations sheet
  /// came up empty for every character created before the column existed.
  Expression<bool> _groupPredicate($CharactersTable t, String groupId) =>
      t.variantGroupId.equals(groupId) |
      (t.variantGroupId.equals('') & t.charId.equals(groupId));

  /// All variations in a group, ordered by variant_order (representative first).
  Future<List<Character>> getVariants(String groupId) async {
    final rows =
        await (_db.select(_db.characters)
              ..where((t) => _groupPredicate(t, groupId))
              ..orderBy([(t) => OrderingTerm.asc(t.variantOrder)]))
            .get();
    return rows.map(_toModel).toList();
  }

  Stream<List<Character>> watchVariants(String groupId) {
    return (_db.select(_db.characters)
          ..where((t) => _groupPredicate(t, groupId))
          ..orderBy([(t) => OrderingTerm.asc(t.variantOrder)]))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  /// Per-group [VariantGroupStats] for the whole library, keyed by group id.
  ///
  /// Reads only the three columns the aggregate needs and folds them in Dart:
  /// legacy rows can still carry an empty `variant_group_id` (their group is
  /// their own `char_id`), which a plain SQL `GROUP BY variant_group_id` would
  /// collapse into one bogus bucket.
  Stream<Map<String, VariantGroupStats>> watchVariantGroupStats() {
    final query = _db.selectOnly(_db.characters)
      ..addColumns([
        _db.characters.charId,
        _db.characters.variantGroupId,
        _db.characters.fav,
      ]);
    return query.watch().map((rows) {
      final counts = <String, int>{};
      final favs = <String>{};
      for (final row in rows) {
        final id = row.read(_db.characters.charId) ?? '';
        final rawGroup = row.read(_db.characters.variantGroupId) ?? '';
        final groupId = rawGroup.isEmpty ? id : rawGroup;
        counts[groupId] = (counts[groupId] ?? 0) + 1;
        if (row.read(_db.characters.fav) ?? false) favs.add(groupId);
      }
      return {
        for (final entry in counts.entries)
          entry.key: VariantGroupStats(
            count: entry.value,
            anyFav: favs.contains(entry.key),
          ),
      };
    });
  }

  /// Avatar of each group's original (the `variant_order 0` row), keyed by
  /// group id.
  ///
  /// The chat list's collapsed group header stands for the whole character, so
  /// it shows the original's picture rather than whichever variation happened
  /// to be used last — that used to make a group's face change as you chatted.
  ///
  /// A future rather than a stream: its only caller already rebuilds on every
  /// character write.
  Future<Map<String, String?>> getGroupAvatars() async {
    final query = _db.selectOnly(_db.characters)
      ..addColumns([
        _db.characters.charId,
        _db.characters.variantGroupId,
        _db.characters.avatarPath,
      ])
      ..where(_db.characters.variantOrder.equals(0));
    final rows = await query.get();
    final avatars = <String, String?>{};
    for (final row in rows) {
      final id = row.read(_db.characters.charId) ?? '';
      final rawGroup = row.read(_db.characters.variantGroupId) ?? '';
      avatars[rawGroup.isEmpty ? id : rawGroup] = row.read(
        _db.characters.avatarPath,
      );
    }
    return avatars;
  }

  /// Favorites or unfavorites an entire variation group.
  ///
  /// The grid shows one card per group and treats "favorite" as an OR across
  /// its variations, so the toggle has to be group-wide — clearing the flag on
  /// the cover alone would leave the card still reading as favorited. Matches
  /// legacy empty-group-id rows by id, exactly like [setHidden].
  Future<void> setGroupFav(String groupId, bool fav) async {
    await (_db.update(_db.characters)
          ..where((t) => _groupPredicate(t, groupId)))
        .write(CharactersCompanion(fav: Value(fav)));
  }

  /// Next free variant_order for a group (max + 1, or 0 for a fresh group).
  Future<int> nextVariantOrder(String groupId) async {
    final maxExpr = _db.characters.variantOrder.max();
    final query = _db.selectOnly(_db.characters)
      ..addColumns([maxExpr])
      ..where(_groupPredicate(_db.characters, groupId));
    final row = await query.getSingleOrNull();
    final current = row?.read(maxExpr);
    return current == null ? 0 : current + 1;
  }

  /// Backfills `variant_group_id` for a character that predates the column, so
  /// it and the variations added to it form one queryable group. Called before
  /// the first variation is cloned off a legacy row — without it the group is
  /// split in two and both rows keep `variant_order 0`, which surfaces the same
  /// character twice in the library grid.
  Future<void> normalizeGroupId(String charId) async {
    await (_db.update(_db.characters)
          ..where((t) => t.charId.equals(charId) & t.variantGroupId.equals('')))
        .write(CharactersCompanion(variantGroupId: Value(charId)));
  }

  Future<void> renameVariant(String charId, String? name) async {
    final trimmed = name?.trim();
    await (_db.update(
      _db.characters,
    )..where((t) => t.charId.equals(charId))).write(
      CharactersCompanion(
        variantName: Value(trimmed == null || trimmed.isEmpty ? null : trimmed),
      ),
    );
  }

  /// Hides or reveals an entire variation group. Applied group-wide so that
  /// promoting a sibling on delete never resurfaces a hidden character. See
  /// [_groupPredicate] for why legacy rows are matched by id too.
  Future<void> setHidden(String groupId, bool hidden) async {
    await (_db.update(_db.characters)
          ..where((t) => _groupPredicate(t, groupId)))
        .write(CharactersCompanion(hidden: Value(hidden)));
  }

  /// Hides or reveals the variation groups of every character in [charIds] in a
  /// single transaction, so the reactive watchers emit **one** update instead of
  /// one per character (the bulk "hide selected" flow — otherwise cards vanish
  /// one-by-one as each write lands).
  Future<void> setHiddenMany(Set<String> charIds, bool hidden) async {
    if (charIds.isEmpty) return;
    await _db.transaction(() async {
      final ids = charIds.toList();
      final rows = await (_db.select(
        _db.characters,
      )..where((t) => t.charId.isIn(ids))).get();
      // Resolve each selected card to its whole variation group so hidden state
      // stays consistent (mirrors the single-character [setHidden] semantics).
      final groupIds = <String>{
        for (final r in rows)
          r.variantGroupId.isEmpty ? r.charId : r.variantGroupId,
      };
      if (groupIds.isEmpty) return;
      final groupList = groupIds.toList();
      await (_db.update(_db.characters)..where(
            (t) =>
                t.variantGroupId.isIn(groupList) |
                (t.variantGroupId.equals('') & t.charId.isIn(groupList)),
          ))
          .write(CharactersCompanion(hidden: Value(hidden)));
    });
  }

  Future<void> createCharacterFromCatalog({
    required String id,
    required String name,
    String description = '',
    String personality = '',
    String scenario = '',
    String firstMes = '',
    String mesExample = '',
    String creatorNotes = '',
    String systemPrompt = '',
    String postHistoryInstructions = '',
    List<String> alternateGreetings = const [],
    List<String> tags = const [],
    String creator = '',
    String creatorId = '',
    String? avatarPath,
    String? sourceUrl,
  }) async {
    final extensionsJson = (sourceUrl != null && sourceUrl.isNotEmpty)
        ? jsonEncode({'catalogUrl': sourceUrl})
        : null;
    await _db
        .into(_db.characters)
        .insertOnConflictUpdate(
          CharactersCompanion(
            charId: Value(id),
            // A catalog import is a standalone character: seed its group id so
            // group-wide operations (e.g. hide) can match it by id.
            variantGroupId: Value(id),
            name: Value(name),
            avatarPath: Value(avatarPath),
            description: Value(description),
            personality: Value(personality),
            scenario: Value(scenario),
            firstMes: Value(firstMes),
            mesExample: Value(mesExample),
            systemPrompt: Value(systemPrompt),
            postHistoryInstructions: Value(postHistoryInstructions),
            creator: Value(creator),
            creatorNotes: Value(creatorNotes),
            updatedAt: Value(currentTimestampSeconds()),
            createdAt: Value(currentTimestampSeconds()),
            tagsJson: Value(jsonEncode(tags)),
            alternateGreetingsJson: Value(jsonEncode(alternateGreetings)),
            extensionsJson: Value(extensionsJson),
            tokenCount: Value(
              estimateCharacterTokensFromParts(
                name: name,
                description: description,
                personality: personality,
                scenario: scenario,
                firstMes: firstMes,
                mesExample: mesExample,
              ),
            ),
          ),
        );
  }

  Character _toModel(CharacterRow c) {
    final extensions = c.extensionsJson != null
        ? Map<String, dynamic>.from(jsonDecode(c.extensionsJson!) as Map)
        : <String, dynamic>{};
    final rawDisplayName = extensions.remove('displayName');

    return Character(
      id: c.charId,
      name: c.name,
      displayName: rawDisplayName is String ? rawDisplayName : null,
      avatarPath: c.avatarPath,
      description: c.description,
      personality: c.personality,
      scenario: c.scenario,
      firstMes: c.firstMes,
      mesExample: c.mesExample,
      systemPrompt: c.systemPrompt,
      postHistoryInstructions: c.postHistoryInstructions,
      creator: c.creator,
      creatorNotes: c.creatorNotes,
      color: c.color,
      updatedAt: c.updatedAt,
      createdAt: c.createdAt,
      tags: c.tagsJson != null
          ? List<String>.from(jsonDecode(c.tagsJson!) as List<dynamic>)
          : [],
      alternateGreetings: c.alternateGreetingsJson != null
          ? List<String>.from(
              jsonDecode(c.alternateGreetingsJson!) as List<dynamic>,
            )
          : [],
      gallery: c.galleryJson != null
          ? (jsonDecode(c.galleryJson!) as List)
                .map((e) => GalleryEntry.fromJson(e as Map<String, dynamic>))
                .toList()
          : [],
      currentSessionIndex: c.currentSessionIndex,
      fav: c.fav,
      extensions: extensions,
      characterVersion: c.characterVersion,
      macroName: c.macroName,
      picksHash: c.picksHash,
      tokenCount: c.tokenCount,
      variantGroupId: c.variantGroupId.isEmpty ? c.charId : c.variantGroupId,
      variantName: c.variantName,
      variantOrder: c.variantOrder,
      hidden: c.hidden,
    );
  }

  CharactersCompanion _toCompanion(Character m) => CharactersCompanion(
    charId: Value(m.id),
    name: Value(m.name),
    avatarPath: Value(m.avatarPath),
    description: Value(m.description),
    personality: Value(m.personality),
    scenario: Value(m.scenario),
    firstMes: Value(m.firstMes),
    mesExample: Value(m.mesExample),
    systemPrompt: Value(m.systemPrompt),
    postHistoryInstructions: Value(m.postHistoryInstructions),
    creator: Value(m.creator),
    creatorNotes: Value(m.creatorNotes),
    color: Value(m.color),
    updatedAt: Value(m.updatedAt),
    createdAt: Value(m.createdAt),
    tagsJson: Value(jsonEncode(m.tags)),
    alternateGreetingsJson: Value(jsonEncode(m.alternateGreetings)),
    galleryJson: Value(jsonEncode(m.gallery.map((e) => e.toJson()).toList())),
    currentSessionIndex: Value(m.currentSessionIndex),
    fav: Value(m.fav),
    extensionsJson: Value(_encodeCharacterExtensions(m)),
    characterVersion: Value(m.characterVersion),
    macroName: Value(m.macroName),
    picksHash: Value(m.picksHash),
    tokenCount: Value(m.tokenCount),
    variantGroupId: Value(m.variantGroupId.isEmpty ? m.id : m.variantGroupId),
    variantName: Value(m.variantName),
    variantOrder: Value(m.variantOrder),
    hidden: Value(m.hidden),
  );

  String? _encodeCharacterExtensions(Character m) {
    final extensions = Map<String, dynamic>.from(m.extensions);
    final displayName = m.displayName?.trim();
    if (displayName != null && displayName.isNotEmpty) {
      extensions['displayName'] = displayName;
    } else {
      extensions.remove('displayName');
    }
    return extensions.isNotEmpty ? jsonEncode(extensions) : null;
  }

  Map<String, dynamic> _decodeJsonMap(String? text) {
    if (text == null || text.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return <String, dynamic>{};
  }
}
