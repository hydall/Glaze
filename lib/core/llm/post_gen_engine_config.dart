import '../models/api_config.dart';
import '../models/ledger_prompt_injection_mode.dart';
import '../models/ledger_prompt_injection_policy.dart';
import '../models/pipeline_settings.dart';
import '../models/preset.dart';
import 'aux_api_config_resolver.dart';
import 'aux_llm_client.dart';

/// What the engines that run after a reply — Post Clean and the Tracker
/// (Ledger) — need for one turn: their prompt blocks, their connections and
/// the settings they run on.
///
/// Captured once per turn and immutable, so a setting edited mid-turn never
/// splits one turn across two configurations. The agents system builds it from
/// the chat's built-in Post Clean and Tracker agents; nothing else does.
class PostGenEngineConfig {
  final PipelineSettings pipelineSettings;
  final List<ApiConfig> apiConfigs;
  final ApiConfig? activeApiConfig;

  /// Post Clean runs this turn.
  final bool cleanerEnabled;

  /// The Tracker runs this turn.
  final bool ledgerEnabled;

  /// Post Clean prompt blocks, in order.
  final List<PresetBlock> cleanerBlocks;

  /// Tracker prompt blocks: `ledger_system` and
  /// `ledger_reconciliation_prompt`.
  final List<PresetBlock> ledgerBlocks;

  /// Names of the blocks Post Clean forwards to the cleaner verbatim.
  final List<String> broadcastBlocks;

  /// Connection of Post Clean; empty uses the chat's connection.
  final String cleanerApiConfigId;

  /// Connection of the Tracker; empty falls back to Post Clean's.
  final String ledgerApiConfigId;

  final LedgerPromptInjectionPolicy ledgerPromptInjectionPolicy;

  const PostGenEngineConfig({
    required this.pipelineSettings,
    required this.apiConfigs,
    required this.activeApiConfig,
    this.cleanerEnabled = false,
    this.ledgerEnabled = false,
    this.cleanerBlocks = const [],
    this.ledgerBlocks = const [],
    this.broadcastBlocks = const [],
    this.cleanerApiConfigId = '',
    this.ledgerApiConfigId = '',
    this.ledgerPromptInjectionPolicy = const LedgerPromptInjectionPolicy(
      presetOptIn: true,
      mode: LedgerPromptInjectionMode.legacy,
    ),
  });

  /// Any engine runs this turn.
  bool get enabled => cleanerEnabled || ledgerEnabled;

  AuxApiConfig resolveCleanerConfig({
    required String errorLabel,
    bool? useResponsesApi,
  }) {
    return AuxApiConfigResolver.resolve(
      apiConfigs: apiConfigs,
      apiConfigId: cleanerApiConfigId,
      fallback: activeApiConfig,
      errorLabel: errorLabel,
      modelOverride: pipelineSettings.cleaner.postCleanerModel,
      extraRequestParameterOverrides:
          pipelineSettings.cleaner.postCleanerExtraRequestParameters,
      useResponsesApi: useResponsesApi,
    );
  }

  /// The Tracker's own connection, falling back to Post Clean's when neither
  /// the connection nor the model override is set.
  AuxApiConfig resolveLedgerConfig({
    required String errorLabel,
    bool? useResponsesApi,
  }) {
    final model = pipelineSettings.ledger.studioLedgerModel;
    if (ledgerApiConfigId.isEmpty && model.isEmpty) {
      return resolveCleanerConfig(
        errorLabel: errorLabel,
        useResponsesApi: useResponsesApi,
      );
    }
    return AuxApiConfigResolver.resolve(
      apiConfigs: apiConfigs,
      apiConfigId: ledgerApiConfigId.isNotEmpty
          ? ledgerApiConfigId
          : cleanerApiConfigId,
      fallback: activeApiConfig,
      errorLabel: errorLabel,
      // A configured Tracker route is independent from cleaner tuning. The
      // cleaner model/extra parameters are inherited only by the complete
      // fallback above (neither a Tracker connection nor model is set).
      modelOverride: model,
      extraRequestParameterOverrides: const [],
      useResponsesApi: useResponsesApi,
    );
  }
}
