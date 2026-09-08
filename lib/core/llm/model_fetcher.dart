import 'sse_client.dart';

/// Shared utility for fetching and parsing model IDs from an LLM API endpoint.
///
/// Used by Studio Settings and Memory Generation Settings sheets to populate
/// model dropdowns. The raw `fetchModels` response is a list of maps; this
/// helper extracts, deduplicates, sorts the `id` field, and prepends the
/// config's default model if it's missing from the response.
class ModelFetcher {
  ModelFetcher._();

  /// Fetches model IDs from [endpoint] using [apiKey].
  ///
  /// If [fallbackModel] is provided and non-empty, it is prepended to the
  /// list when the API response doesn't include it.
  static Future<List<String>> fetchModelIds({
    required String endpoint,
    required String apiKey,
    String fallbackModel = '',
  }) async {
    final models = await SseClient().fetchModels(
      endpoint: endpoint,
      apiKey: apiKey,
    );
    final ids = models
        .map((m) => m['id'])
        .whereType<String>()
        .where((id) => id.trim().isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    if (fallbackModel.isNotEmpty && !ids.contains(fallbackModel)) {
      ids.insert(0, fallbackModel);
    }
    return ids;
  }
}
