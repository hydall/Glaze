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
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../settings/api_settings_screen.dart';
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

  /// Slider positions while the sheet is open, null until the user drags one.
  ///
  /// The stored setting is the value until then. Reading it once in
  /// `initState` instead froze whatever was loaded at that moment — the
  /// defaults, when the sheet opened before settings arrived — and the next
  /// save wrote those defaults back over the stored ones.

  @override
  void initState() {
    super.initState();
    _loadOrCalculate();
  }

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
      trimSignature: chatApi.contextBudgetSignature,
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

    // Editing the connection's window or trim mode changes which messages
    // survive, so the numbers on screen are wrong the moment it is saved. The
    // cached breakdown is keyed on the same signature, so drop it too.
    ref.listen(
      activeApiConfigProvider.select(
        (config) => config?.contextBudgetSignature ?? '',
      ),
      (previous, next) {
        if (previous == null || previous == next) return;
        TokenBreakdownCache.invalidate();
        ref.read(cachedTokenBreakdownProvider(widget.charId).notifier).state =
            null;
        _calculate();
      },
    );

    final contextSize = _contextSize ?? 4096;
    final bd = _breakdown;
    final used = bd?.totalTokens ?? 0;
    final remaining = bd?.remaining ?? (contextSize - used);
    final usedPercent = contextSize > 0 ? (used / contextSize * 100) : 0.0;
    final historyFill = bd?.historyFillPercent ?? 0.0;

    final body = _loading
        ? const Center(child: GlazeSpinner())
        : bd == null
        ? Center(
            child: Text(
              'label_no_data'.tr(),
              style: TextStyle(color: context.cs.onSurfaceVariant),
            ),
          )
        : _buildMainView(
            bd,
            contextSize,
            used,
            remaining,
            usedPercent,
            historyFill,
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
          child: body,
        ),
      );
    }

    return SheetView(
      title: 'tab_context'.tr(),
      showBack: true,
      fitContent: true,
      onBack: () => Navigator.of(context).maybePop(),
      actions: [
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
  ) {
    final messages =
        ref.watch(chatProvider(widget.charId)).value?.messages ??
        const <ChatMessage>[];
    final hiddenCount = messages.where((m) => m.isHidden).length;

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
            // The gear leads to the connection's Context section: the window
            // and the trim mode are what decide this number, and neither is
            // adjustable from here.
            CutoffWarning(
              cutoffCount: bd.cutoffIndex,
              onOpenSettings: () => showApiSettingsSheet(
                context,
                focusSection: ApiSettingsSection.context,
              ),
            ),
          ],
          if (hiddenCount > 0) ...[
            const SizedBox(height: 24),
            // Hiding is done by selecting messages in the chat; this is the
            // only bulk way back, so it stays.
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
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final tint = context.cs.onSurface;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: GlassSurface(
        borderRadius: BorderRadius.circular(12),
        tint: tint.withValues(alpha: 0.06),
        border: Border.all(color: tint.withValues(alpha: 0.18)),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: context.cs.onSurface),
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
                    color: context.cs.onSurface,
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
