import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/studio_activation_gate.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

void main() {
  final staleAgents = <StudioAgent>[
    const StudioAgent(id: 'agent_s_continuity', name: 'Continuity Controller'),
    const StudioAgent(
      id: 'agent_s_agency',
      name: 'Agency & Character Controller',
    ),
    const StudioAgent(
      id: 'agent_s_narrative',
      name: 'Narrative / Pacing / Style Controller',
    ),
    const StudioAgent(id: 'agent_s_dialogue', name: 'Dialogue Controller'),
    const StudioAgent(id: 'agent_s_guard', name: 'Anti-Loop & Prose Guard'),
    const StudioAgent(id: 'agent_s_world', name: 'World / NPC Controller'),
    const StudioAgent(id: 'agent_s_meta', name: 'Meta-Weaver / OOC Policy'),
    const StudioAgent(id: 'agent_s_beauty', name: 'Beauty Shard'),
    const StudioAgent(id: 'agent_s_final', name: 'Main Responder'),
  ];

  test('direct mode blocks every stale pregen controller except final', () {
    final gated = StudioActivationGate.applyExecutionMode(
      staleAgents,
      StudioExecutionMode.direct,
    );

    expect(gated.where((agent) => agent.enabled).map((agent) => agent.name), [
      'Main Responder',
    ]);
  });

  test('assisted permits continuity, scene director, beauty, and final', () {
    final gated = StudioActivationGate.applyExecutionMode(
      staleAgents,
      StudioExecutionMode.assisted,
    );

    expect(gated.where((agent) => agent.enabled).map((agent) => agent.name), [
      'Continuity Controller',
      'Narrative / Pacing / Style Controller',
      'Beauty Shard',
      'Main Responder',
    ]);
  });

  test('topology reports controllers that a mode cannot enable', () {
    expect(
      StudioActivationGate.isControllerAllowed(
        'beauty',
        StudioExecutionMode.direct,
      ),
      isFalse,
    );
    expect(
      StudioActivationGate.isControllerAllowed(
        'beauty',
        StudioExecutionMode.assisted,
      ),
      isTrue,
    );
    expect(
      StudioActivationGate.isControllerAllowed(
        'meta',
        StudioExecutionMode.direct,
      ),
      isFalse,
    );
    expect(
      StudioActivationGate.isControllerAllowed(
        'narrative',
        StudioExecutionMode.assisted,
      ),
      isTrue,
    );
  });
}
