import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/persona.dart';
import '../../core/state/db_provider.dart';
import '../../core/utils/id_generator.dart';
import '../../core/utils/sync_deletion_tracker.dart';
import '../../core/utils/time_helpers.dart';

final personaListProvider =
    AsyncNotifierProvider<PersonaListNotifier, List<Persona>>(
      PersonaListNotifier.new,
    );

class PersonaListNotifier extends AsyncNotifier<List<Persona>> {
  @override
  Future<List<Persona>> build() async {
    return ref.watch(personaRepoProvider).getAll();
  }

  Future<void> add(Persona persona) async {
    await ref.read(personaRepoProvider).put(persona);
    ref.invalidateSelf();
  }

  Future<void> updatePersona(Persona persona) async {
    await ref.read(personaRepoProvider).put(persona);
    ref.invalidateSelf();
  }

  /// Creates an independent copy of [persona] with a fresh id and a
  /// "(copy)" suffixed name. The avatar image path is shared with the source
  /// (personas reference the same avatar file). Returns the new persona.
  Future<Persona> clone(Persona persona) async {
    final copy = persona.copyWith(
      id: generateId(),
      name: '${persona.name} (copy)',
      createdAt: currentTimestampSeconds(),
    );
    await ref.read(personaRepoProvider).put(copy);
    ref.invalidateSelf();
    return copy;
  }

  Future<void> remove(String id) async {
    await ref.read(personaRepoProvider).delete(id);
    await SyncDeletionTracker.record('persona', id);
    ref.invalidateSelf();
  }
}
