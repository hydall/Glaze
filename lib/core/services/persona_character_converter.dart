import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/character.dart';
import '../models/persona.dart';
import '../../features/personas/persona_list_provider.dart';
import '../state/character_provider.dart';
import '../state/db_provider.dart';
import '../utils/id_generator.dart';
import '../utils/platform_paths.dart';
import '../utils/time_helpers.dart';

/// Conversions between [Persona] and [Character]. Each conversion creates a new
/// entity (with its own id and copied avatar file) and leaves the source intact.

/// Copies the avatar at [srcPath] into a fresh avatar file owned by [newId] so
/// the new entity never shares (and later orphans) the source's image. Returns
/// the saved path, or `null` when there is nothing to copy or the copy fails.
Future<String?> _copyAvatar(WidgetRef ref, String? srcPath, String newId) async {
  final src = srcPath?.trim();
  if (src == null || src.isEmpty) return null;
  try {
    final imageStorage = await ref.read(imageStorageProvider.future);
    final resolved = resolveGlazeFilePath(src) ?? src;
    final bytes = await File(resolved).readAsBytes();
    return imageStorage.saveAvatar(newId, bytes);
  } catch (_) {
    return null;
  }
}

/// Creates a [Character] from [persona] without deleting the persona. The
/// persona's prompt becomes the character's description. Returns the new
/// character.
Future<Character> convertPersonaToCharacter(
  WidgetRef ref,
  Persona persona,
) async {
  final newId = generateId();
  final avatarPath = await _copyAvatar(ref, persona.avatarPath, newId);
  final now = currentTimestampSeconds();

  final character = Character(
    id: newId,
    name: persona.name,
    displayName: persona.displayName,
    avatarPath: avatarPath,
    description: persona.prompt,
    createdAt: now,
    updatedAt: now,
  );

  await ref.read(charactersProvider.notifier).add(character);
  return character;
}

/// Creates a [Persona] from [character] without deleting the character. The
/// character's description becomes the persona's prompt. Returns the new
/// persona.
Future<Persona> convertCharacterToPersona(
  WidgetRef ref,
  Character character,
) async {
  final newId = generateId();
  final avatarPath = await _copyAvatar(ref, character.avatarPath, 'persona_$newId');

  final persona = Persona(
    id: newId,
    name: character.name,
    displayName: character.displayName,
    prompt: character.description,
    avatarPath: avatarPath,
    createdAt: currentTimestampSeconds(),
  );

  await ref.read(personaListProvider.notifier).add(persona);
  return persona;
}
