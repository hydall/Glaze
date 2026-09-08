import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';

import '../../../core/models/pipeline_settings.dart';
import '../../../core/models/extra_request_parameter.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../../shared/widgets/extra_request_parameters_editor.dart';

/// Which Studio model slot is being configured.
enum StudioSlot { finalGenerator, tracker, cleaner }

/// Snapshot of per-slot settings captured in the dialog.
class StudioSlotSettings {
  final double temperature;
  final double topP;
  final int topK;
  final double frequencyPenalty;
  final double presencePenalty;
  final bool requestReasoning;
  final bool useResponsesApi;
  final String reasoningEffort;
  final bool omitTemperature;
  final bool omitTopP;
  final bool omitReasoning;
  final bool omitReasoningEffort;
  final int reasoningHistoryCount;
  final int maxTokens;
  final int timeoutMs;
  final List<ExtraRequestParameter> extraRequestParameters;

  const StudioSlotSettings({
    required this.temperature,
    required this.topP,
    required this.topK,
    required this.frequencyPenalty,
    required this.presencePenalty,
    required this.requestReasoning,
    required this.useResponsesApi,
    required this.reasoningEffort,
    required this.omitTemperature,
    required this.omitTopP,
    required this.omitReasoning,
    required this.omitReasoningEffort,
    this.reasoningHistoryCount = 0,
    required this.maxTokens,
    required this.timeoutMs,
    required this.extraRequestParameters,
  });

  PipelineSettings applyTo(PipelineSettings pipeline, StudioSlot slot) {
    switch (slot) {
      case StudioSlot.finalGenerator:
        return pipeline.copyWith(
          studioAgent: pipeline.studioAgent.copyWith(
            studioFinalTemperature: temperature,
            studioFinalTopP: topP,
            studioFinalTopK: topK,
            studioFinalFrequencyPenalty: frequencyPenalty,
            studioFinalPresencePenalty: presencePenalty,
            studioFinalRequestReasoning: requestReasoning,
            studioFinalUseResponsesApi: useResponsesApi,
            studioFinalReasoningEffort: reasoningEffort,
            studioFinalOmitTemperature: omitTemperature,
            studioFinalOmitTopP: omitTopP,
            studioFinalOmitReasoning: omitReasoning,
            studioFinalOmitReasoningEffort: omitReasoningEffort,
            studioFinalReasoningHistoryCount: reasoningHistoryCount,
            studioFinalMaxTokens: maxTokens,
            studioFinalTimeoutMs: timeoutMs,
            studioFinalExtraRequestParameters: extraRequestParameters,
          ),
        );
      case StudioSlot.tracker:
        return pipeline.copyWith(
          studioAgent: pipeline.studioAgent.copyWith(
            studioTrackerTemperature: temperature,
            studioTrackerTopP: topP,
            studioTrackerTopK: topK,
            studioTrackerFrequencyPenalty: frequencyPenalty,
            studioTrackerPresencePenalty: presencePenalty,
            studioTrackerRequestReasoning: requestReasoning,
            studioTrackerUseResponsesApi: useResponsesApi,
            studioTrackerReasoningEffort: reasoningEffort,
            studioTrackerOmitTemperature: omitTemperature,
            studioTrackerOmitTopP: omitTopP,
            studioTrackerOmitReasoning: omitReasoning,
            studioTrackerOmitReasoningEffort: omitReasoningEffort,
            studioTrackerMaxTokens: maxTokens,
            studioTrackerTimeoutMs: timeoutMs,
            studioTrackerExtraRequestParameters: extraRequestParameters,
          ),
        );
      case StudioSlot.cleaner:
        return pipeline.copyWith(
          cleaner: pipeline.cleaner.copyWith(
            postCleanerTemperature: temperature,
            postCleanerTopP: topP,
            postCleanerTopK: topK,
            postCleanerFrequencyPenalty: frequencyPenalty,
            postCleanerPresencePenalty: presencePenalty,
            postCleanerRequestReasoning: requestReasoning,
            postCleanerUseResponsesApi: useResponsesApi,
            postCleanerReasoningEffort: reasoningEffort,
            postCleanerOmitTemperature: omitTemperature,
            postCleanerOmitTopP: omitTopP,
            postCleanerOmitReasoning: omitReasoning,
            postCleanerOmitReasoningEffort: omitReasoningEffort,
            postCleanerMaxTokens: maxTokens,
            postCleanerTimeoutMs: timeoutMs,
            postCleanerExtraRequestParameters: extraRequestParameters,
          ),
        );
    }
  }
}

class StudioSlotSettingsDialog extends StatefulWidget {
  final StudioSlot slot;
  final PipelineSettings pipeline;

  const StudioSlotSettingsDialog({
    super.key,
    required this.slot,
    required this.pipeline,
  });

  @override
  State<StudioSlotSettingsDialog> createState() =>
      _StudioSlotSettingsDialogState();
}

class _StudioSlotSettingsDialogState extends State<StudioSlotSettingsDialog> {
  late double _temperature;
  late double _topP;
  late int _topK;
  late double _frequencyPenalty;
  late double _presencePenalty;
  late bool _requestReasoning;
  late bool _useResponsesApi;
  late String _reasoningEffort;
  late bool _omitTemperature;
  late bool _omitTopP;
  late bool _omitReasoning;
  late bool _omitReasoningEffort;
  late TextEditingController _reasoningHistoryCountCtrl;
  late TextEditingController _maxTokensCtrl;
  late TextEditingController _timeoutCtrl;
  late List<ExtraRequestParameter> _extraRequestParameters;

  @override
  void initState() {
    super.initState();
    final p = widget.pipeline;
    switch (widget.slot) {
      case StudioSlot.finalGenerator:
        _temperature = p.studioAgent.studioFinalTemperature;
        _topP = p.studioAgent.studioFinalTopP;
        _topK = p.studioAgent.studioFinalTopK;
        _frequencyPenalty = p.studioAgent.studioFinalFrequencyPenalty;
        _presencePenalty = p.studioAgent.studioFinalPresencePenalty;
        _requestReasoning = p.studioAgent.studioFinalRequestReasoning;
        _useResponsesApi = p.studioAgent.studioFinalUseResponsesApi;
        _reasoningEffort = p.studioAgent.studioFinalReasoningEffort;
        _omitTemperature = p.studioAgent.studioFinalOmitTemperature;
        _omitTopP = p.studioAgent.studioFinalOmitTopP;
        _omitReasoning = p.studioAgent.studioFinalOmitReasoning;
        _omitReasoningEffort = p.studioAgent.studioFinalOmitReasoningEffort;
        _reasoningHistoryCountCtrl = TextEditingController(
          text: '${p.studioAgent.studioFinalReasoningHistoryCount}',
        );
        _maxTokensCtrl = TextEditingController(
          text: p.studioAgent.studioFinalMaxTokens > 0
              ? '${p.studioAgent.studioFinalMaxTokens}'
              : '',
        );
        _timeoutCtrl = TextEditingController(
          text: p.studioAgent.studioFinalTimeoutMs > 0
              ? '${p.studioAgent.studioFinalTimeoutMs ~/ 1000}'
              : '',
        );
        _extraRequestParameters =
            p.studioAgent.studioFinalExtraRequestParameters;
      case StudioSlot.tracker:
        _temperature = p.studioAgent.studioTrackerTemperature;
        _topP = p.studioAgent.studioTrackerTopP;
        _topK = p.studioAgent.studioTrackerTopK;
        _frequencyPenalty = p.studioAgent.studioTrackerFrequencyPenalty;
        _presencePenalty = p.studioAgent.studioTrackerPresencePenalty;
        _requestReasoning = p.studioAgent.studioTrackerRequestReasoning;
        _useResponsesApi = p.studioAgent.studioTrackerUseResponsesApi;
        _reasoningEffort = p.studioAgent.studioTrackerReasoningEffort;
        _omitTemperature = p.studioAgent.studioTrackerOmitTemperature;
        _omitTopP = p.studioAgent.studioTrackerOmitTopP;
        _omitReasoning = p.studioAgent.studioTrackerOmitReasoning;
        _omitReasoningEffort = p.studioAgent.studioTrackerOmitReasoningEffort;
        _reasoningHistoryCountCtrl = TextEditingController(text: '0');
        _maxTokensCtrl = TextEditingController(
          text: p.studioAgent.studioTrackerMaxTokens > 0
              ? '${p.studioAgent.studioTrackerMaxTokens}'
              : '',
        );
        _timeoutCtrl = TextEditingController(
          text: p.studioAgent.studioTrackerTimeoutMs > 0
              ? '${p.studioAgent.studioTrackerTimeoutMs ~/ 1000}'
              : '',
        );
        _extraRequestParameters =
            p.studioAgent.studioTrackerExtraRequestParameters;
      case StudioSlot.cleaner:
        _temperature = p.cleaner.postCleanerTemperature;
        _topP = p.cleaner.postCleanerTopP;
        _topK = p.cleaner.postCleanerTopK;
        _frequencyPenalty = p.cleaner.postCleanerFrequencyPenalty;
        _presencePenalty = p.cleaner.postCleanerPresencePenalty;
        _requestReasoning = p.cleaner.postCleanerRequestReasoning;
        _useResponsesApi = p.cleaner.postCleanerUseResponsesApi;
        _reasoningEffort = p.cleaner.postCleanerReasoningEffort;
        _omitTemperature = p.cleaner.postCleanerOmitTemperature;
        _omitTopP = p.cleaner.postCleanerOmitTopP;
        _omitReasoning = p.cleaner.postCleanerOmitReasoning;
        _omitReasoningEffort = p.cleaner.postCleanerOmitReasoningEffort;
        _reasoningHistoryCountCtrl = TextEditingController(text: '0');
        _maxTokensCtrl = TextEditingController(
          text: p.cleaner.postCleanerMaxTokens > 0
              ? '${p.cleaner.postCleanerMaxTokens}'
              : '',
        );
        _timeoutCtrl = TextEditingController(
          text: p.cleaner.postCleanerTimeoutMs > 0
              ? '${p.cleaner.postCleanerTimeoutMs ~/ 1000}'
              : '',
        );
        _extraRequestParameters = p.cleaner.postCleanerExtraRequestParameters;
    }
  }

  @override
  void dispose() {
    _maxTokensCtrl.dispose();
    _timeoutCtrl.dispose();
    _reasoningHistoryCountCtrl.dispose();
    super.dispose();
  }

  String get _slotTitle {
    switch (widget.slot) {
      case StudioSlot.finalGenerator:
        return 'Final Generator';
      case StudioSlot.tracker:
        return 'Trackers';
      case StudioSlot.cleaner:
        return 'Cleaner';
    }
  }

  String get _maxTokensLabel {
    switch (widget.slot) {
      case StudioSlot.finalGenerator:
        return 'Max response length (0 = default)';
      case StudioSlot.tracker:
        return 'Max response length (0 = default)';
      case StudioSlot.cleaner:
        return 'Max response length (0 = default)';
    }
  }

  String get _maxTokensHint {
    switch (widget.slot) {
      case StudioSlot.finalGenerator:
        return '8000';
      case StudioSlot.tracker:
        return '1600';
      case StudioSlot.cleaner:
        return '0';
    }
  }

  /// Slot-specific timeout label showing the fallback default (in seconds)
  /// that applies when the field is left at 0. The defaults mirror the
  /// hardcoded fallbacks in `AgentRunner.effectiveTimeoutMs` (final 90 s,
  /// trackers 60 s) and `AuxLlmClient.resolveCleanerTimeout` (cleaner 60 s).
  String get _timeoutLabel {
    switch (widget.slot) {
      case StudioSlot.finalGenerator:
        return 'Timeout seconds (0 = 90s default)';
      case StudioSlot.tracker:
        return 'Timeout seconds (0 = 60s default)';
      case StudioSlot.cleaner:
        return 'Timeout seconds (0 = 60s default)';
    }
  }

  String get _timeoutHint {
    switch (widget.slot) {
      case StudioSlot.finalGenerator:
        return '90';
      case StudioSlot.tracker:
        return '60';
      case StudioSlot.cleaner:
        return '60';
    }
  }

  String _reasoningEffortLabel(String effort) {
    return switch (effort) {
      'auto' => 'Auto',
      'min' => 'Min',
      'low' => 'Low',
      'medium' => 'Medium',
      'high' => 'High',
      'max' => 'Max',
      _ => effort,
    };
  }

  Future<void> _openReasoningEffortSelector() async {
    const options = ['auto', 'min', 'low', 'medium', 'high', 'max'];
    await GlazeBottomSheet.show<void>(
      context,
      title: 'Reasoning Effort',
      items: options.map((option) {
        final active = option == _reasoningEffort;
        return BottomSheetItem(
          label: _reasoningEffortLabel(option),
          icon: active ? Icons.check : null,
          iconColor: Theme.of(context).colorScheme.primary,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            setState(() => _reasoningEffort = option);
          },
        );
      }).toList(),
    );
  }

  void _save() {
    final maxTokens = int.tryParse(_maxTokensCtrl.text.trim()) ?? 0;
    final reasoningHistoryCount =
        int.tryParse(_reasoningHistoryCountCtrl.text.trim()) ?? 0;
    final seconds = int.tryParse(_timeoutCtrl.text.trim()) ?? 0;
    final timeoutMs = seconds > 0 ? seconds * 1000 : 0;
    Navigator.of(context).pop(
      StudioSlotSettings(
        temperature: _temperature,
        topP: _topP,
        topK: _topK,
        frequencyPenalty: _frequencyPenalty,
        presencePenalty: _presencePenalty,
        requestReasoning: _requestReasoning,
        useResponsesApi: _useResponsesApi,
        reasoningEffort: _reasoningEffort,
        omitTemperature: _omitTemperature,
        omitTopP: _omitTopP,
        omitReasoning: _omitReasoning,
        omitReasoningEffort: _omitReasoningEffort,
        reasoningHistoryCount: reasoningHistoryCount < -1
            ? 0
            : reasoningHistoryCount,
        maxTokens: maxTokens,
        timeoutMs: timeoutMs,
        extraRequestParameters: _extraRequestParameters,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SheetView(
      title: '$_slotTitle Settings',
      showHandle: true,
      bodyPadding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      actions: [
        SheetViewAction(
          icon: const Icon(Icons.check, size: 22),
          tooltip: 'Save',
          onPressed: _save,
        ),
      ],
      body: ListView(
        children: [
          const SizedBox(height: 8),
          MenuGroup(
            compact: true,
            header: 'Параметры генерации',
            items: [
              MenuRangeItem(
                label: 'Temperature',
                value: _temperature,
                min: 0,
                max: 2,
                divisions: 200,
                editableValue: true,
                included: !_omitTemperature,
                onIncludedChanged: (v) => setState(() => _omitTemperature = !v),
                onChanged: (v) => setState(() => _temperature = v),
              ),
              MenuRangeItem(
                label: 'Top P',
                value: _topP,
                min: 0,
                max: 1,
                divisions: 100,
                editableValue: true,
                included: !_omitTopP,
                onIncludedChanged: (v) => setState(() => _omitTopP = !v),
                onChanged: (v) => setState(() => _topP = v),
              ),
              MenuRangeItem(
                label: 'Top K',
                value: _topK.toDouble(),
                min: 0,
                max: 200,
                divisions: 200,
                editableValue: true,
                decimalPlaces: 0,
                onChanged: (v) => setState(() => _topK = v.round()),
              ),
              MenuRangeItem(
                label: 'Частотный штраф',
                value: _frequencyPenalty,
                min: -2,
                max: 2,
                divisions: 80,
                editableValue: true,
                onChanged: (v) => setState(() => _frequencyPenalty = v),
              ),
              MenuRangeItem(
                label: 'Штраф присутствия',
                value: _presencePenalty,
                min: -2,
                max: 2,
                divisions: 80,
                editableValue: true,
                onChanged: (v) => setState(() => _presencePenalty = v),
              ),
              MenuFieldItem(
                label: _maxTokensLabel,
                controller: _maxTokensCtrl,
                placeholder: _maxTokensHint,
                keyboardType: TextInputType.number,
              ),
              MenuFieldItem(
                label: _timeoutLabel,
                controller: _timeoutCtrl,
                placeholder: _timeoutHint,
                keyboardType: TextInputType.number,
              ),
            ],
          ),
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
          MenuGroup(
            compact: true,
            header: 'Мышление',
            items: [
              MenuSwitchItem(
                label: 'label_use_responses_api'.tr(),
                description: 'desc_use_responses_api'.tr(),
                value: _useResponsesApi,
                onChanged: (value) => setState(() => _useResponsesApi = value),
              ),
              MenuSwitchItem(
                label: 'Запросить нативное мышление',
                description: 'Показывает блок нативного мышления модели',
                included: !_omitReasoning,
                onIncludedChanged: (v) => setState(() => _omitReasoning = !v),
                value: _requestReasoning,
                onChanged: (v) => setState(() => _requestReasoning = v),
              ),
              MenuSelectorItem(
                label: 'Уровень мышления',
                currentValue: _reasoningEffortLabel(_reasoningEffort),
                included: !_omitReasoningEffort,
                onIncludedChanged: (v) =>
                    setState(() => _omitReasoningEffort = !v),
                onTap: _openReasoningEffortSelector,
              ),
              if (widget.slot == StudioSlot.finalGenerator)
                MenuFieldItem(
                  label: 'Reasoning-блоки (-1 = все, 0 = не передавать)',
                  controller: _reasoningHistoryCountCtrl,
                  placeholder: '0',
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
    );
  }
}
