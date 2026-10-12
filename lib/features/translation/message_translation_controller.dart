import 'package:dio/dio.dart';

/// What the controller needs from the chat WebView. Split out so the request
/// lifecycle can be tested without one.
class MessageTranslationView {
  /// Shows the translating bubble; false when the message no longer shows the
  /// text the tap carried, in which case nothing is sent.
  final Future<bool> Function(String id, String original, String label)
  showPending;
  final Future<void> Function(String id, String original, String text)
  showTranslation;
  final Future<void> Function(String id) showOriginal;

  const MessageTranslationView({
    required this.showPending,
    required this.showTranslation,
    required this.showOriginal,
  });
}

typedef MessageTranslator =
    Future<String> Function(String text, CancelToken cancelToken);

/// Runs the per-message translate button for one chat screen.
///
/// Holds nothing but the requests in flight. The translation itself lives
/// only in the WebView, painted over the bubble: the message, its edit buffer
/// and every prompt keep the original, so nothing here can reach the model.
class MessageTranslationController {
  final MessageTranslationView view;
  final void Function(Object error) onError;

  final Map<String, CancelToken> _jobs = {};

  /// Bumped by [cancelAll], so a request that settles after a chat switch
  /// cannot paint into, or report an error on, the chat that replaced it.
  int _epoch = 0;

  MessageTranslationController({required this.view, required this.onError});

  bool isTranslating(String id) => _jobs.containsKey(id);

  /// Handles one tap. [action] is what the WebView read off the bubble:
  /// `translate`, `original` (it shows a translation) or `cancel` (a request
  /// is running).
  Future<void> handle({
    required String id,
    required String action,
    required String text,
    required String pendingLabel,
    required MessageTranslator translate,
  }) async {
    if (action != 'translate') {
      _jobs.remove(id)?.cancel('Translation dismissed');
      await view.showOriginal(id);
      return;
    }
    if (_jobs.containsKey(id) || text.trim().isEmpty) return;
    final epoch = _epoch;
    final token = CancelToken();
    _jobs[id] = token;
    try {
      if (!await view.showPending(id, text, pendingLabel)) return;
      if (token.isCancelled || epoch != _epoch) return;
      final translated = await translate(text, token);
      if (token.isCancelled || epoch != _epoch) return;
      await view.showTranslation(id, text, translated);
    } catch (error) {
      if (token.isCancelled || epoch != _epoch) return;
      await view.showOriginal(id);
      onError(error);
    } finally {
      if (identical(_jobs[id], token)) _jobs.remove(id);
    }
  }

  /// Drops every request in flight — the chat changed or the screen closed.
  void cancelAll() {
    for (final token in _jobs.values) {
      token.cancel('Translation cancelled');
    }
    _jobs.clear();
    _epoch++;
  }
}
