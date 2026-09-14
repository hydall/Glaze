import '../models/api_config.dart';
import '../models/memory_book_api_settings.dart';

/// Output cap used only when neither the Memory Book slot nor the connection
/// it runs on names one.
///
/// It matches the floor the transports themselves fall back to, so an
/// unconfigured slot asks for no more than an unconfigured chat request would.
/// It is deliberately *not* a generous number: a draft that asks for more
/// output than the provider's own ceiling is rejected outright — several
/// providers cap `max_output_tokens` plus reasoning tokens well under 32K —
/// and the whole generation fails instead of producing a shorter summary.
const int kMemoryDraftFallbackMaxTokens = 4096;

/// Temperature used when the Memory Book slot does not pin one. Drafting is
/// extraction, not prose, so it stays low.
const double kMemoryDraftDefaultTemperature = 0.4;

/// Resolves the saved connection used by Memory Book draft generation without
/// changing the chat's globally active connection.
class MemoryBookApiConfigResolver {
  final List<ApiConfig> apiConfigs;
  final ApiConfig? activeConfig;

  const MemoryBookApiConfigResolver({
    required this.apiConfigs,
    this.activeConfig,
  });

  ApiConfig? resolve(MemoryBookApiSettings settings) {
    if (settings.apiConfigId.isNotEmpty) {
      final selected = apiConfigs
          .where((config) => config.id == settings.apiConfigId)
          .firstOrNull;
      if (selected != null) return selected;
    }
    return activeConfig;
  }

  /// Uses the same saved connection as draft generation itself. This avoids
  /// silently falling back to the transport's generic 120-second timeout.
  int? resolveTimeoutMs(MemoryBookApiSettings settings) =>
      resolve(settings)?.firstChunkTimeoutMs;

  /// The output cap a draft request carries.
  ///
  /// The slot's own value wins; left unset ("auto"), the request inherits the
  /// limit configured on the connection it runs on, exactly like every other
  /// auxiliary call in the app. It used to be a flat 25000 written into the
  /// generator, which no UI could lower — so a provider that caps output plus
  /// reasoning tokens below that rejected every draft with HTTP 400 and the
  /// user had no field to fix it in.
  int resolveMaxTokens(MemoryBookApiSettings settings) =>
      maxTokensFor(settings, resolve(settings));

  /// [resolveMaxTokens] for a caller that already knows the connection — or
  /// has none, as the custom endpoint branch does.
  static int maxTokensFor(MemoryBookApiSettings settings, ApiConfig? config) {
    final slot = settings.generationMaxTokens;
    if (slot != null && slot > 0) return slot;
    final fromConfig = config?.maxTokens ?? 0;
    if (fromConfig > 0) return fromConfig;
    return kMemoryDraftFallbackMaxTokens;
  }

  /// The temperature a draft request carries — the slot's own, or the drafting
  /// default. The connection's temperature is deliberately not inherited:
  /// roleplay presets run hot, and a hot summariser invents facts.
  static double temperatureFor(MemoryBookApiSettings settings) =>
      settings.generationTemperature ?? kMemoryDraftDefaultTemperature;
}
