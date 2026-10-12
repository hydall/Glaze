import 'package:freezed_annotation/freezed_annotation.dart';

part 'translation_settings.freezed.dart';
part 'translation_settings.g.dart';

/// On-screen translation: which engine translates, into what, and how much of
/// the turn happens automatically.
///
/// The per-message and composer buttons only ever paint text — the stored
/// message, the edit buffer and the prompt history keep the original. The two
/// automatic toggles are the exception, and each moves the boundary in the one
/// direction that makes sense: sent user messages are rewritten *before* they
/// are stored, so the model and the context get the translation too, while
/// received character messages are translated for display and keep the original
/// in the context the model continues from.
///
/// Nested inside `PipelineSettings` under the `translation` field. An LLM
/// translation runs on a saved API config, so its key stays wherever API keys
/// are kept rather than being copied in here. A machine-translation provider
/// has no connection to borrow, so its key and endpoint are stored here, the
/// same way `MemoryBookApiSettings` keeps a custom generation key.
@freezed
abstract class TranslationSettings with _$TranslationSettings {
  const factory TranslationSettings({
    /// Gates every translation affordance: the per-message button, the
    /// composer action and the rows on the Agents tab.
    @Default(false) bool enabled,

    /// Which engine translates. See `TranslationProvider`.
    @Default('llm') String provider,

    /// Saved API connection used when [provider] is `llm`. Empty means the
    /// active chat connection.
    @Default('') String apiConfigId,

    /// Overrides the connection's model when non-empty (LLM provider only).
    @Default('') String model,

    /// The translation instruction for the LLM provider. Empty uses the
    /// built-in default. See `TranslationPromptPresets`.
    @Default('') String prompt,

    /// Machine-translation API key ([provider] other than `llm`).
    @Default('') String translatorApiKey,

    /// Endpoint override for a machine-translation provider. Empty uses the
    /// provider's default; LibreTranslate has no default and needs one.
    @Default('') String translatorEndpoint,

    /// Yandex folder id.
    @Default('') String translatorFolderId,

    /// Language code messages are translated into. Empty follows the app's
    /// interface language.
    @Default('') String messageLanguage,

    /// Language code the roleplay is written in — the target of the composer
    /// action and of the automatic rewrite of an outgoing message.
    @Default('en') String inputLanguage,

    /// Rewrites an outgoing user message into [inputLanguage] before it is
    /// sent, so the model and the stored history get the translation.
    @Default(false) bool autoTranslateUser,

    /// Translates a received character message into [messageLanguage] for
    /// display. Display-only — the stored message stays in the original.
    @Default(false) bool autoTranslateCharacter,
  }) = _TranslationSettings;

  factory TranslationSettings.fromJson(Map<String, dynamic> json) =>
      _$TranslationSettingsFromJson(json);
}
