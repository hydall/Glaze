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

  setUp(() {
    logs.clear();
    parser = StudioBriefParser((msg) => logs.add(msg));
  });

  group('field-based brief parsing', () {
    test('parses beat_type, tempo, scene_pressure into Focus', () {
      const raw = '''
beat_type: social
tempo: medium
scene_pressure: medium
what_must_advance: Danvi orders a drink, Claire reads his posture
active_characters: Claire, Lucy
target_length: 800-1400 words
target_paragraphs: 6-10
stop_point: After Claire asks what Danvi wants
avoid_repeating: bar atmosphere paragraphs, neon descriptions
''';
      final result = parser.sanitizeIntermediateAgentOutput(narrativeAgent, raw);

      expect(result, contains('Focus:'));
      expect(result, contains('beat_type: social'));
      expect(result, contains('tempo: medium'));
      expect(result, contains('what_must_advance'));
      expect(result, contains('active_characters'));
      expect(result, contains('Constraints:'));
      expect(result, contains('target_length: 800-1400 words'));
      expect(result, contains('target_paragraphs: 6-10'));
      expect(result, contains('stop_point'));
      expect(result, contains('Avoid:'));
      expect(result, contains('avoid_repeating'));
      expect(logs, isEmpty);
    });

    test('returns null for single field (not enough signal)', () {
      const raw = 'beat_type: social\n';
      final result = parser.sanitizeIntermediateAgentOutput(narrativeAgent, raw);

      // Single field → recognized < 2 → falls through to fallback.
      expect(logs, isNotEmpty);
      expect(result, contains('Apply the default'));
    });

    test('field-based with unknown keys goes to constraints', () {
      const raw = '''
beat_type: combat
custom_field: some value
another_field: another value
''';
      final result = parser.sanitizeIntermediateAgentOutput(narrativeAgent, raw);

      expect(result, contains('Focus:'));
      expect(result, contains('beat_type: combat'));
      expect(result, contains('Constraints:'));
      expect(result, contains('custom_field'));
      expect(result, contains('another_field'));
    });

    test('does not break existing section-based parsing', () {
      const raw = '''
Focus:
- Beat: social, medium tempo
- Danvi sits at the bar

Constraints:
- Keep dialogue sparse
- Stop when Claire asks the question

Avoid:
- Neon descriptions
''';
      final result = parser.sanitizeIntermediateAgentOutput(narrativeAgent, raw);

      expect(result, contains('Focus:'));
      expect(result, contains('Beat: social'));
      expect(result, contains('Constraints:'));
      expect(result, contains('Keep dialogue sparse'));
      expect(result, contains('Avoid:'));
      expect(result, contains('Neon descriptions'));
      expect(logs, isEmpty);
    });

    test('rejects scene prose even with key: value lines', () {
      const raw = '''
*Клэр подходит к стойке. Её взгляд скользит по Данви.*
beat_type: social
*Она ставит стакан на столешницу с глухим стуком.*
''';
      final result = parser.sanitizeIntermediateAgentOutput(narrativeAgent, raw);

      expect(logs, isNotEmpty);
      expect(result, contains('Apply the default'));
    });
  });
}
