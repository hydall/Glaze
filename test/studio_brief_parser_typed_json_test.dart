import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/studio_brief_parser.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

void main() {
  late StudioBriefParser parser;
  final logs = <String>[];
  final narrativeAgent = const StudioAgent(
    id: 'narrative',
    name: 'Narrative / Pacing / Style Controller',
    sourceBlockNames: 'narrative_task',
  );
  final dialogueAgent = const StudioAgent(
    id: 'dialogue',
    name: 'Dialogue Controller',
    sourceBlockNames: 'dialogue_task',
  );

  setUp(() {
    logs.clear();
    parser = StudioBriefParser((msg) => logs.add(msg));
  });

  group('typed-JSON brief parsing (semantic keys)', () {
    test('parses JSON with capitalized Focus key', () {
      const raw = '{"Focus":["Beat: action, tempo: medium"]}';
      final result = parser.sanitizeIntermediateAgentOutput(narrativeAgent, raw);

      expect(result, isNotNull);
      expect(result, contains('Focus:'));
      expect(result, contains('Beat: action'));
      expect(logs, isEmpty);
    });

    test('parses JSON with semantic keys → correct sections', () {
      const raw = '''
{"beat_type":"action","tempo":"medium","scene_pressure":"medium-high",
"what_must_advance":"Helga gives concrete navigation",
"target_length":"800-1400 words","target_paragraphs":"6-10",
"avoid_repeating":"bar atmosphere paragraphs"}
''';
      final result = parser.sanitizeIntermediateAgentOutput(narrativeAgent, raw);

      expect(result, isNotNull);
      expect(result, contains('Focus:'));
      expect(result, contains('beat_type: action'));
      expect(result, contains('what_must_advance: Helga'));
      expect(result, contains('Constraints:'));
      expect(result, contains('target_length: 800-1400 words'));
      expect(result, contains('target_paragraphs: 6-10'));
      expect(result, contains('Avoid:'));
      expect(result, contains('avoid_repeating'));
      expect(logs, isEmpty);
    });

    test('parses JSON with dialogue-controller semantic keys', () {
      const raw = '''
{"who_can_speak":["Helga - via HUD/audio, cyberdeck link"],
"who_should_not_speak":["Lucy, Bestia, Clare, Smasher - not present"],
"speech_mode":"exchange",
"low_speech_reason":"n/a - Helga is remote"}
''';
      final result = parser.sanitizeIntermediateAgentOutput(dialogueAgent, raw);

      expect(result, isNotNull);
      expect(result, contains('Constraints:'));
      expect(result, contains('who_can_speak'));
      expect(result, contains('who_should_not_speak'));
      expect(result, contains('speech_mode: exchange'));
      expect(result, contains('low_speech_reason'));
      expect(logs, isEmpty);
    });

    test('unknown semantic keys go to constraints', () {
      const raw = '{"custom_key":"some value","another_key":"another value"}';
      final result = parser.sanitizeIntermediateAgentOutput(narrativeAgent, raw);

      expect(result, isNotNull);
      expect(result, contains('Constraints:'));
      expect(result, contains('custom_key: some value'));
      expect(result, contains('another_key: another value'));
    });

    test('mixes canonical and semantic keys', () {
      const raw = '''
{"Focus":["Beat: social"],"beat_type":"social","avoid":["neon"],"avoid_repeating":"neon"}
''';
      final result = parser.sanitizeIntermediateAgentOutput(narrativeAgent, raw);

      expect(result, isNotNull);
      expect(result, contains('Focus:'));
      expect(result, contains('Beat: social'));
      expect(result, contains('beat_type: social'));
      expect(result, contains('Avoid:'));
      // "neon" from avoid (canonical) and "avoid_repeating: neon" from semantic
      // are different strings — both appear, no exact duplicates.
      final avoidSection = result.split('Avoid:').last;
      // Count lines containing "neon"
      final neonLines = avoidSection
          .split('\n')
          .where((l) => l.contains('neon'))
          .length;
      expect(neonLines, 2); // "neon" and "avoid_repeating: neon"
    });

    test('still rejects truly empty JSON', () {
      const raw = '{"focus":[],"constraints":[],"avoid":[],"options":[]}';
      final result =
          parser.sanitizeIntermediateAgentOutput(narrativeAgent, raw);

      expect(logs, isNotEmpty);
      expect(result, contains('Apply the default'));
    });
  });
}
