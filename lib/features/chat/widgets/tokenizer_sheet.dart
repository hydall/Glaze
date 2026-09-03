import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/context_calculator.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/llm/prompt_isolate.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../providers/prompt_build_providers.dart';
import '../../../core/models/api_config.dart';
import '../../../features/settings/api_list_provider.dart';
import '../../../features/settings/app_settings_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../chat_provider.dart';
import '../state/cached_token_breakdown.dart';
import '../state/token_breakdown_cache.dart';
import 'tokenizer_widgets.dart';

class TokenizerSheet extends ConsumerStatefulWidget {
  final String charId;

  /// When true, render only the body content (no SheetView chrome) for
  /// embedding inside the Prompt Inspector's tabbed shell.
  final bool embedded;

  const TokenizerSheet({
    super.key,
    required this.charId,
    this.embedded = false,
  });

  @override
  ConsumerState<TokenizerSheet> createState() => _TokenizerSheetState();
}

class _TokenizerSheetState extends ConsumerState<TokenizerSheet> {
  TokenBreakdown? _breakdown;
  int? _contextSize;
  bool _loading = false;
  int _visibleCount = 0;
  bool _showSettings = false;

  /// Slider positions while the sheet is open, null until the user drags one.
  ///
  /// The stored setting is the value until then. Reading it once in
  /// `initState` instead froze whatever was loaded at that moment — the
  /// defaults, when the sheet opened before settings arrived — and the next
  /// save wrote those defaults back over the stored ones.
  double? _hideOverride;
  double? _thresholdOverride;

  @override
  void initState() {
    super.initState();
    _loadOrCalculate();
  }

  AppSettings get _settings =>
      ref.watch(appSettingsProvider).value ?? const AppSettings();

  double get _hidePercent => _hideOverride ?? _settings.tokenizerHidePercent;

  double get _historyFillThreshold =>
      _thresholdOverride ?? _settings.tokenizerHistoryFillThreshold;

  void _loadOrCalculate() {
    final chatState = ref.read(chatProvider(widget.charId)).value;
    final session = chatState?.session;
    if (session == null) {
      _calculate();
      return;
    }

    final chatApi = _resolveApiConfig();
    if (chatApi == null) {
      _calculate();
      return;
    }

    final visibleCount = session.messages
        .where((m) => !m.isHidden && !m.isTyping)
        .length;
    final summaryContent = ref.read(
      cachedTokenBreakdownProvider(widget.charId),
    );
    final hash = TokenBreakdownCache.computeHash(
      charId: widget.charId,
      sessionId: session.id,
      messageCount: visibleCount,
      contextSize: chatApi.contextSize,
      maxTokens: chatApi.maxTokens,
      authorsNote: session.authorsNote?.content ?? '',
      summary: '',
    );

    final cached = TokenBreakdownCache.get(hash);
    if (cached != null) {
      _contextSize = chatApi.contextSize;
      _visibleCount = visibleCount;
      _breakdown = cached;
      return;
    }

    final riverpodCached = summaryContent;
    if (riverpodCached != null) {
      _contextSize = chatApi.contextSize;
      _visibleCount = visibleCount;
      _breakdown = riverpodCached;
      return;
    }

    _calculate();
  }

  ApiConfig? _resolveApiConfig() {
    try {
      return ref.read(activeApiConfigProvider);
    } catch (_) {
      return null;
    }
  }

  Future<void> _calculate() async {
    // Callers await a write first (hide, unhide), so the sheet can be gone by
    // the time we get here.
    if (!mounted) return;
    setState(() => _loading = true);

    try {
      final chatState = ref.read(chatProvider(widget.charId)).value;
      final session = chatState?.session;
      if (session == null) {
        setState(() => _loading = false);
        return;
      }

      // Same predicate `HistoryAssembler` uses, so the count matches what the
      // prompt actually carries — the typing placeholder is not a message.
      _visibleCount = session.messages
          .where((m) => !m.isHidden && !m.isTyping)
          .length;

      final builder = ref.read(promptPayloadBuilderProvider);
      final inputs = await builder.collectInputs(
        charId: widget.charId,
        session: session,
      );
      _contextSize = inputs.apiConfig.contextSize;

      final result = await buildFromInputsInIsolate(inputs);
      var breakdown = result.breakdown;

      final lastVectorTokens = ref.read(
        lastVectorLoreTokensProvider(widget.charId),
      );
      if (lastVectorTokens > 0 && breakdown.vectorLoreTokens == 0) {
        // The fast-path collectInputs skips vector search (it can take
        // seconds via the embedding endpoint), but vector entries were
        // counted on the last real generation. Reuse that count here so
        // the tokenizer/preview screen shows a "Vector Lorebook" row
        // instead of silently folding them into the lorebook reserve.
        final newSources = Map<String, int>.from(breakdown.sourceTokens)
          ..['vectorLore'] = lastVectorTokens;
        breakdown = TokenBreakdown(
          sourceTokens: newSources,
          macroTokens: breakdown.macroTokens,
          staticTotal: breakdown.staticTotal,
          historyBudget: breakdown.historyBudget,
          historyTokens: breakdown.historyTokens,
          totalTokens: breakdown.totalTokens + lastVectorTokens,
          cutoffIndex: breakdown.cutoffIndex,
          trimmedHistory: breakdown.trimmedHistory,
          lorebookReserveTokens: breakdown.lorebookReserveTokens,
          memoryTokens: breakdown.memoryTokens,
          vectorLoreTokens: lastVectorTokens,
          fixedTotal: breakdown.fixedTotal + lastVectorTokens,
          remaining: breakdown.remaining - lastVectorTokens,
        );
      }

      final hash = TokenBreakdownCache.computeHash(
        charId: widget.charId,
        sessionId: session.id,
        messageCount: _visibleCount,
        contextSize: inputs.apiConfig.contextSize,
        maxTokens: inputs.apiConfig.maxTokens,
        authorsNote: session.authorsNote?.content ?? '',
        summary: inputs.summaryContent ?? '',
      );
      TokenBreakdownCache.set(hash, breakdown);

      ref.read(cachedTokenBreakdownProvider(widget.charId).notifier).state =
          breakdown;

      if (mounted) setState(() => _breakdown = breakdown);
    } catch (e) {
      debugPrint('Tokenizer error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(chatProvider(widget.charId), (prev, next) {
      final prevSession = prev?.value?.session;
      final nextSession = next.value?.session;
      if (prevSession != nextSession && !_loading) {
        _calculate();
      }
    });

    final contextSize = _contextSize ?? 4096;
    final bd = _breakdown;
    final used = bd?.totalTokens ?? 0;
    final remaining = bd?.remaining ?? (contextSize - used);
    final usedPercent = contextSize > 0 ? (used / contextSize * 100) : 0.0;
    final historyFill = bd?.historyFillPercent ?? 0.0;
    final nearLimit = historyFill >= _historyFillThreshold;

    final body = _loading
        ? const Center(child: GlazeSpinner())
        : bd == null
        ? Center(
            child: Text(
              'label_no_data'.tr(),
              style: TextStyle(color: context.cs.onSurfaceVariant),
            ),
          )
        : _showSettings
        ? _buildSettings()
        : _buildMainView(
            bd,
            contextSize,
            used,
            remaining,
            usedPercent,
            historyFill,
            nearLimit,
          );

    if (widget.embedded) {
      // The Prompt Inspector injects the floating-header height as the body's
      // top inset. Offset the whole embedded column (toolbar included) by it,
      // then strip the inset from descendants so the scroll body — which also
      // reads padding.top — doesn't add the gap a second time.
      return Padding(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
        child: MediaQuery.removePadding(
          context: context,
          removeTop: true,
          child: Column(
            children: [
              TokenizerEmbeddedToolbar(
                showSettings: _showSettings,
                onToggleSettings: () =>
                    setState(() => _showSettings = !_showSettings),
                onRefresh: _loading ? null : _calculate,
              ),
              Expanded(child: body),
            ],
          ),
        ),
      );
    }

    return SheetView(
      title: _showSettings ? 'context_settings_title'.tr() : 'tab_context'.tr(),
      showBack: true,
      fitContent: true,
      onBack: () => _showSettings
          ? setState(() => _showSettings = false)
          : Navigator.of(context).maybePop(),
      actions: _showSettings
          ? []
          : [
              SheetViewAction(
                icon: const Icon(Icons.refresh, size: 20),
                tooltip: 'action_recalculate'.tr(),
                onPressed: _loading ? () {} : _calculate,
              ),
            ],
      body: body,
    );
  }

  Widget _buildMainView(
    TokenBreakdown bd,
    int contextSize,
    int used,
    int remaining,
    double usedPercent,
    double historyFill,
    bool nearLimit,
  ) {
    // The newest message always stays, so a chat with one visible message has
    // nothing to hide. `clamp(1, 0)` — the empty range that case used to
    // produce — throws, and took the whole Context tab down with it.
    final maxHide = _visibleCount > 1 ? _visibleCount - 1 : 0;
    final hideCount = maxHide == 0
        ? 0
        : (_visibleCount * _hidePercent / 100).ceil().clamp(1, maxHide);
    final messages =
        ref.watch(chatProvider(widget.charId)).value?.messages ??
        const <ChatMessage>[];
    final hiddenCount = messages.where((m) => m.isHidden).length;
    final historyTokens = bd.sourceTokens['history'] ?? 0;
    // Messages the history budget already cut are not in the prompt, so
    // hiding them frees nothing — only the ones past the cutoff count, and
    // `historyTokens` is spread over exactly those.
    final inPrompt = (_visibleCount - bd.cutoffIndex).clamp(0, _visibleCount);
    final freedCount = (hideCount - bd.cutoffIndex).clamp(0, hideCount);
    final hideTokens = inPrompt > 0
        ? ((historyTokens / inPrompt) * freedCount).round()
        : 0;

    return Builder(
      builder: (context) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(
          16,
        ).add(EdgeInsets.only(top: MediaQuery.paddingOf(context).top)),
        children: [
          HeroCard(
            used: used,
            contextSize: contextSize,
            remaining: remaining,
            historyFill: historyFill,
          ),
          const SizedBox(height: 24),
          TokenizerLayout(breakdown: bd, contextSize: contextSize),
          if (bd.cutoffIndex > 0) ...[
            const SizedBox(height: 12),
            CutoffWarning(cutoffCount: bd.cutoffIndex),
          ],
          // Nothing to suggest when the newest message is the only one left:
          // the banner's whole body is "hide N of them".
          if (nearLimit && hideCount > 0) ...[
            const SizedBox(height: 24),
            NearLimitWarning(hideCount: hideCount, hideTokens: hideTokens),
          ],
          const SizedBox(height: 24),
          // Glaze tiles, not Material buttons: the pair used to be a
          // `FilledButton` + a hand-styled `OutlinedButton` (white alphas and
          // all), which rendered as stock Material under every theme preset.
          Row(
            children: [
              Expanded(
                child: _ActionTile(
                  icon: Icons.visibility_off_outlined,
                  label: hideCount > 0
                      ? 'tokenizer_hide_top_n'.tr(args: ['$hideCount'])
                      : 'label_hide_top_messages'.tr(),
                  accent: true,
                  onTap: hideCount > 0
                      ? () => _confirmHide(context, hideCount)
                      : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ActionTile(
                  icon: Icons.tune_rounded,
                  label: 'title_settings'.tr(),
                  onTap: () => setState(() => _showSettings = true),
                ),
              ),
            ],
          ),
          if (hiddenCount > 0) ...[
            const SizedBox(height: 12),
            // Unhiding used to live in `TokenizerActionButtons`, a widget
            // nothing rendered — so the action was unreachable. It belongs
            // next to the one that hides.
            _ActionTile(
              icon: Icons.visibility_outlined,
              label: 'action_unhide_all_count'.tr(args: ['$hiddenCount']),
              onTap: () async {
                await ref
                    .read(chatProvider(widget.charId).notifier)
                    .unhideAllMessages();
                await _calculate();
              },
            ),
          ],
        ],
      ),
    );
  }

  void _saveSettings() {
    final settings = ref.read(appSettingsProvider).value ?? const AppSettings();
    ref
        .read(appSettingsProvider.notifier)
        .save(
          settings.copyWith(
            tokenizerHidePercent:
                _hideOverride ?? settings.tokenizerHidePercent,
            tokenizerHistoryFillThreshold:
                _thresholdOverride ?? settings.tokenizerHistoryFillThreshold,
          ),
        );
  }

  void _confirmHide(BuildContext context, int count) async {
    final confirmed = await GlazeBottomSheet.show<bool>(
      context,
      title: 'tokenizer_hide_messages_title'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.visibility_off_outlined,
        description: 'tokenizer_hide_confirm_desc'.tr(args: ['$count']),
      ),
      items: [
        BottomSheetItem(
          label: '${'action_hide_msg'.tr()} $count',
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
        ),
      ],
    );
    if (confirmed == true) {
      await ref
          .read(chatProvider(widget.charId).notifier)
          .hideTopMessages(count);
      await _calculate();
    }
  }

  Widget _buildSettings() {
    return Builder(
      // No horizontal padding: `MenuGroup` already supplies the 16px gutters,
      // and adding our own stacked them into a 32px inset.
      builder: (context) => ListView(
        shrinkWrap: true,
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 8,
          bottom: 16,
        ),
        children: [
          SettingsSlider(
            label: 'tokenizer_history_fill_threshold_label'.tr(),
            value: _historyFillThreshold,
            min: 1,
            max: 100,
            unit: '%',
            description: 'tokenizer_history_fill_threshold_desc'.tr(),
            onChanged: (v) {
              setState(() => _thresholdOverride = v);
              _saveSettings();
            },
          ),
          SettingsSlider(
            label: 'label_hide_top_messages'.tr(),
            value: _hidePercent,
            min: 1,
            max: 95,
            unit: '%',
            description: 'tokenizer_hide_percent_desc'.tr(),
            onChanged: (v) {
              setState(() => _hideOverride = v);
              _saveSettings();
            },
          ),
        ],
      ),
    );
  }
}

/// A tappable Glaze tile — the app's stand-in for a button (see `docs/UI_KIT`).
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final tint = accent ? context.cs.primary : context.cs.onSurface;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: GlassSurface(
        borderRadius: BorderRadius.circular(12),
        tint: tint.withValues(alpha: accent ? 0.18 : 0.06),
        border: Border.all(color: tint.withValues(alpha: 0.18)),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: accent ? context.cs.primary : context.cs.onSurface,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: accent ? context.cs.primary : context.cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
