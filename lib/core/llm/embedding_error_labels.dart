class EmbeddingErrorLabel {
  final String type;
  final String label;
  final bool retryable;

  const EmbeddingErrorLabel(this.type, this.label, this.retryable);

  static const _map = {
    'rate_limit': EmbeddingErrorLabel('rate_limit', 'Rate limited', true),
    'timeout': EmbeddingErrorLabel('timeout', 'Timeout', true),
    'config_endpoint': EmbeddingErrorLabel('config_endpoint', 'Endpoint not configured', false),
    'empty_text': EmbeddingErrorLabel('empty_text', 'Empty content', false),
    'api_error': EmbeddingErrorLabel('api_error', 'API error', true),
    'auth_error': EmbeddingErrorLabel('auth_error', 'Authentication failed', false),
    'model_not_found': EmbeddingErrorLabel('model_not_found', 'Model not found', false),
    'quota_exceeded': EmbeddingErrorLabel('quota_exceeded', 'Quota exceeded', true),
  };

  static EmbeddingErrorLabel classify(Map<String, dynamic>? error) {
    if (error == null) return const EmbeddingErrorLabel('unknown', 'Unknown', false);
    final type = error['type'] as String? ?? 'unknown';
    return _map[type] ?? EmbeddingErrorLabel(type, type.replaceAll('_', ' '), error['retryable'] as bool? ?? false);
  }
}
