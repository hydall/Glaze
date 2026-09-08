import 'package:flutter_riverpod/flutter_riverpod.dart';

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
