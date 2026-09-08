import 'package:dio/dio.dart';

class EmbeddingRequestGate {
  EmbeddingRequestGate._();

  static bool _enabled = true;
  static final Set<CancelToken> _activeTokens = {};

  static void setEnabled(bool enabled) {
    _enabled = enabled;
    if (enabled) return;
    for (final token in _activeTokens.toList()) {
      token.cancel('Embeddings disabled');
    }
    _activeTokens.clear();
  }

  static CancelToken beginRequest(CancelToken? parent) {
    final token = CancelToken();
    if (!_enabled) {
      token.cancel('Embeddings disabled');
      return token;
    }
    _activeTokens.add(token);
    parent?.whenCancel.then((_) => token.cancel(parent.cancelError));
    return token;
  }

  static void endRequest(CancelToken token) {
    _activeTokens.remove(token);
  }
}
