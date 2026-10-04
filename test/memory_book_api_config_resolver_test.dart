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
  // A connection whose provider caps output well below the default.
  const capped = ApiConfig(id: 'capped', model: 'capped-model', maxTokens: 6000);

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

  test('output limit falls back to the connection, never a fixed number', () {
    const resolver = MemoryBookApiConfigResolver(
      apiConfigs: [active, memory, capped],
      activeConfig: active,
    );

    // Unset on the slot: whatever the connection is configured for. The old
    // generator hardcoded 25000 here, which providers that cap output plus
    // reasoning tokens rejected outright.
    expect(
      resolver.resolveMaxTokens(
        const MemoryBookApiSettings(apiConfigId: 'capped'),
      ),
      6000,
    );
    // Set on the slot: the slot wins over the connection.
    expect(
      resolver.resolveMaxTokens(
        const MemoryBookApiSettings(
          apiConfigId: 'capped',
          generationMaxTokens: 2000,
        ),
      ),
      2000,
    );
    // Neither names one — the custom-endpoint branch has no connection at all.
    expect(
      MemoryBookApiConfigResolver.maxTokensFor(
        const MemoryBookApiSettings(),
        null,
      ),
      kMemoryDraftFallbackMaxTokens,
    );
    // A zero stored by an older build reads as "unset", not as "no output".
    expect(
      MemoryBookApiConfigResolver.maxTokensFor(
        const MemoryBookApiSettings(generationMaxTokens: 0),
        const ApiConfig(id: 'x', maxTokens: 0),
      ),
      kMemoryDraftFallbackMaxTokens,
    );
  });

  test('temperature is the slot\'s own, or the drafting default', () {
    expect(
      MemoryBookApiConfigResolver.temperatureFor(const MemoryBookApiSettings()),
      kMemoryDraftDefaultTemperature,
    );
    expect(
      MemoryBookApiConfigResolver.temperatureFor(
        const MemoryBookApiSettings(generationTemperature: 1.1),
      ),
      1.1,
    );
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
