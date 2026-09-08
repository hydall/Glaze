import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/memory_budget.dart';
import '../../../core/llm/model_fetcher.dart';
import '../../../core/models/memory_book.dart';
import '../../../core/services/memory_prompt_presets.dart';
import '../../../core/state/memory_settings_provider.dart';
import '../../../core/state/pipeline_settings_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../settings/api_list_provider.dart';
import 'custom_prompt_manager_sheet.dart';

class MemoryGenerationSettingsSheet extends ConsumerStatefulWidget {
  final MemoryBookSettings settings;
  final String? sessionId;

  const MemoryGenerationSettingsSheet({
    super.key,
    required this.settings,
    this.sessionId,
  });

  @override
  ConsumerState<MemoryGenerationSettingsSheet> createState() =>
      _MemoryGenerationSettingsSheetState();
}

class _MemoryGenerationSettingsSheetState
    extends ConsumerState<MemoryGenerationSettingsSheet> {
  late bool _enabled;
  late String _memoryMode;
  late bool _autoCreate;
  late bool _autoGenerate;
  late int _maxInjected;
  late bool _memoryExcerptingEnabled;
  late String _memoryPackingMode;
  late int _memoryExcerptTokensPerChunk;
  late int _memoryExcerptChunksPerEntry;
  late int _chunkFirstTopEntries;
  late int _chunkFirstTopChunks;
  late String _memoryBudgetPreset;
  late int? _maxInjectedTokens;
  late int _autoCreateInterval;
  late int _autoCreateLagMessages;
  late int _batchSize;
  late bool _useDelayedAutomation;
  late String _injectionTarget;
  late String _promptPreset;
  late String _keyMatchMode;
  late bool _vectorSearchEnabled;
  late double _vectorThreshold;
  late bool _advancedSelectorOpen;
  late bool _diversityAware;
  late double _diversityPenalty;
  late bool _recencyBoost;
  late double _recencyHalfLifeDays;
  late bool _importanceBoost;
  late double _importanceWeight;
  late bool _sourceWindowExclusion;
  late bool _factualContinuityGuardEnabled;
  late bool _queryIncludeAssistant;
  late int _queryRecentTurns;
  late int _queryMaxChars;

  late final TextEditingController _memoryBudgetCtrl;

  // ── Memory generation model ──────────────────────────────────────────
  // Restored from pre-eec6d6f2 (pipeline settings separation). The model
  // dropdown lives here in the MemoryBooks sheet; it reads/writes
  // PipelineSettings.memoryBookApi.generationModel. Endpoint/key are always inherited
  // from the active chat API (generationSource='current').
  List<String> _fetchedModels = const [];
  bool _fetchingModels = false;

  late String _generationModel;

  @override
  void initState() {
    super.initState();
    final s = widget.settings;
    _enabled = s.enabled;
    _memoryMode = _normalizeMemoryMode(s.memoryMode);
    _autoCreate = s.autoCreateEnabled;
    _autoGenerate = s.autoGenerateEnabled;
    _maxInjected = s.maxInjectedEntries;
    _memoryExcerptingEnabled = s.memoryExcerptingEnabled;
    _memoryPackingMode = _normalizeMemoryPackingMode(s.memoryPackingMode);
    _memoryExcerptTokensPerChunk = s.memoryExcerptTokensPerChunk.clamp(
      100,
      2000,
    );
    _memoryExcerptChunksPerEntry = s.memoryExcerptChunksPerEntry.clamp(1, 10);
    _chunkFirstTopEntries = s.chunkFirstTopEntries.clamp(0, 20);
    _chunkFirstTopChunks =
        (s.chunkFirstTopChunks <= 0 ? 1 : s.chunkFirstTopChunks).clamp(1, 10);
    _memoryBudgetPreset = _normalizeMemoryBudgetPreset(
      s.memoryBudgetPreset,
      s.maxInjectedTokens,
    );
    _maxInjectedTokens = _memoryBudgetTokensForPreset(
      _memoryBudgetPreset,
      s.maxInjectedTokens,
    );
    _memoryBudgetCtrl = TextEditingController(
      text: (_maxInjectedTokens ?? 6000).toString(),
    );
    _autoCreateInterval = s.autoCreateInterval;
    _autoCreateLagMessages = s.autoCreateLagMessages;
    _batchSize = s.batchSize;
    _useDelayedAutomation = s.useDelayedAutomation;
    _injectionTarget = _migrateInjectionTarget(s.injectionTarget);
    _promptPreset = s.promptPreset;
    _keyMatchMode = s.keyMatchMode;
    _vectorSearchEnabled = s.vectorSearchEnabled;
    _vectorThreshold = ref.read(memoryGlobalSettingsProvider).vectorThreshold;
    _advancedSelectorOpen = true;
    _diversityAware = s.diversityAware;
    _diversityPenalty = s.diversityPenalty;
    _recencyBoost = s.recencyBoost;
    _recencyHalfLifeDays = s.recencyHalfLifeDays;
    _importanceBoost = s.importanceBoost;
    _importanceWeight = s.importanceWeight;
    _sourceWindowExclusion = s.sourceWindowExclusion;
    _factualContinuityGuardEnabled = s.factualContinuityGuardEnabled;
    _queryIncludeAssistant = s.queryIncludeAssistant;
    _queryRecentTurns = s.queryRecentTurns;
    _queryMaxChars = s.queryMaxChars;
    // Load the generation model from PipelineSettings.
    _generationModel =
        ref.read(pipelineSettingsProvider).memoryBookApi.generationModel;
  }

  @override
  void dispose() {
    _memoryBudgetCtrl.dispose();
    super.dispose();
  }

  List<MemoryPromptPreset> get _customPrompts =>
      MemoryPromptPreset.fromJsonList(
        ref.read(memoryGlobalSettingsProvider).customPrompts,
      );

  void _save() {
    final settings = widget.settings.copyWith(
      enabled: _enabled,
      memoryMode: _memoryMode,
      autoCreateEnabled: _autoCreate,
      autoGenerateEnabled: _autoGenerate,
      maxInjectedEntries: _maxInjected,
      memoryExcerptingEnabled: _memoryExcerptingEnabled,
      memoryPackingMode: _memoryPackingMode,
      memoryExcerptTokensPerChunk: _memoryExcerptTokensPerChunk,
      memoryExcerptChunksPerEntry: _memoryExcerptChunksPerEntry,
      chunkFirstTopEntries: _chunkFirstTopEntries,
      chunkFirstTopChunks: _chunkFirstTopChunks,
      maxInjectedTokens: _maxInjectedTokens,
      memoryBudgetPreset: _memoryBudgetPreset,
      autoCreateInterval: _autoCreateInterval,
      autoCreateLagMessages: _autoCreateLagMessages,
      batchSize: _batchSize,
      useDelayedAutomation: _useDelayedAutomation,
      injectionTarget: _injectionTarget,
      promptPreset: _promptPreset,
      keyMatchMode: _keyMatchMode,
      vectorSearchEnabled: _vectorSearchEnabled,
      diversityAware: _diversityAware,
      diversityPenalty: _diversityPenalty,
      recencyBoost: _recencyBoost,
      recencyHalfLifeDays: _recencyHalfLifeDays,
      importanceBoost: _importanceBoost,
      importanceWeight: _importanceWeight,
      sourceWindowExclusion: _sourceWindowExclusion,
      factualContinuityGuardEnabled: _factualContinuityGuardEnabled,
      queryIncludeAssistant: _queryIncludeAssistant,
      queryRecentTurns: _queryRecentTurns,
      queryMaxChars: _queryMaxChars,
    );
    Navigator.pop(
      context,
      MemorySettingsSheetResult(
        settings: settings,
        vectorThreshold: _vectorThreshold,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _switchTile(
              'label_enabled'.tr(),
              _enabled,
              (v) => setState(() => _enabled = v),
            ),
            _memoryModeSelector(),
            const SizedBox(height: 12),
            _switchTile(
              'memory_books_auto_create'.tr(),
              _autoCreate,
              (v) => setState(() => _autoCreate = v),
              subtitle: 'memory_books_auto_create_desc'.tr(),
            ),
            _switchTile(
              'memory_books_auto_generate'.tr(),
              _autoGenerate,
              (v) => setState(() => _autoGenerate = v),
              subtitle: 'memory_books_auto_generate_desc'.tr(),
            ),
            if (_autoCreate) ...[
              _switchTile(
                'memory_books_delayed_automation'.tr(),
                _useDelayedAutomation,
                (v) => setState(() => _useDelayedAutomation = v),
                subtitle: 'memory_books_delayed_automation_desc'.tr(),
              ),
              _numberField(
                'memory_books_auto_create_interval'.tr(),
                _autoCreateInterval,
                (v) => setState(() => _autoCreateInterval = v),
                min: 1,
                max: 200,
              ),
              _numberField(
                'memory_books_auto_create_lag'.tr(),
                _autoCreateLagMessages,
                (v) => setState(() => _autoCreateLagMessages = v),
                min: 0,
                max: 50,
                helpTitle: 'memory_books_auto_create_lag'.tr(),
                helpBody: 'memory_books_auto_create_lag_help'.tr(),
              ),
            ],
            _numberField(
              'memory_books_batch_size'.tr(),
              _batchSize,
              (v) => setState(() => _batchSize = v),
              min: 1,
              max: 50,
            ),
            const SizedBox(height: 12),
            _selectorSettings(),
            const SizedBox(height: 12),
            _sectionLabel('label_embedding_target'.tr()),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(
                  value: 'hard_block',
                  label: Text('memory_injection_hard_block'.tr()),
                ),
                ButtonSegment(
                  value: 'macro',
                  label: Text('memory_injection_macro'.tr()),
                ),
              ],
              selected: {_injectionTarget},
              onSelectionChanged: (s) =>
                  setState(() => _injectionTarget = s.first),
              style: ButtonStyle(visualDensity: VisualDensity.compact),
            ),
            const SizedBox(height: 12),
            _sectionLabel('regex_script_settings'.tr()),
            _promptPresetSelector(),
            const SizedBox(height: 12),
            _sectionLabel('tab_api'.tr()),
            _buildModelSelector(),
            const SizedBox(height: 12),
            _sectionLabel('search'.tr()),
            _switchTile(
              'label_vector_search'.tr(),
              _vectorSearchEnabled,
              (v) => setState(() => _vectorSearchEnabled = v),
            ),
            if (_vectorSearchEnabled) ...[
              const SizedBox(height: 8),
              _sliderField(
                label: 'label_similarity_threshold'.tr(),
                value: _vectorThreshold,
                min: 0.0,
                max: 1.0,
                divisions: 20,
                display: _vectorThreshold.toStringAsFixed(2),
                onChanged: (v) => setState(() => _vectorThreshold = v),
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: 'plain',
                    label: Text('memory_packing_plain'.tr()),
                  ),
                  ButtonSegment(
                    value: 'glaze',
                    label: Text('memory_packing_glaze'.tr()),
                  ),
                  ButtonSegment(
                    value: 'both',
                    label: Text('memory_packing_both'.tr()),
                  ),
                ],
                selected: {_keyMatchMode},
                onSelectionChanged: (s) =>
                    setState(() => _keyMatchMode = s.first),
                style: ButtonStyle(visualDensity: VisualDensity.compact),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('btn_cancel'.tr()),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: context.cs.primary,
                    foregroundColor: Colors.black,
                  ),
                  onPressed: _save,
                  child: Text('btn_save'.tr()),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _selectorSettings() {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: const Key('memory_advanced_selector_settings'),
        initiallyExpanded: _advancedSelectorOpen,
        onExpansionChanged: (value) =>
            setState(() => _advancedSelectorOpen = value),
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Text(
          'memory_selector_settings'.tr(),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: context.cs.onSurfaceVariant,
          ),
        ),
        subtitle: Text(
          'memory_selector_advanced_desc'.tr(),
          style: TextStyle(fontSize: 11, color: context.cs.onSurfaceVariant),
        ),
        children: [
          _numberField(
            'memory_books_max_entries_prompt'.tr(),
            _maxInjected,
            (v) => setState(() => _maxInjected = v),
            min: 1,
            max: 20,
          ),
          const SizedBox(height: 12),
          _sectionLabel('memory_budget'.tr()),
          _memoryBudgetSelector(),
          const SizedBox(height: 8),
          _effectiveBudgetHint(),
          _switchTile(
            'memory_excerpting_enabled'.tr(),
            _memoryExcerptingEnabled,
            (v) => setState(() => _memoryExcerptingEnabled = v),
            subtitle: 'memory_excerpting_auto_desc'.tr(),
          ),
          if (_memoryExcerptingEnabled) ...[
            const SizedBox(height: 8),
            _packingModeSelector(),
            const SizedBox(height: 12),
            _numberField(
              'memory_excerpt_tokens_per_chunk'.tr(),
              _memoryExcerptTokensPerChunk,
              (v) => setState(() => _memoryExcerptTokensPerChunk = v),
              min: 100,
              max: 2000,
              step: 100,
              helpTitle: 'memory_excerpt_tokens_per_chunk'.tr(),
              helpBody: 'memory_excerpt_tokens_per_chunk_help'.tr(),
            ),
            _numberField(
              'memory_excerpt_chunks_per_entry'.tr(),
              _memoryExcerptChunksPerEntry,
              (v) => setState(() => _memoryExcerptChunksPerEntry = v),
              min: 1,
              max: 10,
              helpTitle: 'memory_excerpt_chunks_per_entry'.tr(),
              helpBody: 'memory_excerpt_chunks_per_entry_help'.tr(),
            ),
            if (_memoryPackingMode == 'chunk_first') ...[
              const SizedBox(height: 8),
              _numberField(
                'memory_chunk_first_top_entries'.tr(),
                _chunkFirstTopEntries,
                (v) => setState(() => _chunkFirstTopEntries = v),
                min: 0,
                max: 20,
                helpTitle: 'memory_chunk_first_top_entries'.tr(),
                helpBody: 'memory_chunk_first_top_entries_help'.tr(),
              ),
              if (_chunkFirstTopEntries > 0)
                _numberField(
                  'memory_chunk_first_top_chunks'.tr(),
                  _chunkFirstTopChunks,
                  (v) => setState(() => _chunkFirstTopChunks = v),
                  min: 1,
                  max: 10,
                  helpTitle: 'memory_chunk_first_top_chunks'.tr(),
                  helpBody: 'memory_chunk_first_top_chunks_help'.tr(),
                ),
            ],
          ],
          const SizedBox(height: 8),
          _switchTile(
            'memory_selector_diversity'.tr(),
            _diversityAware,
            (v) => setState(() => _diversityAware = v),
            subtitle: 'memory_selector_diversity_desc'.tr(),
          ),
          if (_diversityAware)
            _sliderField(
              label: 'memory_selector_diversity_penalty'.tr(),
              value: _diversityPenalty,
              min: 0,
              max: 1,
              divisions: 20,
              display: _diversityPenalty.toStringAsFixed(2),
              onChanged: (v) => setState(() => _diversityPenalty = v),
            ),
          _switchTile(
            'memory_selector_recency'.tr(),
            _recencyBoost,
            (v) => setState(() => _recencyBoost = v),
            subtitle: 'memory_selector_recency_desc'.tr(),
          ),
          if (_recencyBoost)
            _sliderField(
              label: 'memory_selector_recency_half_life'.tr(),
              value: _recencyHalfLifeDays,
              min: 10,
              max: 1000,
              divisions: 99,
              display: _recencyHalfLifeDays.toStringAsFixed(1),
              onChanged: (v) => setState(() => _recencyHalfLifeDays = v),
              helpTitle: 'memory_selector_recency_half_life'.tr(),
              helpBody: 'memory_selector_recency_half_life_help'.tr(),
            ),
          _switchTile(
            'memory_selector_importance'.tr(),
            _importanceBoost,
            (v) => setState(() => _importanceBoost = v),
            subtitle: 'memory_selector_importance_desc'.tr(),
          ),
          if (_importanceBoost)
            _sliderField(
              label: 'memory_selector_importance_weight'.tr(),
              value: _importanceWeight,
              min: 0,
              max: 2,
              divisions: 40,
              display: _importanceWeight.toStringAsFixed(2),
              onChanged: (v) => setState(() => _importanceWeight = v),
            ),
          _switchTile(
            'memory_selector_exclude_visible'.tr(),
            _sourceWindowExclusion,
            (v) => setState(() => _sourceWindowExclusion = v),
            subtitle: 'memory_selector_exclude_visible_desc'.tr(),
          ),
          _switchTile(
            'memory_selector_continuity_guard'.tr(),
            _factualContinuityGuardEnabled,
            (v) => setState(() => _factualContinuityGuardEnabled = v),
            subtitle: 'memory_selector_continuity_guard_desc'.tr(),
          ),
          _switchTile(
            'memory_selector_query_assistant'.tr(),
            _queryIncludeAssistant,
            (v) => setState(() => _queryIncludeAssistant = v),
            subtitle: 'memory_selector_query_assistant_desc'.tr(),
          ),
          _numberField(
            'memory_selector_query_recent_turns'.tr(),
            _queryRecentTurns,
            (v) => setState(() => _queryRecentTurns = v),
            min: 1,
            max: 20,
            helpTitle: 'memory_selector_query_recent_turns'.tr(),
            helpBody: 'memory_selector_query_recent_turns_help'.tr(),
          ),
          _numberField(
            'memory_selector_query_max_chars'.tr(),
            _queryMaxChars,
            (v) => setState(() => _queryMaxChars = v),
            min: 500,
            max: 5000,
            step: 250,
            helpTitle: 'memory_selector_query_max_chars'.tr(),
            helpBody: 'memory_selector_query_max_chars_help'.tr(),
          ),
        ],
      ),
    );
  }

  Widget _memoryModeSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('memory_mode'.tr()),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(
              value: 'legacy',
              label: Text('memory_mode_legacy'.tr()),
              icon: Icon(Icons.restore_rounded),
            ),
            ButtonSegment(
              value: 'fast',
              label: Text('memory_mode_fast'.tr()),
              icon: Icon(Icons.bolt_rounded),
            ),
            ButtonSegment(
              value: 'balanced',
              label: Text('memory_mode_balanced'.tr()),
              icon: Icon(Icons.tune_rounded),
            ),
            ButtonSegment(
              value: 'deep',
              label: Text('memory_mode_deep'.tr()),
              icon: Icon(Icons.manage_search_rounded),
            ),
          ],
          selected: {_memoryMode},
          onSelectionChanged: (s) => setState(() => _memoryMode = s.first),
          style: ButtonStyle(visualDensity: VisualDensity.compact),
        ),
        const SizedBox(height: 6),
        Text(
          _memoryMode == 'legacy'
              ? 'memory_mode_legacy_desc'.tr()
              : _memoryMode == 'balanced'
              ? 'memory_mode_balanced_desc'.tr()
              : _memoryMode == 'deep'
              ? 'memory_mode_deep_desc'.tr()
              : 'memory_mode_fast_desc'.tr(),
          style: TextStyle(fontSize: 11, color: context.cs.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _packingModeSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('memory_packing_mode'.tr()),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(
              value: 'full',
              label: Text('memory_packing_full'.tr()),
            ),
            ButtonSegment(
              value: 'hybrid',
              label: Text('memory_packing_hybrid'.tr()),
            ),
            ButtonSegment(
              value: 'chunk_first',
              label: Text('memory_packing_chunk_first'.tr()),
            ),
          ],
          selected: {_memoryPackingMode},
          onSelectionChanged: (s) =>
              setState(() => _memoryPackingMode = s.first),
          style: ButtonStyle(visualDensity: VisualDensity.compact),
        ),
        const SizedBox(height: 6),
        Text(
          _memoryPackingMode == 'full'
              ? 'memory_packing_full_desc'.tr()
              : _memoryPackingMode == 'chunk_first'
              ? 'memory_packing_chunk_first_desc'.tr()
              : 'memory_packing_hybrid_desc'.tr(),
          style: TextStyle(fontSize: 11, color: context.cs.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _switchTile(
    String label,
    bool value,
    ValueChanged<bool> onChanged, {
    String? subtitle,
  }) {
    return SwitchListTile(
      title: Text(
        label,
        style: TextStyle(fontSize: 14, color: context.cs.onSurface),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: TextStyle(
                fontSize: 11,
                color: context.cs.onSurfaceVariant,
              ),
            )
          : null,
      value: value,
      onChanged: onChanged,
      dense: true,
      activeThumbColor: context.cs.primary,
      contentPadding: EdgeInsets.zero,
    );
  }

  Widget _numberField(
    String label,
    int value,
    ValueChanged<int> onChanged, {
    int min = 0,
    int max = 99999,
    int step = 1,
    String? helpTitle,
    String? helpBody,
  }) {
    final normalized = min + (((value - min) / step).round() * step);
    final clamped = normalized.clamp(min, max);
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 13, color: context.cs.onSurface),
                ),
              ),
              if (helpTitle != null && helpBody != null)
                _helpButton(title: helpTitle, body: helpBody),
            ],
          ),
        ),
        SizedBox(
          width: 80,
          child: DropdownButton<int>(
            value: clamped,
            items: List.generate(
              ((max - min) ~/ step) + 1,
              (i) => DropdownMenuItem(
                value: min + (i * step),
                child: Text('${min + (i * step)}'),
              ),
            ),
            onChanged: (v) => onChanged(v ?? value),
            underline: const SizedBox.shrink(),
            style: TextStyle(fontSize: 14, color: context.cs.primary),
          ),
        ),
      ],
    );
  }

  Widget _memoryBudgetSelector() {
    return SegmentedButton<String>(
      segments: [
        ButtonSegment(value: 'auto', label: Text('memory_size_auto'.tr())),
        ButtonSegment(value: 'small', label: Text('memory_size_small'.tr())),
        ButtonSegment(value: 'medium', label: Text('memory_size_medium'.tr())),
        ButtonSegment(value: 'large', label: Text('memory_size_large'.tr())),
        ButtonSegment(value: 'custom', label: Text('memory_size_custom'.tr())),
      ],
      selected: {_memoryBudgetPreset},
      onSelectionChanged: (selected) {
        final preset = selected.first;
        setState(() {
          _memoryBudgetPreset = preset;
          _maxInjectedTokens = _memoryBudgetTokensForPreset(
            preset,
            _maxInjectedTokens,
          );
          if (_maxInjectedTokens != null) {
            _memoryBudgetCtrl.text = _maxInjectedTokens.toString();
          }
        });
      },
      style: ButtonStyle(visualDensity: VisualDensity.compact),
    );
  }

  Widget _effectiveBudgetHint() {
    final breakdown = MemoryInjectionBudget.describeBudget(
      contextBudgetTokens: 32000,
      percent: widget.settings.maxInjectionBudgetPercent,
      absoluteCap: _maxInjectedTokens,
    );
    final percentTokens = breakdown.percentTokens;
    final absoluteTokens = breakdown.absoluteTokens;
    final effectiveTokens = breakdown.effectiveTokens;
    final text = absoluteTokens == null
        ? 'At 32k context: uses ${_formatTokens(percentTokens)} from the percent budget.'
        : 'At 32k context: min(${_formatTokens(percentTokens)}, ${_formatTokens(absoluteTokens)}) = ${_formatTokens(effectiveTokens)}. Entries cap stays $_maxInjected.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_memoryBudgetPreset == 'custom')
          TextField(
            key: const Key('memory_custom_token_budget_field'),
            controller: _memoryBudgetCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (value) {
              final parsed = int.tryParse(value);
              setState(() {
                _maxInjectedTokens = parsed != null && parsed > 0
                    ? parsed
                    : null;
              });
            },
            style: TextStyle(color: context.cs.onSurface, fontSize: 14),
            decoration: InputDecoration(
              labelText: 'memory_max_tokens_label'.tr(),
              hintText: 'memory_max_tokens_hint'.tr(),
              labelStyle: TextStyle(
                color: context.cs.onSurfaceVariant,
                fontSize: 12,
              ),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
          ),
        if (_memoryBudgetPreset == 'custom') const SizedBox(height: 8),
        Text(
          text,
          style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
        ),
      ],
    );
  }

  String _normalizeMemoryBudgetPreset(String preset, int? tokens) {
    if (preset == 'small' ||
        preset == 'medium' ||
        preset == 'large' ||
        preset == 'custom') {
      return preset;
    }
    return tokens == null ? 'auto' : 'custom';
  }

  int? _memoryBudgetTokensForPreset(String preset, int? currentCustom) {
    switch (preset) {
      case 'auto':
        return null;
      case 'small':
        return 3000;
      case 'medium':
        return 6000;
      case 'large':
        return 10000;
      case 'custom':
        return currentCustom ?? 6000;
      default:
        return null;
    }
  }

  String _formatTokens(int? tokens) {
    if (tokens == null) return 'memory_unlimited'.tr();
    return '$tokens ${'memory_tokens'.tr()}';
  }

  Widget _promptPresetSelector() {
    final custom = _customPrompts;
    return Column(
      children: [
        GestureDetector(
          onTap: () async {
            final result = await GlazeBottomSheet.show<String>(
              context,
              title: 'regex_script_settings'.tr(),
              items: [
                ...MemoryPromptPresets.builtIn.map(
                  (p) => BottomSheetItem(
                    label: p.label,
                    icon: p.key == _promptPreset ? Icons.check : null,
                    iconColor: context.cs.primary,
                    onTap: () => Navigator.pop(context, p.key),
                  ),
                ),
                if (custom.isNotEmpty)
                  BottomSheetItem(
                    label: 'memory_custom_label'.tr(),
                    centered: true,
                    onTap: () {},
                  ),
                ...custom.map(
                  (p) => BottomSheetItem(
                    label: p.label,
                    icon: p.key == _promptPreset ? Icons.check : null,
                    iconColor: context.cs.primary,
                    onTap: () => Navigator.pop(context, p.key),
                  ),
                ),
              ],
            );
            if (result != null) setState(() => _promptPreset = result);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  MemoryPromptPresets.label(_promptPreset, custom),
                  style: TextStyle(fontSize: 13, color: context.cs.onSurface),
                ),
                Icon(
                  Icons.arrow_drop_down,
                  size: 20,
                  color: context.cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _openPromptManager,
            icon: const Icon(Icons.manage_accounts_rounded, size: 16),
            label: Text('regex_script_settings'.tr()),
            style: TextButton.styleFrom(
              foregroundColor: context.cs.primary,
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
          ),
        ),
      ],
    );
  }

  void _openPromptManager() async {
    final custom = _customPrompts;
    final result = await GlazeBottomSheet.show<List<MemoryPromptPreset>>(
      context,
      title: "${'theme_custom_font_size'.tr()} ${'label_preset_prompts'.tr()}",
      child: CustomPromptManagerSheet(customPrompts: custom, onChanged: (_) {}),
    );
    if (result != null) {
      final notifier = ref.read(memoryGlobalSettingsProvider.notifier);
      final current = ref.read(memoryGlobalSettingsProvider);
      await notifier.save(
        MemoryGlobalSettings(
          enabled: current.enabled,
          memoryMode: current.memoryMode,
          autoCreateEnabled: current.autoCreateEnabled,
          autoGenerateEnabled: current.autoGenerateEnabled,
          maxInjectedEntries: current.maxInjectedEntries,
          memoryExcerptingEnabled: current.memoryExcerptingEnabled,
          memoryPackingMode: current.memoryPackingMode,
          memoryExcerptTokensPerChunk: current.memoryExcerptTokensPerChunk,
          memoryExcerptChunksPerEntry: current.memoryExcerptChunksPerEntry,
          chunkFirstTopEntries: current.chunkFirstTopEntries,
          chunkFirstTopChunks: current.chunkFirstTopChunks,
          maxInjectedTokens: current.maxInjectedTokens,
          memoryBudgetPreset: current.memoryBudgetPreset,
          autoCreateInterval: current.autoCreateInterval,
          autoCreateLagMessages: current.autoCreateLagMessages,
          useDelayedAutomation: current.useDelayedAutomation,
          injectionTarget: current.injectionTarget,
          batchSize: current.batchSize,
          parallelJobs: current.parallelJobs,
          vectorSearchEnabled: current.vectorSearchEnabled,
          keyMatchMode: current.keyMatchMode,
          promptPreset: current.promptPreset,
          diversityAware: current.diversityAware,
          diversityPenalty: current.diversityPenalty,
          recencyBoost: current.recencyBoost,
          recencyHalfLifeDays: current.recencyHalfLifeDays,
          importanceBoost: current.importanceBoost,
          importanceWeight: current.importanceWeight,
          sourceWindowExclusion: current.sourceWindowExclusion,
          factualContinuityGuardEnabled: current.factualContinuityGuardEnabled,
          queryIncludeAssistant: current.queryIncludeAssistant,
          queryRecentTurns: current.queryRecentTurns,
          queryMaxChars: current.queryMaxChars,
          cadenceInterval: current.cadenceInterval,
          consolidationEnabled: current.consolidationEnabled,
          consolidationThreshold: current.consolidationThreshold,
          customPrompts: MemoryPromptPreset.toJsonList(result),
        ),
      );
      setState(() {});
    }
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: context.cs.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _sliderField({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
    String? helpTitle,
    String? helpBody,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        color: context.cs.onSurface,
                      ),
                    ),
                  ),
                  if (helpTitle != null && helpBody != null)
                    _helpButton(title: helpTitle, body: helpBody),
                ],
              ),
            ),
            Text(
              display,
              style: TextStyle(
                fontSize: 12,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _helpButton({required String title, required String body}) {
    return Tooltip(
      message: 'memory_selector_help_tooltip'.tr(),
      child: IconButton(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.all(4),
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        icon: Icon(
          Icons.help_outline_rounded,
          size: 16,
          color: context.cs.onSurfaceVariant,
        ),
        onPressed: () => _showHelpDialog(title: title, body: body),
      ),
    );
  }

  Future<void> _showHelpDialog({required String title, required String body}) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('btn_ok'.tr()),
          ),
        ],
      ),
    );
  }

  /// Model dropdown for the Memory Generation LLM. Fetches models from the
  /// active chat API endpoint on open. Writes the selection to
  /// PipelineSettings.memoryBookApi.generationModel.
  Widget _buildModelSelector() {
    final models = <String>{
      ..._fetchedModels,
      if (_generationModel.isNotEmpty && !_fetchedModels.contains(_generationModel))
        _generationModel,
    }.toList()..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: models.contains(_generationModel) ||
                        _generationModel.isEmpty
                    ? _generationModel
                    : null,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'label_model'.tr(),
                  helperText: _generationModel.isEmpty
                      ? 'memory_leave_blank_hint'.tr()
                      : null,
                  helperMaxLines: 2,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  DropdownMenuItem<String>(
                    value: '',
                    child: Text(
                      _fetchedModels.isEmpty
                          ? 'memory_books_loading_models'.tr()
                          : 'post_building_use_chat_model'.tr(),
                    ),
                  ),
                  ...models.map(
                    (m) => DropdownMenuItem<String>(
                      value: m,
                      child: Text(m, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
                onChanged: (v) async {
                  final model = v ?? '';
                  setState(() => _generationModel = model);
                  final pipeline = ref.read(pipelineSettingsProvider);
                  await ref
                      .read(pipelineSettingsProvider.notifier)
                      .save(
                        pipeline.copyWith(
                          memoryBookApi: pipeline.memoryBookApi.copyWith(
                            generationModel: model,
                          ),
                        ),
                      );
                },
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: 'memory_books_loading_models'.tr(),
              onPressed: _fetchingModels ? null : _fetchModels,
              icon: _fetchingModels
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh, size: 18),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _fetchModels() async {
    final config = ref.read(activeApiConfigProvider);
    if (config == null) {
      if (mounted) GlazeToast.show(context, 'settings_no_api_configs'.tr());
      return;
    }
    setState(() => _fetchingModels = true);
    try {
      final ids = await ModelFetcher.fetchModelIds(
        endpoint: config.endpoint,
        apiKey: config.apiKey,
        fallbackModel: config.model,
      );
      if (!mounted) return;
      setState(() => _fetchedModels = ids);
    } catch (e) {
      if (mounted) {
        GlazeToast.show(context, '${'settings_err_failed'.tr()} $e');
      }
    } finally {
      if (mounted) setState(() => _fetchingModels = false);
    }
  }
}

class MemorySettingsSheetResult {
  final MemoryBookSettings settings;
  final double vectorThreshold;

  const MemorySettingsSheetResult({
    required this.settings,
    required this.vectorThreshold,
  });
}

/// Translates the legacy `summary_block` / `summary_macro` enum values
/// (pre-{{memory}}-split) to `hard_block` / `macro`. Used both for
/// freshly loaded settings (defence in depth — the underlying model
/// also migrates in its `fromJson`) and for the segmented-button
/// `selected` value (which is keyed by the segment's `value`).
String _migrateInjectionTarget(String raw) {
  if (raw == 'summary_block') return 'hard_block';
  if (raw == 'summary_macro') return 'macro';
  return raw;
}

String _normalizeMemoryMode(String raw) {
  if (raw == 'deep') return 'deep';
  if (raw == 'legacy') return 'legacy';
  // `agentic` was removed in Phase 4 — migrate to `deep` (closest
  // backward-compatible retrieval depth).
  if (raw == 'agentic') return 'deep';
  return raw == 'balanced' ? 'balanced' : 'fast';
}

String _normalizeMemoryPackingMode(String raw) {
  if (raw == 'full' || raw == 'chunk_first') return raw;
  return 'hybrid';
}
