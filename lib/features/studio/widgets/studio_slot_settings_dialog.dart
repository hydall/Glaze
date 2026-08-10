import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/models/api_config.dart';
import '../../../core/models/extra_request_parameter.dart';
import '../../../core/models/pipeline_settings.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/extra_request_parameters_editor.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../studio_injection_points.dart';
import 'studio_slot_override_controls.dart';

/// Which Studio model slot is being configured.
enum StudioSlot { finalGenerator, controller, cleaner, ledger }

/// Snapshot of per-slot generation settings captured in the dialog and applied
/// back to [PipelineSettings] via [applyTo].
///
/// Every parameter carries an `*Override` flag. When it is false the parameter
/// is not written into the request at all, so the API preset selected for the
/// slot supplies the value. Temperature, max tokens and the timeout have no
/// flag of their own in [PipelineSettings] — they encode "not overridden" as a
/// sentinel, so [applyTo] writes `-1` / `0` for them.
///
/// The ledger only exposes temperature / max tokens / timeout — it has no
/// sampling or reasoning overrides in [LedgerSettings] — so the ledger dialog
/// branch hides those groups and [applyTo] writes only those three fields.
class StudioSlotSettings {
  final double temperature;
  final bool temperatureOverride;
  final double topP;
  final bool topPOverride;
  final int topK;
  final bool topKOverride;
  final double frequencyPenalty;
  final bool frequencyPenaltyOverride;
  final double presencePenalty;
  final bool presencePenaltyOverride;
  final bool requestReasoning;
  final bool requestReasoningOverride;
  final bool showNativeReasoning;
  final bool showNativeReasoningOverride;
  final bool useResponsesApi;
  final bool useResponsesApiOverride;
  final String reasoningEffort;
  final bool reasoningEffortOverride;
  final bool omitTemperature;
  final bool omitTopP;
  final bool omitReasoning;
  final bool omitReasoningEffort;
  final int reasoningHistoryCount;
  final bool excludeReasoningFromContextBudget;
  final int maxTokens;
  final int timeoutMs;
  final List<ExtraRequestParameter> extraRequestParameters;

  const StudioSlotSettings({
    required this.temperature,
    required this.temperatureOverride,
    required this.topP,
    required this.topPOverride,
    required this.topK,
    required this.topKOverride,
    required this.frequencyPenalty,
    required this.frequencyPenaltyOverride,
    required this.presencePenalty,
    required this.presencePenaltyOverride,
    required this.requestReasoning,
    required this.requestReasoningOverride,
    required this.showNativeReasoning,
    required this.showNativeReasoningOverride,
    required this.useResponsesApi,
    required this.useResponsesApiOverride,
    required this.reasoningEffort,
    required this.reasoningEffortOverride,
    required this.omitTemperature,
    required this.omitTopP,
    required this.omitReasoning,
    required this.omitReasoningEffort,
    this.reasoningHistoryCount = 0,
    this.excludeReasoningFromContextBudget = false,
    required this.maxTokens,
    required this.timeoutMs,
    required this.extraRequestParameters,
  });

  /// Temperature as stored: the sentinel `-1` means "inherit", so the slider
  /// value is only persisted while the override is on.
  double get _storedTemperature => temperatureOverride ? temperature : -1.0;

  PipelineSettings applyTo(PipelineSettings pipeline, StudioSlot slot) {
    switch (slot) {
      case StudioSlot.finalGenerator:
        return pipeline.copyWith(
          studioAgent: pipeline.studioAgent.copyWith(
            studioFinalTemperature: _storedTemperature,
            studioFinalTopP: topP,
            studioFinalTopPOverride: topPOverride,
            studioFinalTopK: topK,
            studioFinalTopKOverride: topKOverride,
            studioFinalFrequencyPenalty: frequencyPenalty,
            studioFinalFrequencyPenaltyOverride: frequencyPenaltyOverride,
            studioFinalPresencePenalty: presencePenalty,
            studioFinalPresencePenaltyOverride: presencePenaltyOverride,
            studioFinalRequestReasoning: requestReasoning,
            studioFinalRequestReasoningOverride: requestReasoningOverride,
            studioFinalShowNativeReasoning: showNativeReasoning,
            studioFinalShowNativeReasoningOverride: showNativeReasoningOverride,
            studioFinalUseResponsesApi: useResponsesApi,
            studioFinalUseResponsesApiOverride: useResponsesApiOverride,
            studioFinalReasoningEffort: reasoningEffort,
            studioFinalReasoningEffortOverride: reasoningEffortOverride,
            studioFinalOmitTemperature: omitTemperature,
            studioFinalOmitTopP: omitTopP,
            studioFinalOmitReasoning: omitReasoning,
            studioFinalOmitReasoningEffort: omitReasoningEffort,
            studioFinalReasoningHistoryCount: reasoningHistoryCount,
            studioFinalExcludeReasoningFromContextBudget:
                excludeReasoningFromContextBudget,
            studioFinalMaxTokens: maxTokens,
            studioFinalTimeoutMs: timeoutMs,
            studioFinalExtraRequestParameters: extraRequestParameters,
          ),
        );
      case StudioSlot.controller:
        return pipeline.copyWith(
          studioAgent: pipeline.studioAgent.copyWith(
            studioControllerTemperature: _storedTemperature,
            studioControllerTopP: topP,
            studioControllerTopPOverride: topPOverride,
            studioControllerTopK: topK,
            studioControllerTopKOverride: topKOverride,
            studioControllerFrequencyPenalty: frequencyPenalty,
            studioControllerFrequencyPenaltyOverride: frequencyPenaltyOverride,
            studioControllerPresencePenalty: presencePenalty,
            studioControllerPresencePenaltyOverride: presencePenaltyOverride,
            studioControllerRequestReasoning: requestReasoning,
            studioControllerRequestReasoningOverride: requestReasoningOverride,
            studioControllerShowNativeReasoning: showNativeReasoning,
            studioControllerShowNativeReasoningOverride:
                showNativeReasoningOverride,
            studioControllerUseResponsesApi: useResponsesApi,
            studioControllerUseResponsesApiOverride: useResponsesApiOverride,
            studioControllerReasoningEffort: reasoningEffort,
            studioControllerReasoningEffortOverride: reasoningEffortOverride,
            studioControllerOmitTemperature: omitTemperature,
            studioControllerOmitTopP: omitTopP,
            studioControllerOmitReasoning: omitReasoning,
            studioControllerOmitReasoningEffort: omitReasoningEffort,
            studioControllerMaxTokens: maxTokens,
            studioControllerTimeoutMs: timeoutMs,
            studioControllerExtraRequestParameters: extraRequestParameters,
          ),
        );
      case StudioSlot.cleaner:
        return pipeline.copyWith(
          cleaner: pipeline.cleaner.copyWith(
            postCleanerTemperature: _storedTemperature,
            postCleanerTopP: topP,
            postCleanerTopPOverride: topPOverride,
            postCleanerTopK: topK,
            postCleanerTopKOverride: topKOverride,
            postCleanerFrequencyPenalty: frequencyPenalty,
            postCleanerFrequencyPenaltyOverride: frequencyPenaltyOverride,
            postCleanerPresencePenalty: presencePenalty,
            postCleanerPresencePenaltyOverride: presencePenaltyOverride,
            postCleanerRequestReasoning: requestReasoning,
            postCleanerRequestReasoningOverride: requestReasoningOverride,
            postCleanerShowNativeReasoning: showNativeReasoning,
            postCleanerShowNativeReasoningOverride: showNativeReasoningOverride,
            postCleanerUseResponsesApi: useResponsesApi,
            postCleanerUseResponsesApiOverride: useResponsesApiOverride,
            postCleanerReasoningEffort: reasoningEffort,
            postCleanerReasoningEffortOverride: reasoningEffortOverride,
            postCleanerOmitTemperature: omitTemperature,
            postCleanerOmitTopP: omitTopP,
            postCleanerOmitReasoning: omitReasoning,
            postCleanerOmitReasoningEffort: omitReasoningEffort,
            postCleanerMaxTokens: maxTokens,
            postCleanerTimeoutMs: timeoutMs,
            postCleanerExtraRequestParameters: extraRequestParameters,
          ),
        );
      case StudioSlot.ledger:
        return pipeline.copyWith(
          ledger: pipeline.ledger.copyWith(
            studioLedgerTemperature: _storedTemperature,
            studioLedgerMaxTokens: maxTokens,
            studioLedgerTimeoutMs: timeoutMs,
          ),
        );
    }
  }
}

/// Per-slot generation settings, laid out like the LLM connection sheet:
/// generation parameters, sampling, reasoning, extra request parameters.
///
/// Every parameter sits under an "Override selected preset value" switch. With
/// the switch off the row shows what [presetConfig] — the API connection bound
/// to this slot — contributes instead.
///
/// Presented via [showModalBottomSheet] with [SheetView]; pops a
/// [StudioSlotSettings] the caller applies through the pipeline notifier.
class StudioSlotSettingsDialog extends StatefulWidget {
  final StudioSlot slot;
  final PipelineSettings pipeline;

  /// The API preset this slot resolves to, used to show inherited values.
  /// Null when neither the slot nor the LLM tab has a connection selected.
  final ApiConfig? presetConfig;

  const StudioSlotSettingsDialog({
    super.key,
    required this.slot,
    required this.pipeline,
    this.presetConfig,
  });

  @override
  State<StudioSlotSettingsDialog> createState() =>
      _StudioSlotSettingsDialogState();
}

class _StudioSlotSettingsDialogState extends State<StudioSlotSettingsDialog> {
  late double _temperature;
  late bool _temperatureOverride;
  late double _topP;
  late bool _topPOverride;
  late int _topK;
  late bool _topKOverride;
  late double _frequencyPenalty;
  late bool _frequencyPenaltyOverride;
  late double _presencePenalty;
  late bool _presencePenaltyOverride;
  late bool _requestReasoning;
  late bool _requestReasoningOverride;
  late bool _showNativeReasoning;
  late bool _showNativeReasoningOverride;
  late bool _useResponsesApi;
  late bool _useResponsesApiOverride;
  late String _reasoningEffort;
  late bool _reasoningEffortOverride;
  late bool _omitTemperature;
  late bool _omitTopP;
  late bool _omitReasoning;
  late bool _omitReasoningEffort;
  late bool _excludeReasoningFromContextBudget;
  late bool _maxTokensOverride;
  late bool _timeoutOverride;
  late TextEditingController _reasoningHistoryCountCtrl;
  late TextEditingController _maxTokensCtrl;
  late TextEditingController _timeoutCtrl;
  late List<ExtraRequestParameter> _extraRequestParameters;

  bool get _isLedger => widget.slot == StudioSlot.ledger;
  bool get _isFinal => widget.slot == StudioSlot.finalGenerator;

  late final StudioSlotInheritedValues _inherited = StudioSlotInheritedValues(
    widget.presetConfig,
  );

  /// Temperature falls back to this while the override is off, so re-enabling
  /// the switch restores a usable slider position instead of the sentinel.
  static const double _temperatureFallback = 0.7;

  @override
  void initState() {
    super.initState();
    final p = widget.pipeline;
    switch (widget.slot) {
      case StudioSlot.finalGenerator:
        final a = p.studioAgent;
        _initTemperature(a.studioFinalTemperature);
        _topP = a.studioFinalTopP;
        _topPOverride = a.studioFinalTopPOverride;
        _topK = a.studioFinalTopK;
        _topKOverride = a.studioFinalTopKOverride;
        _frequencyPenalty = a.studioFinalFrequencyPenalty;
        _frequencyPenaltyOverride = a.studioFinalFrequencyPenaltyOverride;
        _presencePenalty = a.studioFinalPresencePenalty;
        _presencePenaltyOverride = a.studioFinalPresencePenaltyOverride;
        _requestReasoning = a.studioFinalRequestReasoning;
        _requestReasoningOverride = a.studioFinalRequestReasoningOverride;
        _showNativeReasoning = a.studioFinalShowNativeReasoning;
        _showNativeReasoningOverride = a.studioFinalShowNativeReasoningOverride;
        _useResponsesApi = a.studioFinalUseResponsesApi;
        _useResponsesApiOverride = a.studioFinalUseResponsesApiOverride;
        _reasoningEffort = a.studioFinalReasoningEffort;
        _reasoningEffortOverride = a.studioFinalReasoningEffortOverride;
        _omitTemperature = a.studioFinalOmitTemperature;
        _omitTopP = a.studioFinalOmitTopP;
        _omitReasoning = a.studioFinalOmitReasoning;
        _omitReasoningEffort = a.studioFinalOmitReasoningEffort;
        _excludeReasoningFromContextBudget =
            a.studioFinalExcludeReasoningFromContextBudget;
        _reasoningHistoryCountCtrl = TextEditingController(
          text: '${a.studioFinalReasoningHistoryCount}',
        );
        _initTokensAndTimeout(a.studioFinalMaxTokens, a.studioFinalTimeoutMs);
        _extraRequestParameters = a.studioFinalExtraRequestParameters;
      case StudioSlot.controller:
        final a = p.studioAgent;
        _initTemperature(a.studioControllerTemperature);
        _topP = a.studioControllerTopP;
        _topPOverride = a.studioControllerTopPOverride;
        _topK = a.studioControllerTopK;
        _topKOverride = a.studioControllerTopKOverride;
        _frequencyPenalty = a.studioControllerFrequencyPenalty;
        _frequencyPenaltyOverride = a.studioControllerFrequencyPenaltyOverride;
        _presencePenalty = a.studioControllerPresencePenalty;
        _presencePenaltyOverride = a.studioControllerPresencePenaltyOverride;
        _requestReasoning = a.studioControllerRequestReasoning;
        _requestReasoningOverride = a.studioControllerRequestReasoningOverride;
        _showNativeReasoning = a.studioControllerShowNativeReasoning;
        _showNativeReasoningOverride =
            a.studioControllerShowNativeReasoningOverride;
        _useResponsesApi = a.studioControllerUseResponsesApi;
        _useResponsesApiOverride = a.studioControllerUseResponsesApiOverride;
        _reasoningEffort = a.studioControllerReasoningEffort;
        _reasoningEffortOverride = a.studioControllerReasoningEffortOverride;
        _omitTemperature = a.studioControllerOmitTemperature;
        _omitTopP = a.studioControllerOmitTopP;
        _omitReasoning = a.studioControllerOmitReasoning;
        _omitReasoningEffort = a.studioControllerOmitReasoningEffort;
        _excludeReasoningFromContextBudget = false;
        _reasoningHistoryCountCtrl = TextEditingController(text: '0');
        _initTokensAndTimeout(
          a.studioControllerMaxTokens,
          a.studioControllerTimeoutMs,
        );
        _extraRequestParameters = a.studioControllerExtraRequestParameters;
      case StudioSlot.cleaner:
        final c = p.cleaner;
        _initTemperature(c.postCleanerTemperature);
        _topP = c.postCleanerTopP;
        _topPOverride = c.postCleanerTopPOverride;
        _topK = c.postCleanerTopK;
        _topKOverride = c.postCleanerTopKOverride;
        _frequencyPenalty = c.postCleanerFrequencyPenalty;
        _frequencyPenaltyOverride = c.postCleanerFrequencyPenaltyOverride;
        _presencePenalty = c.postCleanerPresencePenalty;
        _presencePenaltyOverride = c.postCleanerPresencePenaltyOverride;
        _requestReasoning = c.postCleanerRequestReasoning;
        _requestReasoningOverride = c.postCleanerRequestReasoningOverride;
        _showNativeReasoning = c.postCleanerShowNativeReasoning;
        _showNativeReasoningOverride =
            c.postCleanerShowNativeReasoningOverride;
        _useResponsesApi = c.postCleanerUseResponsesApi;
        _useResponsesApiOverride = c.postCleanerUseResponsesApiOverride;
        _reasoningEffort = c.postCleanerReasoningEffort;
        _reasoningEffortOverride = c.postCleanerReasoningEffortOverride;
        _omitTemperature = c.postCleanerOmitTemperature;
        _omitTopP = c.postCleanerOmitTopP;
        _omitReasoning = c.postCleanerOmitReasoning;
        _omitReasoningEffort = c.postCleanerOmitReasoningEffort;
        _excludeReasoningFromContextBudget = false;
        _reasoningHistoryCountCtrl = TextEditingController(text: '0');
        _initTokensAndTimeout(
          c.postCleanerMaxTokens,
          c.postCleanerTimeoutMs,
        );
        _extraRequestParameters = c.postCleanerExtraRequestParameters;
      case StudioSlot.ledger:
        final l = p.ledger;
        _initTemperature(l.studioLedgerTemperature);
        _topP = 0.9;
        _topPOverride = false;
        _topK = 0;
        _topKOverride = false;
        _frequencyPenalty = 0;
        _frequencyPenaltyOverride = false;
        _presencePenalty = 0;
        _presencePenaltyOverride = false;
        _requestReasoning = false;
        _requestReasoningOverride = false;
        _showNativeReasoning = false;
        _showNativeReasoningOverride = false;
        _useResponsesApi = false;
        _useResponsesApiOverride = false;
        _reasoningEffort = 'auto';
        _reasoningEffortOverride = false;
        _omitTemperature = false;
        _omitTopP = false;
        _omitReasoning = true;
        _omitReasoningEffort = true;
        _excludeReasoningFromContextBudget = false;
        _reasoningHistoryCountCtrl = TextEditingController(text: '0');
        _initTokensAndTimeout(
          l.studioLedgerMaxTokens,
          l.studioLedgerTimeoutMs,
        );
        _extraRequestParameters = const [];
    }
  }

  /// A negative stored temperature is the "inherit" sentinel.
  void _initTemperature(double stored) {
    _temperatureOverride = stored >= 0;
    _temperature = stored >= 0 ? stored.clamp(0.0, 2.0) : _temperatureFallback;
  }

  /// `0` is the "inherit" sentinel for both, so an empty field reads as off.
  void _initTokensAndTimeout(int maxTokens, int timeoutMs) {
    _maxTokensOverride = maxTokens > 0;
    _maxTokensCtrl = TextEditingController(
      text: maxTokens > 0 ? '$maxTokens' : '',
    );
    _timeoutOverride = timeoutMs > 0;
    _timeoutCtrl = TextEditingController(
      text: timeoutMs > 0 ? '${timeoutMs ~/ 1000}' : '',
    );
  }

  @override
  void dispose() {
    _maxTokensCtrl.dispose();
    _timeoutCtrl.dispose();
    _reasoningHistoryCountCtrl.dispose();
    super.dispose();
  }

  String get _slotTitle {
    final String point = switch (widget.slot) {
      StudioSlot.finalGenerator => 'final',
      StudioSlot.controller => 'pregen',
      StudioSlot.cleaner => 'cleaner',
      StudioSlot.ledger => 'ledger',
    };
    return '${studioInjectionPointLabel(point)} ${'studio_slot_settings_title'.tr()}';
  }

  String _reasoningEffortLabel(String effort) => switch (effort) {
    'auto' => 'reasoning_effort_auto'.tr(),
    'min' => 'reasoning_effort_min'.tr(),
    'low' => 'reasoning_effort_low'.tr(),
    'medium' => 'reasoning_effort_medium'.tr(),
    'high' => 'reasoning_effort_high'.tr(),
    'max' => 'reasoning_effort_max'.tr(),
    _ => effort,
  };

  Future<void> _openReasoningEffortSelector() async {
    const options = ['auto', 'min', 'low', 'medium', 'high', 'max'];
    await GlazeBottomSheet.show<void>(
      context,
      title: 'label_reasoning_effort'.tr(),
      items: options.map((option) {
        final active = option == _reasoningEffort;
        return BottomSheetItem(
          label: _reasoningEffortLabel(option),
          icon: active ? Icons.check : null,
          iconColor: context.cs.primary,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            setState(() => _reasoningEffort = option);
          },
        );
      }).toList(),
    );
  }

  void _save() {
    final maxTokens = _maxTokensOverride
        ? (int.tryParse(_maxTokensCtrl.text.trim()) ?? 0)
        : 0;
    final reasoningHistoryCount =
        int.tryParse(_reasoningHistoryCountCtrl.text.trim()) ?? 0;
    final seconds = _timeoutOverride
        ? (int.tryParse(_timeoutCtrl.text.trim()) ?? 0)
        : 0;
    Navigator.of(context, rootNavigator: true).pop(
      StudioSlotSettings(
        temperature: _temperature,
        temperatureOverride: _temperatureOverride,
        topP: _topP,
        topPOverride: _topPOverride,
        topK: _topK,
        topKOverride: _topKOverride,
        frequencyPenalty: _frequencyPenalty,
        frequencyPenaltyOverride: _frequencyPenaltyOverride,
        presencePenalty: _presencePenalty,
        presencePenaltyOverride: _presencePenaltyOverride,
        requestReasoning: _requestReasoning,
        requestReasoningOverride: _requestReasoningOverride,
        showNativeReasoning: _showNativeReasoning,
        showNativeReasoningOverride: _showNativeReasoningOverride,
        useResponsesApi: _useResponsesApi,
        useResponsesApiOverride: _useResponsesApiOverride,
        reasoningEffort: _reasoningEffort,
        reasoningEffortOverride: _reasoningEffortOverride,
        omitTemperature: _omitTemperature,
        omitTopP: _omitTopP,
        omitReasoning: _omitReasoning,
        omitReasoningEffort: _omitReasoningEffort,
        reasoningHistoryCount: reasoningHistoryCount < -1
            ? 0
            : reasoningHistoryCount,
        excludeReasoningFromContextBudget: _excludeReasoningFromContextBudget,
        maxTokens: maxTokens,
        timeoutMs: seconds > 0 ? seconds * 1000 : 0,
        extraRequestParameters: _extraRequestParameters,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SheetView(
      title: _slotTitle,
      showHandle: true,
      bodyPadding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      actions: [
        SheetViewAction(
          icon: const Icon(Icons.check, size: 22),
          tooltip: 'studio_slot_settings_save'.tr(),
          onPressed: _save,
        ),
      ],
      body: ListView(
        children: [
          const SizedBox(height: 8),
          _buildGenerationGroup(),
          if (!_isLedger) ...[
            _buildSamplingGroup(),
            ExtraRequestParametersEditor(
              parameters: _extraRequestParameters,
              title: 'extra_request_parameters'.tr(),
              description: 'extra_request_parameters_studio_desc'.tr(),
              keyLabel: 'extra_request_parameter_key'.tr(),
              valueLabel: 'extra_request_parameter_value'.tr(),
              addLabel: 'extra_request_parameter_add'.tr(),
              onChanged: (parameters) {
                _extraRequestParameters = parameters;
              },
            ),
            const SizedBox(height: 8),
            _buildReasoningGroup(),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _save,
            child: Text('studio_slot_settings_save'.tr()),
          ),
        ],
      ),
    );
  }

  Widget _buildGenerationGroup() {
    return MenuGroup(
      compact: true,
      header: 'studio_slot_settings_generation'.tr(),
      description: 'studio_slot_override_hint'.tr(),
      items: [
        ...studioSlotOverrideBlock(
          label: 'studio_slot_settings_temperature'.tr(),
          overridden: _temperatureOverride,
          onOverrideChanged: (v) => setState(() => _temperatureOverride = v),
          inheritedValue: _inherited.agentDefault,
          editor: MenuRangeItem(
            label: 'studio_slot_settings_temperature'.tr(),
            value: _temperature,
            min: 0,
            max: 2,
            divisions: 200,
            editableValue: true,
            included: !_omitTemperature,
            onIncludedChanged: (v) => setState(() => _omitTemperature = !v),
            onChanged: (v) => setState(() => _temperature = v),
          ),
        ),
        ...studioSlotOverrideBlock(
          label: 'studio_slot_settings_max_tokens'.tr(),
          overridden: _maxTokensOverride,
          onOverrideChanged: (v) => setState(() => _maxTokensOverride = v),
          inheritedValue: _inherited.agentDefault,
          editor: MenuFieldItem(
            label: 'studio_slot_settings_max_tokens'.tr(),
            controller: _maxTokensCtrl,
            placeholder: '0',
            keyboardType: TextInputType.number,
          ),
        ),
        ...studioSlotOverrideBlock(
          label: 'studio_slot_settings_timeout'.tr(),
          overridden: _timeoutOverride,
          onOverrideChanged: (v) => setState(() => _timeoutOverride = v),
          inheritedValue: _inherited.agentDefault,
          editor: MenuFieldItem(
            label: 'studio_slot_settings_timeout'.tr(),
            controller: _timeoutCtrl,
            placeholder: '0',
            keyboardType: TextInputType.number,
          ),
        ),
      ],
    );
  }

  Widget _buildSamplingGroup() {
    return MenuGroup(
      compact: true,
      header: 'section_sampling'.tr(),
      items: [
        ...studioSlotOverrideBlock(
          label: 'studio_slot_settings_top_p'.tr(),
          overridden: _topPOverride,
          onOverrideChanged: (v) => setState(() => _topPOverride = v),
          inheritedValue: _inherited.topP,
          editor: MenuRangeItem(
            label: 'studio_slot_settings_top_p'.tr(),
            value: _topP,
            min: 0,
            max: 1,
            divisions: 100,
            editableValue: true,
            included: !_omitTopP,
            onIncludedChanged: (v) => setState(() => _omitTopP = !v),
            onChanged: (v) => setState(() => _topP = v),
          ),
        ),
        ...studioSlotOverrideBlock(
          label: 'studio_slot_settings_top_k'.tr(),
          overridden: _topKOverride,
          onOverrideChanged: (v) => setState(() => _topKOverride = v),
          inheritedValue: _inherited.topK,
          editor: MenuRangeItem(
            label: 'studio_slot_settings_top_k'.tr(),
            value: _topK.toDouble(),
            min: 0,
            max: 200,
            divisions: 200,
            editableValue: true,
            decimalPlaces: 0,
            onChanged: (v) => setState(() => _topK = v.round()),
          ),
        ),
        ...studioSlotOverrideBlock(
          label: 'studio_slot_settings_frequency_penalty'.tr(),
          overridden: _frequencyPenaltyOverride,
          onOverrideChanged: (v) =>
              setState(() => _frequencyPenaltyOverride = v),
          inheritedValue: _inherited.frequencyPenalty,
          editor: MenuRangeItem(
            label: 'studio_slot_settings_frequency_penalty'.tr(),
            value: _frequencyPenalty,
            min: -2,
            max: 2,
            divisions: 80,
            editableValue: true,
            onChanged: (v) => setState(() => _frequencyPenalty = v),
          ),
        ),
        ...studioSlotOverrideBlock(
          label: 'studio_slot_settings_presence_penalty'.tr(),
          overridden: _presencePenaltyOverride,
          onOverrideChanged: (v) =>
              setState(() => _presencePenaltyOverride = v),
          inheritedValue: _inherited.presencePenalty,
          editor: MenuRangeItem(
            label: 'studio_slot_settings_presence_penalty'.tr(),
            value: _presencePenalty,
            min: -2,
            max: 2,
            divisions: 80,
            editableValue: true,
            onChanged: (v) => setState(() => _presencePenalty = v),
          ),
        ),
      ],
    );
  }

  Widget _buildReasoningGroup() {
    return MenuGroup(
      compact: true,
      header: 'studio_slot_settings_reasoning'.tr(),
      items: [
        ...studioSlotOverrideBlock(
          label: 'label_use_responses_api'.tr(),
          overridden: _useResponsesApiOverride,
          onOverrideChanged: (v) => setState(() => _useResponsesApiOverride = v),
          inheritedValue: _inherited.useResponsesApi,
          editor: MenuSwitchItem(
            label: 'label_use_responses_api'.tr(),
            description: 'desc_use_responses_api'.tr(),
            value: _useResponsesApi,
            onChanged: (v) => setState(() => _useResponsesApi = v),
          ),
        ),
        ...studioSlotOverrideBlock(
          label: 'studio_slot_settings_request_reasoning'.tr(),
          overridden: _requestReasoningOverride,
          onOverrideChanged: (v) =>
              setState(() => _requestReasoningOverride = v),
          inheritedValue: _inherited.requestReasoning,
          editor: MenuSwitchItem(
            label: 'studio_slot_settings_request_reasoning'.tr(),
            description: 'studio_slot_settings_request_reasoning_desc'.tr(),
            value: _requestReasoning && !_omitReasoning,
            onChanged: (v) => setState(() {
              _requestReasoning = v;
              _omitReasoning = false;
            }),
          ),
        ),
        ...studioSlotOverrideBlock(
          label: 'label_reasoning'.tr(),
          overridden: _showNativeReasoningOverride,
          onOverrideChanged: (v) =>
              setState(() => _showNativeReasoningOverride = v),
          inheritedValue: _inherited.showNativeReasoning,
          editor: MenuSwitchItem(
            label: 'label_reasoning'.tr(),
            description: 'desc_reasoning'.tr(),
            value: _showNativeReasoning,
            onChanged: (v) => setState(() => _showNativeReasoning = v),
          ),
        ),
        ...studioSlotOverrideBlock(
          label: 'label_reasoning_effort'.tr(),
          overridden: _reasoningEffortOverride,
          onOverrideChanged: (v) => setState(() => _reasoningEffortOverride = v),
          inheritedValue: _inherited.reasoningEffort,
          editor: MenuSelectorItem(
            label: 'label_reasoning_effort'.tr(),
            currentValue: _reasoningEffortLabel(_reasoningEffort),
            included: !_omitReasoningEffort,
            onIncludedChanged: (v) =>
                setState(() => _omitReasoningEffort = !v),
            onTap: _openReasoningEffortSelector,
          ),
        ),
        // Studio-only knobs: they shape the prompt this slot builds rather than
        // a request field the API preset could supply, so they carry no
        // override switch.
        if (_isFinal) ...[
          MenuFieldItem(
            label: 'studio_slot_settings_reasoning_history_count'.tr(),
            controller: _reasoningHistoryCountCtrl,
            placeholder: '0',
            keyboardType: const TextInputType.numberWithOptions(signed: true),
          ),
          MenuSwitchItem(
            label: 'label_exclude_reasoning_from_budget'.tr(),
            description: 'desc_exclude_reasoning_from_budget'.tr(),
            value: _excludeReasoningFromContextBudget,
            onChanged: (v) =>
                setState(() => _excludeReasoningFromContextBudget = v),
          ),
        ],
      ],
    );
  }
}
