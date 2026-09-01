import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/memory_book_api_config_resolver.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/memory_book_api_settings.dart';

void main() {
  const active = ApiConfig(id: 'active', model: 'active-model');
  const memory = ApiConfig(
    id: 'memory',
    model: 'memory-model',
    firstChunkTimeoutMs: 240000,
  );

  test('uses selected Memory Books connection without changing active', () {
    const resolver = MemoryBookApiConfigResolver(
      apiConfigs: [active, memory],
      activeConfig: active,
    );

    final resolved = resolver.resolve(
      const MemoryBookApiSettings(apiConfigId: 'memory'),
    );

    expect(resolved, memory);
    expect(
      resolver.resolveTimeoutMs(
        const MemoryBookApiSettings(apiConfigId: 'memory'),
      ),
      240000,
    );
    expect(resolver.activeConfig, active);
  });

  test('falls back to active connection for empty or missing id', () {
    const resolver = MemoryBookApiConfigResolver(
      apiConfigs: [active],
      activeConfig: active,
    );

    expect(resolver.resolve(const MemoryBookApiSettings()), active);
    expect(
      resolver.resolve(const MemoryBookApiSettings(apiConfigId: 'deleted')),
      active,
    );
  });
}
