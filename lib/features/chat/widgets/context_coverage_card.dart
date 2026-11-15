import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/lorebook_coverage.dart';
import '../../../core/llm/tokenizer.dart';
import '../../../shared/theme/app_colors.dart';
import '../chrome/chat_chrome_channel.dart';
import '../chrome/chrome_json.dart';
import '../state/lorebook_coverage_provider.dart';
import '../state/memory_activity_provider.dart';
import 'context_coverage/coverage_entry_tile.dart';
import 'context_coverage/coverage_reasons.dart';
import 'context_coverage/coverage_summary.dart';
import 'context_coverage/coverage_tone.dart';
import 'context_coverage/memory_candidate_view.dart';
import 'memory_graph_panel.dart';
import 'prompt_inspector_sheet.dart';

/// Breathing room between the chat header and the card.
///
/// The card used to sit flush against the header's bottom edge, which read as
/// one two-storey header rather than a panel the header happens to sit above —
/// and left its rounded top corners with nothing to round against.
const double kContextCardHeaderGap = 8.0;

/// The panel under the chat header: what the next prompt is actually
/// carrying from the two retrieval layers.
///
/// It used to be the memory-only activity card, which answered half the
/// question — the other half (which lorebook entries fired, and which were cut)
/// was three taps away in the Prompt Inspector. Both layers answer "why is this
/// in my prompt?", so they share one surface, one collapsed line and one
/// expanded body with a tab per layer.
///
/// Collapsed it is a single row of counters. That is the state it is in almost
/// always, and it is what the header gap is sized for.
///
/// The chat page draws it (`assets/chat_webview/chrome/cards.js`), in its own
/// stacking order under the header and the composer; it used to be a Flutter
/// widget laid over the WebView, above everything the page draws. This widget
/// keeps everything but the drawing: it resolves what the card says into the
/// `coverage` chrome section, keeps the picked tab and filter, and answers the
/// card's taps. It lays nothing out itself. Which rows of a list are opened is
/// the page's own business.
class ContextCoverageCard extends ConsumerStatefulWidget {
  const ContextCoverageCard({
    super.key,
    required this.channel,
    required this.charId,
    required this.expanded,
    required this.onToggle,
    this.hidden = false,
    this.memory,
    this.sessionId,
  });

  final ChatChromeChannel channel;
  final String charId;
  final bool expanded;
  final VoidCallback onToggle;

  /// The header is hidden on scroll; the card slides away with it.
  final bool hidden;

  /// Null when memory books are off or the session has no memory run yet — the
  /// card then shows the lorebook layer alone, with no tab strip.
  final MemoryActivityState? memory;
  final String? sessionId;

  @override
  ConsumerState<ContextCoverageCard> createState() =>
      _ContextCoverageCardState();
}

enum _Layer { memory, lorebook }

class _ContextCoverageCardState extends ConsumerState<ContextCoverageCard> {
  _Layer _layer = _Layer.memory;
  CoverageFilter _filter = CoverageFilter.injected;
  List<_Layer> _layers = const [_Layer.lorebook];
  VoidCallback? _removeIntents;
  late ChatChromeChannel _channel;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant ContextCoverageCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) {
      _unbind();
      _bind();
    }
  }

  @override
  void dispose() {
    _unbind();
    super.dispose();
  }

  void _bind() {
    _channel = widget.channel;
    _removeIntents = _channel.onAll({
      'coverageToggle': (_) => widget.onToggle(),
      'coverageTab': (data) {
        final i = data['i'];
        if (i is int && i >= 0 && i < _layers.length && mounted) {
          setState(() => _layer = _layers[i]);
        }
      },
      'coverageFilter': (data) {
        final i = data['i'];
        if (i is int && i >= 0 && i < CoverageFilter.values.length && mounted) {
          setState(() => _filter = CoverageFilter.values[i]);
        }
      },
      'coverageAction': (data) => _onAction(data['id']),
    });
  }

  void _unbind() {
    _removeIntents?.call();
    _removeIntents = null;
    _channel.set('coverage', null);
  }

  _Layer get _active => _layers.contains(_layer) ? _layer : _layers.first;

  void _onAction(Object? id) {
    if (!mounted) return;
    switch (id) {
      case 'refresh':
        ref.invalidate(lorebookCoverageProvider(widget.charId));
      case 'inspector':
        showPromptInspectorSheet(
          context,
          widget.charId,
          initialTabId: _active == _Layer.lorebook
              ? PromptInspectorSheet.coverageTabId
              : PromptInspectorSheet.contextTabId,
        );
      case 'graph':
        final sessionId = widget.sessionId;
        if (sessionId == null || sessionId.isEmpty) return;
        showDialog<void>(
          context: context,
          builder: (_) => MemoryGraphPanel(sessionId: sessionId),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final tone = CoverageTone.of(context);
    final memory = widget.memory;
    final summary = memory == null ? null : MemoryActivitySummary.of(memory);
    final coverageAsync = ref.watch(lorebookCoverageProvider(widget.charId));
    final coverage = coverageAsync.value;

    _layers = [if (memory != null) _Layer.memory, _Layer.lorebook];
    final active = _active;

    Map<String, Object?> pill(
      IconData icon,
      int value,
      int total,
      Color color,
    ) => {
      'icon': chromeIcon(icon),
      'value': '$value',
      'total': '$total',
      'color': chromeColor(color),
    };

    _channel.set('coverage', {
      'hidden': widget.hidden,
      'expanded': widget.expanded,
      'title': 'coverage_card_title'.tr(),
      'pills': [
        if (summary != null)
          pill(
            Icons.psychology_alt_outlined,
            summary.selectedCount,
            summary.totalCandidates,
            summary.macroMissing ? tone.cutOff : cs.onSurfaceVariant,
          ),
        if (coverage != null)
          pill(
            Icons.menu_book_outlined,
            coverage.injectedCount,
            coverage.totalCandidates,
            coverage.cutOffCount > 0 ? tone.cutOff : cs.onSurfaceVariant,
          ),
      ],
      // The rest is only drawn while the card is open.
      if (widget.expanded) ...{
        'tabs': [
          if (_layers.length > 1)
            for (final layer in _layers)
              {'label': _label(layer), 'icon': chromeIcon(_icon(layer))},
        ],
        'tab': _layers.indexOf(active),
        'label': _label(active),
        'actions': [
          if (active == _Layer.lorebook)
            {
              'id': 'refresh',
              'icon': chromeIcon(Icons.refresh_rounded),
              'tip': 'action_refresh'.tr(),
              'size': 18,
            },
          {
            'id': 'inspector',
            'icon': chromeIcon(Icons.open_in_full_rounded),
            'tip': 'coverage_open_inspector'.tr(),
            'size': 16,
          },
        ],
        'body': active == _Layer.memory && memory != null
            ? _memoryBody(context, memory, summary!)
            : _lorebookBody(context, tone, coverageAsync),
      },
    });
    return const SizedBox.shrink();
  }

  Map<String, Object?> _memoryBody(
    BuildContext context,
    MemoryActivityState memory,
    MemoryActivitySummary summary,
  ) {
    final cs = context.cs;
    final diagnostics = memory.diagnostics;
    final sessionId = widget.sessionId;
    List<num> c(Color color) => chromeColor(color);
    return {
      'kind': 'memory',
      // A new run: the page closes the rows it had open.
      'key': memory.messageId,
      'warning': summary.macroMissing
          ? 'memory_macro_missing_warning'.tr()
          : null,
      'warnColor': c(Colors.orangeAccent),
      'chips': MemoryCandidateView.chipsOf(summary, diagnostics),
      'graph': sessionId != null && sessionId.isNotEmpty
          ? {
              'icon': chromeIcon(Icons.account_tree_outlined),
              'tip': 'memory_graph_title'.tr(),
              'size': 18,
            }
          : null,
      'rows': [
        for (final view in MemoryCandidateView.listOf(diagnostics))
          _memoryRow(cs, view),
      ],
    };
  }

  Map<String, Object?> _memoryRow(ColorScheme cs, MemoryCandidateView view) {
    final verdict = view.selected ? Colors.greenAccent : Colors.orangeAccent;
    return {
      'k': view.entryId,
      'lead': {
        'icon': chromeIcon(
          view.selected ? Icons.check_circle_outline : Icons.cancel_outlined,
        ),
        'color': chromeColor(verdict),
      },
      'title': view.label,
      'sub': [
        if (view.shortReason != null)
          {
            't': view.shortReason,
            'c': chromeColor(Colors.orangeAccent),
            'bb': true,
          },
      ],
      'trail': view.trailing,
      'details': [
        for (final line in view.details)
          {
            't': line.text,
            'c': chromeColor(switch (line.tone) {
              MemoryDetailTone.verdict => verdict,
              MemoryDetailTone.normal => cs.onSurfaceVariant,
              MemoryDetailTone.dim => cs.onSurfaceVariant.withValues(
                alpha: 0.85,
              ),
            }),
            'b': line.tone == MemoryDetailTone.verdict,
          },
      ],
    };
  }

  Map<String, Object?> _lorebookBody(
    BuildContext context,
    CoverageTone tone,
    AsyncValue<CoverageResult> coverage,
  ) {
    final cs = context.cs;
    return coverage.when(
      loading: () => {'kind': 'loading'},
      error: (e, _) => {
        'kind': 'error',
        'text': '${'title_error'.tr()}: $e',
        'color': chromeColor(cs.error),
      },
      data: (result) {
        if (result.totalCandidates == 0) {
          return {'kind': 'empty', 'text': 'coverage_no_active_books'.tr()};
        }
        Map<String, Object?> stat(int value, String label, Color color) => {
          'value': '$value',
          'label': label,
          'color': chromeColor(color),
        };
        final entries = filterCoverageEntries(result.entries, _filter);
        return {
          'kind': 'lorebook',
          'stats': [
            stat(result.injectedCount, 'label_active'.tr(), tone.injected),
            if (result.cutOffCount > 0)
              stat(result.cutOffCount, 'label_cut_off'.tr(), tone.cutOff),
            stat(result.inactiveCount, 'label_inactive'.tr(), tone.idle),
            stat(
              result.totalCandidates,
              'label_total'.tr(),
              cs.onSurface.withValues(alpha: 0.7),
            ),
          ],
          'filters': [
            for (final f in CoverageFilter.values) coverageFilterLabel(f),
          ],
          'filter': CoverageFilter.values.indexOf(_filter),
          'empty': 'lorebook_no_entries_category'.tr(),
          'rows': [for (final e in entries) _entryRow(cs, tone, e)],
        };
      },
    );
  }

  Map<String, Object?> _entryRow(
    ColorScheme cs,
    CoverageTone tone,
    CoverageEntry e,
  ) {
    final status = tone.forEntry(e);
    final short = lorebookStatusShortLabel(e);
    final subtitle = coverageEntrySubtitle(e);
    final reasons = lorebookCoverageReasons(e);
    List<Map<String, Object?>> badges(List<String> keys, Color color) => [
      for (final key in keys) {'t': key, 'c': chromeColor(color)},
    ];
    return {
      'k': '${e.lorebookId}/${e.id}',
      'rail': chromeColor(status),
      'bg': chromeColor(
        e.activated
            ? status.withValues(alpha: 0.06)
            : cs.onSurface.withValues(alpha: 0.03),
      ),
      'title': e.comment.isNotEmpty ? e.comment : e.id,
      'titleColor': chromeColor(
        e.activated ? cs.onSurface : cs.onSurfaceVariant,
      ),
      'trail': 'coverage_tokens_short'.tr(
        args: ['${estimateTokens(e.content)}'],
      ),
      'sub': [
        if (short != null) {'t': short, 'c': chromeColor(status), 'bb': true},
        if (subtitle.isNotEmpty)
          {
            't': subtitle,
            'c': chromeColor(cs.onSurfaceVariant.withValues(alpha: 0.85)),
          },
      ],
      'details': [
        for (final (index, line) in reasons.indexed)
          {
            't': line,
            'c': chromeColor(index == 0 ? status : cs.onSurfaceVariant),
            'b': index == 0,
          },
      ],
      'badges': [
        if (e.matchedKeys.isNotEmpty) badges(e.matchedKeys, tone.injected),
        if (e.matchedSecondaryKeys.isNotEmpty)
          badges(e.matchedSecondaryKeys, tone.vector),
      ],
    };
  }

  String _label(_Layer layer) => switch (layer) {
    _Layer.memory => 'coverage_tab_memory'.tr(),
    _Layer.lorebook => 'coverage_tab_lorebook'.tr(),
  };

  IconData _icon(_Layer layer) => switch (layer) {
    _Layer.memory => Icons.psychology_alt_outlined,
    _Layer.lorebook => Icons.menu_book_outlined,
  };
}
