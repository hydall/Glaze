import '../../../../core/models/api_config.dart';
import '../models/connection_profiles.dart';
import '../models/extension_preset.dart';
import '../models/profile_params.dart';

/// Resolves the [ApiConfig] a JS `glaze.generateText({ preset })` call runs on.
///
/// A Glaze extension preset has one connection, so every call goes to the
/// preset's own connection; the requested [profile] picks the generation
/// parameters it runs with (see [ProfileParams]), as the original's API
/// presets do.
///
/// The connection is opt-in: when the preset names none — or names one that no
/// longer exists — the resolver falls back to [activeFallback]. That is the
/// behaviour the bridge had before presets could pick a connection at all, so
/// existing setups keep working untouched.
///
/// [activeFallback] is normally the user's currently-selected active API config
/// (`activeApiConfigProvider`). When it is `null` too the resolver returns
/// `null` and the bridge surfaces a `StateError` ("No active API config
/// available") — matching the pre-existing bridge contract.
class ConnectionProfileResolver {
  const ConnectionProfileResolver();

  ApiConfig? resolve(
    ExtensionPreset? preset,
    ConnectionProfile profile,
    ApiConfig? activeFallback,
    Iterable<ApiConfig> allConfigs,
  ) {
    final mappedId = preset?.apiConfigId ?? '';
    var config = activeFallback;
    if (mappedId.isNotEmpty) {
      config = allConfigs.where((c) => c.id == mappedId).firstOrNull ?? config;
    }
    if (config == null || preset == null) return config;
    return profileParamsFor(preset.profileParams, profile).applyTo(config);
  }
}
