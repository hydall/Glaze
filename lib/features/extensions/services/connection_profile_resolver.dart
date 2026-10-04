import '../../../../core/models/api_config.dart';
import '../models/connection_profiles.dart';
import '../models/extension_preset.dart';

/// Resolves the [ApiConfig] a JS `glaze.generateText({ preset })` call runs on.
///
/// A Glaze extension preset has one connection, so the requested [profile]
/// does not change the answer: every call goes to the preset's own connection.
/// The argument is still accepted because blocks imported from the original
/// extension carry `big` / `medium` / `small`, and rejecting it would break
/// scripts that pass it.
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
    if (mappedId.isNotEmpty) {
      final match = allConfigs.where((c) => c.id == mappedId).firstOrNull;
      if (match != null) return match;
    }
    return activeFallback;
  }
}
