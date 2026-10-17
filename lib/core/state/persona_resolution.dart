import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../models/persona.dart';
import 'active_selection_provider.dart';
import '../../features/personas/persona_list_provider.dart';

Persona? getEffectivePersona(
  List<Persona> personas,
  String? charId,
  String? sessionId,
  String? globalPersonaId,
  PersonaConnections connections,
) {
  if (sessionId != null) {
    final chatPersonaId = connections.chat[sessionId];
    if (chatPersonaId != null) {
      final p = personas.where((p) => p.id == chatPersonaId).firstOrNull;
      if (p != null) return p;
    }
  }
  if (charId != null) {
    final charPersonaId = connections.character[charId];
    if (charPersonaId != null) {
      final p = personas.where((p) => p.id == charPersonaId).firstOrNull;
      if (p != null) return p;
    }
  }
  if (globalPersonaId != null) {
    final p = personas.where((p) => p.id == globalPersonaId).firstOrNull;
    if (p != null) return p;
  }
  return personas.isNotEmpty ? personas.first : null;
}

typedef EffectivePersonaChatKey = ({String charId, String? sessionId});

/// The chat the user is in, or was last in: the character and the session on
/// screen. Screens outside the chat (the Tools tile) read it to show the
/// persona that chat actually speaks as, not just the global default, which a
/// chat or character binding overrides.
final lastOpenChatProvider = StateProvider<EffectivePersonaChatKey?>(
  (ref) => null,
);

/// True when the chat [key] has a binding (its own, or its character's) that
/// resolves to an existing persona — one that wins over the global selection.
bool hasPersonaBinding(
  List<Persona> personas,
  PersonaConnections connections,
  EffectivePersonaChatKey key,
) {
  bool exists(String? id) => id != null && personas.any((p) => p.id == id);
  final sessionId = key.sessionId;
  return (sessionId != null && exists(connections.chat[sessionId])) ||
      exists(connections.character[key.charId]);
}

/// Makes [personaId] the persona the chat [key] speaks as, or, with no chat,
/// the global one. A chat whose character or own binding overrides the global
/// selection is rebound itself — setting only the global persona there changed
/// nothing in the chat while the list showed the pick as active.
Future<void> selectPersonaFor(
  WidgetRef ref,
  EffectivePersonaChatKey? key,
  String? personaId,
) async {
  final personas = ref.read(personaListProvider).value ?? const <Persona>[];
  final connections = ref.read(personaConnectionsProvider);
  final sessionId = key?.sessionId;
  if (key != null &&
      sessionId != null &&
      hasPersonaBinding(personas, connections, key)) {
    // Deselecting drops the chat's own binding: the chat falls back to its
    // character's binding, or to the global persona when there is none.
    await setPersonaConnection(ref, 'chat', sessionId, personaId);
    return;
  }
  await setActivePersona(ref, personaId);
}

final effectivePersonaForChatProvider =
    Provider.family<Persona?, EffectivePersonaChatKey>((ref, key) {
      final personasAsync = ref.watch(personaListProvider);
      if (!personasAsync.hasValue) return null;

      final activePersonaId = ref.watch(activePersonaIdProvider);
      final personaConnections = ref.watch(personaConnectionsProvider);
      return getEffectivePersona(
        personasAsync.requireValue,
        key.charId,
        key.sessionId,
        activePersonaId,
        personaConnections,
      );
    });
