import '../../../../core/models/api_config.dart';
import '../models/connection_profiles.dart';
import '../models/extension_preset.dart';

/// Resolves the [ApiConfig] for a JS `glaze.generateText({ preset })` call
/// based on the active extension preset's [ConnectionProfiles] mapping.
///
/// The mapping is opt-in: when a profile slot is empty (or the user has
/// not configured connection profiles for the preset), the resolver
/// falls back to [activeFallback]. This is the same behaviour the
/// bridge had before the mapping existed, so existing single-config
/// setups continue to work without any user changes.
///
/// [activeFallback] is normally the user's currently-selected active
/// API config (`activeApiConfigProvider`). When the active config is
/// `null` the resolver returns `null` and the bridge surfaces a
/// `StateError` ("No active API config available") — matching the
/// pre-existing bridge contract.
class ConnectionProfileResolver {
  const ConnectionProfileResolver();

  /// Returns the [ApiConfig] for [profile], or `null` if no API
  /// config is registered for the requested profile and the fallback
  /// is also `null`. The caller decides whether `null` should surface
  /// as a bridge error.
  ApiConfig? resolve(
    ExtensionPreset? preset,
    ConnectionProfile profile,
    ApiConfig? activeFallback,
    Iterable<ApiConfig> allConfigs,
  ) {
    final mappedId = switch (profile) {
      ConnectionProfile.big => preset?.connectionProfiles.big ?? '',
      ConnectionProfile.medium => preset?.connectionProfiles.medium ?? '',
      ConnectionProfile.small => preset?.connectionProfiles.small ?? '',
    };
    if (mappedId.isNotEmpty) {
      final match = allConfigs.where((c) => c.id == mappedId).firstOrNull;
      if (match != null) return match;
    }
    return activeFallback;
  }
}
