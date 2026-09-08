import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../models/persona.dart';
import '../models/preset.dart';
import 'shared_prefs_provider.dart';
import 'memory_settings_provider.dart';
import 'pipeline_settings_provider.dart';

export 'active_regex_provider.dart';
export 'persona_resolution.dart';
export 'preset_resolution.dart';

final activePresetIdProvider = StateProvider<String?>((ref) => null);
final activePersonaIdProvider = StateProvider<String?>((ref) => null);

final globalVarsProvider = StateProvider<Map<String, String>>((ref) => {});

final personaConnectionsProvider = StateProvider<PersonaConnections>((ref) {
  return const PersonaConnections();
});

final presetConnectionsProvider = StateProvider<PresetConnections>((ref) {
  return const PresetConnections();
});

Future<void> loadActiveSelections(WidgetRef ref) async {
  final prefs = await ref.read(sharedPreferencesProvider.future);
  ref.read(activePresetIdProvider.notifier).state = prefs.getString(
    'activePresetId',
  );
  ref.read(activePersonaIdProvider.notifier).state = prefs.getString(
    'activePersonaId',
  );
  final gvJson = prefs.getString('globalVars');
  if (gvJson != null) {
    try {
      final map = jsonDecode(gvJson) as Map<String, dynamic>;
      ref.read(globalVarsProvider.notifier).state = map.map(
        (k, v) => MapEntry(k, v.toString()),
      );
    } catch (_) {}
  }
  final pcJson = prefs.getString('personaConnections');
  if (pcJson != null) {
    try {
      ref
          .read(personaConnectionsProvider.notifier)
          .state = PersonaConnections.fromJson(
        jsonDecode(pcJson) as Map<String, dynamic>,
      );
    } catch (_) {}
  }
  final prConnJson = prefs.getString('presetConnections');
  if (prConnJson != null) {
    try {
      ref
          .read(presetConnectionsProvider.notifier)
          .state = PresetConnections.fromJson(
        jsonDecode(prConnJson) as Map<String, dynamic>,
      );
    } catch (_) {}
  }
  await ref.read(memoryGlobalSettingsProvider.notifier).load();
  await ref.read(pipelineSettingsProvider.notifier).load();
}

Future<void> setActivePreset(WidgetRef ref, String? id) async {
  ref.read(activePresetIdProvider.notifier).state = id;
  final prefs = await ref.read(sharedPreferencesProvider.future);
  if (id != null) {
    await prefs.setString('activePresetId', id);
  } else {
    await prefs.remove('activePresetId');
  }
}

Future<void> setActivePersona(WidgetRef ref, String? id) async {
  ref.read(activePersonaIdProvider.notifier).state = id;
  final prefs = await ref.read(sharedPreferencesProvider.future);
  if (id != null) {
    await prefs.setString('activePersonaId', id);
  } else {
    await prefs.remove('activePersonaId');
  }
}

PersonaConnections _buildUpdatedConnections(
  PersonaConnections current,
  String type,
  String targetId,
  String? personaId,
) {
  if (type == 'character') {
    final map = Map<String, String>.from(current.character);
    if (personaId == null) {
      map.remove(targetId);
    } else {
      map[targetId] = personaId;
    }
    return current.copyWith(character: map);
  } else {
    final map = Map<String, String>.from(current.chat);
    if (personaId == null) {
      map.remove(targetId);
    } else {
      map[targetId] = personaId;
    }
    return current.copyWith(chat: map);
  }
}

Future<void> setPersonaConnection(
  WidgetRef ref,
  String type,
  String targetId,
  String? personaId,
) async {
  final current = ref.read(personaConnectionsProvider);
  final updated = _buildUpdatedConnections(current, type, targetId, personaId);
  ref.read(personaConnectionsProvider.notifier).state = updated;
  final prefs = await ref.read(sharedPreferencesProvider.future);
  await prefs.setString('personaConnections', jsonEncode(updated.toJson()));
}

void setPersonaConnectionRef(
  Ref ref,
  String type,
  String targetId,
  String? personaId,
) {
  final current = ref.read(personaConnectionsProvider);
  final updated = _buildUpdatedConnections(current, type, targetId, personaId);
  ref.read(personaConnectionsProvider.notifier).state = updated;
  final prefs = ref.read(sharedPreferencesProvider).value;
  if (prefs != null) {
    prefs.setString('personaConnections', jsonEncode(updated.toJson()));
  }
}

void updateGlobalVarsRef(Ref ref, Map<String, String> vars) {
  ref.read(globalVarsProvider.notifier).state = vars;
  final prefs = ref.read(sharedPreferencesProvider).value;
  if (prefs != null) {
    prefs.setString('globalVars', jsonEncode(vars));
  }
}

// ─── Preset connections ───────────────────────────────────────────────────────

PresetConnections _buildUpdatedPresetConnections(
  PresetConnections current,
  String type,
  String targetId,
  String? presetId,
) {
  if (type == 'character') {
    final map = Map<String, String>.from(current.character);
    if (presetId == null) {
      map.remove(targetId);
    } else {
      map[targetId] = presetId;
    }
    return current.copyWith(character: map);
  } else {
    final map = Map<String, String>.from(current.chat);
    if (presetId == null) {
      map.remove(targetId);
    } else {
      map[targetId] = presetId;
    }
    return current.copyWith(chat: map);
  }
}

Future<void> setPresetConnection(
  WidgetRef ref,
  String type,
  String targetId,
  String? presetId,
) async {
  final current = ref.read(presetConnectionsProvider);
  final updated = _buildUpdatedPresetConnections(
    current,
    type,
    targetId,
    presetId,
  );
  ref.read(presetConnectionsProvider.notifier).state = updated;
  final prefs = await ref.read(sharedPreferencesProvider.future);
  await prefs.setString('presetConnections', jsonEncode(updated.toJson()));
}

void setPresetConnectionRef(
  Ref ref,
  String type,
  String targetId,
  String? presetId,
) {
  final current = ref.read(presetConnectionsProvider);
  final updated = _buildUpdatedPresetConnections(
    current,
    type,
    targetId,
    presetId,
  );
  ref.read(presetConnectionsProvider.notifier).state = updated;
  final prefs = ref.read(sharedPreferencesProvider).value;
  if (prefs != null) {
    prefs.setString('presetConnections', jsonEncode(updated.toJson()));
  }
}
