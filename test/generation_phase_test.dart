// The typing bubble used to read "Generating..." from the moment it appeared —
// while the app was still collecting context, retrieving memory and building
// the prompt. Every phase the run walks through now has a label, so these
// tests guard the two things that break silently: a phase without a
// translation, and a phase whose label leaks after the run settles.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/generation_phase.dart';
import 'package:glaze_flutter/features/chat/state/generation_phase_provider.dart';

Map<String, String> _translations(String path) {
  final decoded = jsonDecode(File(path).readAsStringSync()) as Map;
  return decoded.map((key, value) => MapEntry('$key', '$value'));
}

void main() {
  test('every generation phase has an EN and RU label', () {
    final en = _translations('assets/translations/en.json');
    final ru = _translations('assets/translations/ru.json');

    for (final phase in GenerationPhase.values) {
      final key = phase.translationKey;
      expect(
        en,
        contains(key),
        reason: '$phase has no English label ($key)',
      );
      expect(ru, contains(key), reason: '$phase has no Russian label ($key)');
      expect(
        en[key],
        isNotEmpty,
        reason: '$phase would render as an empty bubble in English',
      );
      expect(
        ru[key],
        isNotEmpty,
        reason: '$phase would render as an empty bubble in Russian',
      );
    }
  });

  test('phases that are visibly different do not share a label', () {
    final en = _translations('assets/translations/en.json');
    // idle borrows the streaming key so the enum has no null case; every
    // other phase must name its own stage, or the label stops being
    // information the reader can act on.
    final labelled = GenerationPhase.values
        .where((phase) => phase != GenerationPhase.idle)
        .map((phase) => en[phase.translationKey])
        .toList();
    expect(labelled.toSet().length, labelled.length);
  });

  test('an idle run pushes an empty label, not its last phase', () {
    // The page falls back to its own default text, so a bubble that outlives
    // the run never keeps claiming "Waiting for the model…".
    expect(generationPhaseLabel(GenerationPhase.idle), isEmpty);
  });
}
