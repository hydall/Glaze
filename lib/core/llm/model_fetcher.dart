import '../models/api_config.dart';
import 'transport/transport_factory.dart';

/// Shared utility for fetching and parsing model IDs from an LLM API endpoint.
///
/// Used by the Studio slots tab, Memory Generation settings and the card
/// rewriter to populate model pickers. The request goes through the same
/// transport the connection itself uses — [pickChatTransportFor] — so a
/// Gemini/Anthropic/OpenRouter connection is listed over its own protocol and
/// auth scheme, exactly like the LLM tab's "fetch models" button.
///
/// The raw `fetchModels` response is a list of maps; this helper extracts,
/// deduplicates and sorts the `id` field, and prepends the config's own model
/// if it is missing from the response.
class ModelFetcher {
  ModelFetcher._();

  /// Fetches model IDs for [config] over that config's protocol.
  ///
  /// Transports return an empty list rather than throwing when the endpoint
  /// rejects the request, so an empty result means "nothing to offer", not
  /// necessarily an error.
  static Future<List<String>> fetchModelIds(ApiConfig config) async {
    final models = await pickChatTransportFor(config).fetchModels(
      endpoint: config.endpoint,
      apiKey: config.apiKey,
    );
    final ids = models
        .map((m) => m['id'])
        .whereType<String>()
        .where((id) => id.trim().isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    if (config.model.isNotEmpty && !ids.contains(config.model)) {
      ids.insert(0, config.model);
    }
    return ids;
  }
}
