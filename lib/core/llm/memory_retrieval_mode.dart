/// Retrieval behavior enabled by a Memory Book mode.
///
/// Modern modes are intentionally cumulative. Legacy is a separate rollback
/// path rather than the first rung of the modern ladder.
enum MemoryRetrievalCapability {
  modernSelector,
  catalogMatching,
  salienceEnrichment,
  entityEnrichment,
  emotionEnrichment,
  missingContextDiagnostics,
  extendedPromptContext,
}

enum MemoryRetrievalMode {
  legacy('legacy'),
  fast('fast'),
  balanced('balanced'),
  deep('deep');

  const MemoryRetrievalMode(this.value);

  final String value;

  static MemoryRetrievalMode fromValue(String value) => switch (value) {
    'legacy' => legacy,
    'balanced' => balanced,
    'deep' || 'agentic' => deep,
    _ => fast,
  };

  bool get isLegacy => this == legacy;

  Set<MemoryRetrievalCapability> get capabilities => switch (this) {
    legacy => const {},
    fast => _fastCapabilities,
    balanced => _balancedCapabilities,
    // There is currently no separate retrieval LLM/reranker. Deep therefore
    // consumes every available local/vector signal: the complete Balanced
    // capability set. Keeping this explicit prevents it from accidentally
    // dropping catalog matching when deeper integrations change.
    deep => _deepCapabilities,
  };

  bool supports(MemoryRetrievalCapability capability) =>
      capabilities.contains(capability);
}

const _fastCapabilities = <MemoryRetrievalCapability>{
  MemoryRetrievalCapability.modernSelector,
};

const _balancedCapabilities = <MemoryRetrievalCapability>{
  ..._fastCapabilities,
  MemoryRetrievalCapability.catalogMatching,
  MemoryRetrievalCapability.salienceEnrichment,
  MemoryRetrievalCapability.entityEnrichment,
  MemoryRetrievalCapability.emotionEnrichment,
  MemoryRetrievalCapability.missingContextDiagnostics,
  MemoryRetrievalCapability.extendedPromptContext,
};

const _deepCapabilities = <MemoryRetrievalCapability>{..._balancedCapabilities};
