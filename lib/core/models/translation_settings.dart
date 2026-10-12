import 'package:freezed_annotation/freezed_annotation.dart';

part 'translation_settings.freezed.dart';
part 'translation_settings.g.dart';

/// On-screen translation: which connection translates and into what.
///
/// Translation is display-only. A translated message is swapped into the chat
/// WebView and nowhere else — the stored message, the edit buffer and every
/// prompt keep the original text — and a translated composer draft is just
/// text the user may still edit before sending.
///
/// Nested inside `PipelineSettings` under the `translation` field. The
/// connection is a saved API config, so its key stays wherever API keys are
/// kept rather than being copied in here.
@freezed
abstract class TranslationSettings with _$TranslationSettings {
  const factory TranslationSettings({
    /// Gates every translation affordance: the per-message button, the
    /// composer action and the connection rows on the Agents tab.
    @Default(false) bool enabled,

    /// Saved API connection. Empty means the active chat connection.
    @Default('') String apiConfigId,

    /// Overrides the connection's model when non-empty.
    @Default('') String model,

    /// Language code messages are translated into. Empty follows the app's
    /// interface language.
    @Default('') String messageLanguage,

    /// Language code the composer draft is translated into — the language the
    /// roleplay is written in.
    @Default('en') String inputLanguage,
  }) = _TranslationSettings;

  factory TranslationSettings.fromJson(Map<String, dynamic> json) =>
      _$TranslationSettingsFromJson(json);
}
