import 'package:freezed_annotation/freezed_annotation.dart';

part 'extension_context_policy.freezed.dart';
part 'extension_context_policy.g.dart';

/// Context available to one LLM-backed extension block.
///
/// The defaults preserve the pre-policy behavior for existing blocks:
/// character/persona plus the block's existing per-block history count.
@freezed
abstract class ExtensionContextPolicy with _$ExtensionContextPolicy {
  const factory ExtensionContextPolicy({
    /// Persisted compatibility marker for blocks created before context
    /// policies existed. These blocks keep the original two-message
    /// InfoBlock request shape until the user changes the policy.
    @Default(false) bool legacyPromptSemantics,
    @Default(false) bool useMainModelContext,
    @Default(true) bool includeCharacterCard,
    @Default(true) bool includePersona,
    @Default(false) bool includeMainPresetInstructions,
    @Default(false) bool includeLorebooks,
    @Default(false) bool includeMemoryBooks,
    @Default(false) bool includeStudioState,
    @Default(false) bool includeSummary,
    @Default(false) bool includeAuthorsNote,
    @Default(false) bool includeRuntimePrompts,
  }) = _ExtensionContextPolicy;

  factory ExtensionContextPolicy.fromJson(Map<String, dynamic> json) =>
      _$ExtensionContextPolicyFromJson(json);
}
