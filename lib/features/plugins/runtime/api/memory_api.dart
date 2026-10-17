import '../../../../core/models/memory_book.dart';
import '../../../../core/models/memory_entry_revisions.dart';
import '../../../../core/state/db_provider.dart';
import '../../../../core/utils/id_generator.dart';
import '../../../memory/state/memory_book_revision_provider.dart';
import '../../models/plugin_manifest.dart';
import '../plugin_api.dart';

/// `glaze.memory.*`: the open chat's memory book.
Map<String, PluginMethod> memoryApi() => {
  'memory.get': const PluginMethod(_get, permission: PluginPermission.messages),
  'memory.update': const PluginMethod(
    _update,
    permission: PluginPermission.messages,
  ),
  'memory.append': const PluginMethod(
    _append,
    permission: PluginPermission.messages,
  ),
};

Map<String, Object?> _entryJson(MemoryEntry e) => {
  'id': e.id,
  'title': e.title,
  'content': e.content,
  'keys': e.keys,
  'status': e.status,
};

MemoryEntry _entry(Object? raw) {
  if (raw is String) {
    return MemoryEntryRevisions.initialize(
      MemoryEntry(
        id: generateId(),
        content: raw,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
      author: 'plugin',
      reason: 'plugin_create',
    );
  }
  if (raw is Map && raw['content'] is String) {
    return MemoryEntryRevisions.initialize(
      MemoryEntry(
        id: raw['id']?.toString() ?? generateId(),
        title: raw['title']?.toString() ?? '',
        content: raw['content'] as String,
        keys: [
          for (final k
              in (raw['keys'] is List ? raw['keys'] as List : const []))
            k.toString(),
        ],
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
      author: 'plugin',
      reason: 'plugin_create',
    );
  }
  throw const PluginApiError(
    'invalid_arguments',
    'A memory is a string or { title?, content, keys? }',
  );
}

void _changed(PluginCall c, String sessionId) {
  c.ref.invalidate(memoryBookProvider(sessionId));
  c.ref.read(memoryBookRevisionProvider.notifier).state++;
}

Future<Object?> _get(PluginCall c) async {
  final sessionId = c.requireSession();
  final book = await c.ref
      .read(memoryBookRepoProvider)
      .ensureForSession(sessionId);
  return {
    'enabled': book.settings.enabled,
    'entries': [for (final e in book.entries) _entryJson(e)],
  };
}

Future<Object?> _update(PluginCall c) async {
  final sessionId = c.requireSession();
  final data = c.mapArg(0);
  final repo = c.ref.read(memoryBookRepoProvider);
  final book = await repo.ensureForSession(sessionId);
  var next = book;
  if (data['enabled'] is bool) {
    next = next.copyWith(
      settings: next.settings.copyWith(enabled: data['enabled'] as bool),
    );
  }
  if (data['entries'] is List) {
    final byId = {for (final e in book.entries) e.id: e};
    MemoryEntry merge(Object? raw) {
      final old = raw is Map ? byId[raw['id']?.toString()] : null;
      if (old == null || raw is! Map) return _entry(raw);
      return old.copyWith(
        title: raw['title']?.toString() ?? old.title,
        content: raw['content']?.toString() ?? old.content,
        keys: raw['keys'] is List
            ? [for (final k in raw['keys'] as List) k.toString()]
            : old.keys,
      );
    }

    next = next.copyWith(
      entries: [for (final raw in data['entries'] as List) merge(raw)],
    );
  }
  await repo.put(next);
  _changed(c, sessionId);
  return null;
}

Future<Object?> _append(PluginCall c) async {
  final sessionId = c.requireSession();
  final raw = c.arg(0);
  final entries = [
    for (final x in (raw is List ? raw : [raw])) _entry(x),
  ];
  final repo = c.ref.read(memoryBookRepoProvider);
  await repo.ensureForSession(sessionId);
  await repo.appendApprovedEntries(sessionId, entries);
  _changed(c, sessionId);
  final book = await repo.getBySessionId(sessionId);
  return {
    'added': [for (final e in entries) e.id],
    'total': book?.entries.length ?? entries.length,
    'enabled': book?.settings.enabled ?? true,
  };
}
