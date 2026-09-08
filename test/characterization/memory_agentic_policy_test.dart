import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/memory_agentic_policy.dart';

void main() {
  test('agentic mode is disabled by default', () {
    const policy = MemoryAgenticPolicy(MemoryAgenticSettings());

    final decision = policy.canUse(MemoryAgenticTool.inspectContext);

    expect(decision.allowed, isFalse);
    expect(decision.reason, 'agentic_disabled');
  });

  test('enabled agentic scaffold allows read-only proposal tools', () {
    const policy = MemoryAgenticPolicy(MemoryAgenticSettings(enabled: true));

    expect(policy.canUse(MemoryAgenticTool.inspectContext).allowed, isTrue);
    expect(policy.canUse(MemoryAgenticTool.proposeMemory).allowed, isTrue);
    expect(policy.canUse(MemoryAgenticTool.proposeTracker).allowed, isTrue);
  });
}
