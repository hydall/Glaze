import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/studio_brief_parser.dart';
import 'package:glaze_flutter/core/llm/studio_controller_ontology.dart';
import 'package:glaze_flutter/core/models/studio_agent_codec.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

void main() {
  group('StudioAgentCodec', () {
    test('canonicalizes legacy identities and preserves other fields', () {
      final canonical = StudioAgentCodec.canonicalizeAgentsJson(
        jsonEncode([
          {
            'id': 'agent_session_continuity_123',
            'name': 'Renamed',
            'sourceBlockNames': 'legacy blocks',
            'temperature': 0.7,
            'customFutureField': {'kept': true},
          },
          {'id': 'custom', 'name': 'Dialogue Controller', 'maxTokens': 321},
        ]),
      );
      final agents = jsonDecode(canonical) as List<dynamic>;

      expect(agents[0]['controllerId'], 'continuity');
      expect(agents[0], isNot(contains('sourceBlockNames')));
      expect(agents[0]['temperature'], 0.7);
      expect(agents[0]['customFutureField'], {'kept': true});
      expect(agents[1]['controllerId'], 'dialogue');
      expect(agents[1]['maxTokens'], 321);
      expect(StudioAgentCodec.canonicalizeAgentsJson(canonical), canonical);
    });

    test('valid controller identity wins over a lower-priority collision', () {
      final decoded =
          jsonDecode(
                StudioAgentCodec.canonicalizeAgentsJson(
                  jsonEncode([
                    {'id': 'continuity', 'name': 'First'},
                    {
                      'id': 'second',
                      'controllerId': 'continuity',
                      'name': 'Second',
                    },
                  ]),
                ),
              )
              as List<dynamic>;

      expect(decoded[0]['controllerId'], isEmpty);
      expect(decoded[0]['enabled'], isFalse);
      expect(decoded[1]['controllerId'], 'continuity');
    });

    test('unresolved and ambiguous duplicate agents are disabled', () {
      final decoded =
          jsonDecode(
                StudioAgentCodec.canonicalizeAgentsJson(
                  jsonEncode([
                    {'id': 'unknown', 'name': 'Unknown', 'enabled': true},
                    {'id': 'final', 'name': 'First final'},
                    {'id': 'final', 'name': 'Second final'},
                  ]),
                ),
              )
              as List<dynamic>;

      expect(decoded[0]['controllerId'], isEmpty);
      expect(decoded[0]['enabled'], isFalse);
      expect(decoded[1]['controllerId'], isEmpty);
      expect(decoded[1]['enabled'], isFalse);
      expect(decoded[2]['controllerId'], isEmpty);
      expect(decoded[2]['enabled'], isFalse);
    });

    test('cloud config decoding ignores moved runtime fields', () {
      final config = StudioAgentCodec.decodeConfig({
        'sessionId': 'session',
        'runApiConfigId': 'legacy-api',
        'expensiveApiConfigId': 'explicit-api',
        'agents': [
          {'id': 'agent_session_continuity_123', 'sourceBlockNames': 'legacy'},
        ],
      });

      expect(config.toJson(), isNot(contains('agents')));
      expect(config.toJson(), isNot(contains('expensiveApiConfigId')));
      expect(config.toJson(), isNot(contains('runApiConfigId')));
    });

    test('backup row canonicalization migrates API slots and dead columns', () {
      final row = StudioAgentCodec.canonicalizeConfigRow({
        'session_id': 'session',
        'run_api_config_id': 'legacy-api',
        'expensive_api_config_id': '',
        'cheap_api_config_id': 'cheap-api',
        'cleaner_api_config_id': '',
        'final_preset_id': 'dead',
        'run_model_override': 'dead-model',
      });

      expect(row['expensive_api_config_id'], 'legacy-api');
      expect(row['cheap_api_config_id'], 'cheap-api');
      expect(row['cleaner_api_config_id'], 'legacy-api');
      expect(row, isNot(contains('final_preset_id')));
      expect(row, isNot(contains('run_api_config_id')));
      expect(row, isNot(contains('run_model_override')));
    });
  });

  group('canonical Studio runtime identity', () {
    test('defaults persist each exact controller id', () {
      final agents = StudioControllerOntology.buildDefaultAgents(
        sessionId: 'session',
        now: 123,
      );
      expect(
        agents.map((agent) => agent.controllerId),
        StudioControllerOntology.specs.map((spec) => spec.id),
      );
    });

    test('lookup and target routing do not infer from id, name, or order', () {
      const unknown = StudioAgent(
        id: 'continuity',
        name: 'Continuity Controller',
        order: 0,
      );
      const canonical = StudioAgent(
        id: 'arbitrary',
        controllerId: 'dialogue',
        name: 'Renamed',
        order: 8,
      );

      expect(StudioControllerOntology.specForAgent(unknown), isNull);
      expect(StudioControllerOntology.targetIdForAgent(unknown), isNull);
      expect(StudioControllerOntology.targetIdForAgent(canonical), 'dialogue');
    });

    test('meta policy detection is exact', () {
      final parser = StudioBriefParser((_) {});
      expect(
        parser.isMetaPolicyAgent(
          const StudioAgent(id: 'x', controllerId: 'meta'),
        ),
        isTrue,
      );
      expect(
        parser.isMetaPolicyAgent(
          const StudioAgent(id: 'meta', name: 'Meta-Weaver / OOC Policy'),
        ),
        isFalse,
      );
    });
  });
}
