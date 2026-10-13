import '../../../../core/llm/tokenizer.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/state/persona_resolution.dart';
import '../../../../core/utils/id_generator.dart';
import '../../../chat/chat_provider.dart';
import '../../models/plugin_manifest.dart';
import '../plugin_api.dart';
import 'shapes.dart';

/// `glaze.messages.*` for the open chat, and `glaze.messages.variants.*` for
/// the alternative replies (swipes) of one message. Variant ids are their
/// position in the message's list.
Map<String, PluginMethod> messagesApi() => {
  'messages.list': const PluginMethod(_list, permission: _p),
  'messages.get': const PluginMethod(_get, permission: _p),
  'messages.count': const PluginMethod(_count, permission: _p),
  'messages.current': const PluginMethod(_current, permission: _p),
  'messages.add': const PluginMethod(_add, permission: _p),
  'messages.edit': const PluginMethod(_edit, permission: _p),
  'messages.remove': const PluginMethod(_remove, permission: _p),
  'messages.variants.list': const PluginMethod(_variants, permission: _p),
  'messages.variants.add': const PluginMethod(_variantAdd, permission: _p),
  'messages.variants.edit': const PluginMethod(_variantEdit, permission: _p),
  'messages.variants.remove': const PluginMethod(
    _variantRemove,
    permission: _p,
  ),
  'messages.variants.select': const PluginMethod(
    _variantSelect,
    permission: _p,
  ),
};

const _p = PluginPermission.messages;

List<ChatMessage> _messages(PluginCall c) =>
    c.ref.read(chatProvider(c.host.charId)).value?.session?.messages ??
    const [];

Map<String, Object?> _json(PluginCall c, ChatMessage m, int index) =>
    messageJson(m, index: index, characterId: c.host.charId);

int? _int(Object? v) => v is num ? v.toInt() : null;

Future<Object?> _list(PluginCall c) async {
  final all = _messages(c);
  final range = c.arg(0);
  int norm(int i) => i < 0 ? all.length + i : i;
  var start = 0;
  var end = all.length - 1;
  if (range is num) {
    start = end = norm(range.toInt());
  } else if (range is List && range.isNotEmpty) {
    start = norm(_int(range[0]) ?? 0);
    if (range.length > 1) end = norm(_int(range[1]) ?? end);
  }
  start = start.clamp(0, all.length);
  end = end.clamp(-1, all.length - 1);
  final filter = c.mapArg(1);
  final role = filter['role'];
  final hidden = filter['hidden'];
  return [
    for (var i = start; i <= end; i++)
      if ((role == null || all[i].role == role) &&
          (hidden is! bool || all[i].isHidden == hidden))
        _json(c, all[i], i),
  ];
}

int _indexOf(List<ChatMessage> all, Object? ref) {
  if (ref is Map && ref['index'] is num) {
    final i = (ref['index'] as num).toInt();
    return i < 0 ? all.length + i : i;
  }
  final id = ref is Map ? ref['id'] : ref;
  if (id == null) return -1;
  return all.indexWhere((m) => m.id == id.toString());
}

Future<Object?> _get(PluginCall c) async {
  final all = _messages(c);
  final index = _indexOf(all, c.arg(0));
  if (index < 0 || index >= all.length) return null;
  return _json(c, all[index], index);
}

Future<Object?> _count(PluginCall c) async => _messages(c).length;

Future<Object?> _current(PluginCall c) async {
  final id = c.messageId;
  if (id == null) return null;
  final all = _messages(c);
  final index = all.indexWhere((m) => m.id == id);
  return index < 0 ? null : _json(c, all[index], index);
}

/// Runs [mutate] on the open session's messages through the chat's write
/// queue. [mutate] returns the new list, or null to leave it unchanged.
Future<void> _mutate(
  PluginCall c,
  List<ChatMessage>? Function(List<ChatMessage> latest) mutate,
) async {
  c.requireSession();
  Object? failure;
  try {
    await c.ref
        .read(chatProvider(c.host.charId).notifier)
        .mutateMessagesForPlugin((latest) {
          try {
            return mutate(latest) ?? latest;
          } catch (e) {
            failure = e;
            return latest;
          }
        });
  } on StateError catch (e) {
    throw PluginApiError('busy', e.message);
  }
  if (failure != null) throw failure!;
}

ChatMessage _require(List<ChatMessage> all, String id) {
  final m = all.where((m) => m.id == id).firstOrNull;
  if (m == null) throw PluginApiError('not_found', 'No message $id');
  return m;
}

Future<Object?> _add(PluginCall c) async {
  final data = c.mapArg(0);
  final content = data['content'];
  if (content is! String) {
    throw const PluginApiError('invalid_arguments', 'content is required');
  }
  final role = data['role'] == 'user' ? 'user' : 'assistant';
  final persona = role == 'user'
      ? c.ref.read(
          effectivePersonaForChatProvider((
            charId: c.host.charId,
            sessionId: c.host.sessionId,
          )),
        )
      : null;
  final message = ChatMessage(
    id: generateId(),
    role: role,
    content: content,
    timestamp: DateTime.now().millisecondsSinceEpoch,
    tokens: estimateTokens(content),
    isHidden: data['hidden'] == true,
    swipes: role == 'assistant' ? [content] : const [],
    personaId: persona?.id,
    personaName: persona?.name,
  );
  await _mutate(c, (latest) => [...latest, message]);
  return message.id;
}

Future<Object?> _edit(PluginCall c) async {
  final data = c.mapArg(0);
  final id = data['id']?.toString();
  if (id == null) {
    throw const PluginApiError('invalid_arguments', 'id is required');
  }
  await _mutate(c, (latest) {
    final m = _require(latest, id);
    var next = m;
    final content = data['content'];
    if (content is String) {
      final swipes = [...m.swipes];
      if (m.swipeId >= 0 && m.swipeId < swipes.length) {
        swipes[m.swipeId] = content;
      }
      next = next.copyWith(
        content: content,
        swipes: swipes,
        tokens: estimateTokens(content),
      );
    }
    if (data.containsKey('reasoning')) {
      final r = data['reasoning']?.toString();
      next = next.copyWith(reasoning: r == null || r.isEmpty ? null : r);
    }
    if (data['hidden'] is bool) {
      next = next.copyWith(isHidden: data['hidden'] as bool);
    }
    return [for (final x in latest) x.id == id ? next : x];
  });
  return id;
}

Future<Object?> _remove(PluginCall c) async {
  final id = c.requireString(0, 'id');
  await _mutate(c, (latest) {
    _require(latest, id);
    return [
      for (final x in latest)
        if (x.id != id) x,
    ];
  });
  return id;
}

/* ---------- variants ---------- */

List<String> _swipesOf(ChatMessage m) =>
    m.swipes.isEmpty ? [m.content] : [...m.swipes];

List<Map<String, dynamic>> _metaOf(ChatMessage m, int length) => [
  for (var i = 0; i < length; i++)
    i < m.swipesMeta.length ? {...m.swipesMeta[i]} : <String, dynamic>{},
];

Future<Object?> _variants(PluginCall c) async {
  final m = _require(_messages(c), c.requireString(0, 'messageId'));
  final swipes = _swipesOf(m);
  final meta = _metaOf(m, swipes.length);
  return [
    for (var i = 0; i < swipes.length; i++)
      if (i != m.swipeId)
        {
          'id': i,
          'content': swipes[i],
          if (meta[i]['reasoning'] case final String r) 'reasoning': r,
        },
  ];
}

Future<Object?> _variantAdd(PluginCall c) async {
  final messageId = c.requireString(0, 'messageId');
  final data = c.mapArg(1);
  final content = data['content'];
  if (content is! String) {
    throw const PluginApiError('invalid_arguments', 'content is required');
  }
  final reasoning = data['reasoning']?.toString();
  final select = c.mapArg(2)['select'] != false;
  var created = -1;
  await _mutate(c, (latest) {
    final m = _require(latest, messageId);
    final swipes = _swipesOf(m)..add(content);
    final meta = _metaOf(m, swipes.length - 1)..add({'reasoning': ?reasoning});
    created = swipes.length - 1;
    var next = m.copyWith(swipes: swipes, swipesMeta: meta);
    if (select) {
      next = next.copyWith(
        swipeId: created,
        content: content,
        reasoning: reasoning,
        tokens: estimateTokens(content),
      );
    }
    return [for (final x in latest) x.id == messageId ? next : x];
  });
  return created;
}

int _variantId(PluginCall c, Object? raw) {
  final id = raw is num ? raw.toInt() : int.tryParse('$raw');
  if (id == null) {
    throw const PluginApiError('invalid_arguments', 'variant id is required');
  }
  return id;
}

Future<Object?> _variantEdit(PluginCall c) async {
  final messageId = c.requireString(0, 'messageId');
  final data = c.mapArg(1);
  final id = _variantId(c, data['id']);
  await _mutate(c, (latest) {
    final m = _require(latest, messageId);
    final swipes = _swipesOf(m);
    if (id < 0 || id >= swipes.length || id == m.swipeId) {
      throw const PluginApiError(
        'invalid_arguments',
        'Only other variants can be edited; edit the message itself instead',
      );
    }
    final meta = _metaOf(m, swipes.length);
    if (data['content'] is String) swipes[id] = data['content'] as String;
    if (data.containsKey('reasoning')) {
      final r = data['reasoning'];
      if (r == null) {
        meta[id].remove('reasoning');
      } else {
        meta[id]['reasoning'] = r.toString();
      }
    }
    final next = m.copyWith(swipes: swipes, swipesMeta: meta);
    return [for (final x in latest) x.id == messageId ? next : x];
  });
  return id;
}

Future<Object?> _variantRemove(PluginCall c) async {
  final messageId = c.requireString(0, 'messageId');
  final id = _variantId(c, c.arg(1));
  await _mutate(c, (latest) {
    final m = _require(latest, messageId);
    final swipes = _swipesOf(m);
    if (id < 0 || id >= swipes.length || id == m.swipeId) {
      throw const PluginApiError(
        'invalid_arguments',
        'The shown variant cannot be removed',
      );
    }
    final meta = _metaOf(m, swipes.length)..removeAt(id);
    swipes.removeAt(id);
    final next = m.copyWith(
      swipes: swipes,
      swipesMeta: meta,
      swipeId: id < m.swipeId ? m.swipeId - 1 : m.swipeId,
    );
    return [for (final x in latest) x.id == messageId ? next : x];
  });
  return id;
}

Future<Object?> _variantSelect(PluginCall c) async {
  final messageId = c.requireString(0, 'messageId');
  final id = _variantId(c, c.arg(1));
  final all = _messages(c);
  final index = all.indexWhere((m) => m.id == messageId);
  if (index < 0) throw PluginApiError('not_found', 'No message $messageId');
  if (id < 0 || id >= _swipesOf(all[index]).length) {
    throw const PluginApiError('invalid_arguments', 'No such variant');
  }
  await c.ref.read(chatProvider(c.host.charId).notifier).setSwipe(index, id);
  return id;
}
