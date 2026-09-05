import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glaze_filter_chip_bar.dart';
import 'inspector_message.dart';
import 'inspector_surface.dart';

/// Budget accents. No token covers "how full is the context window", so the
/// three states are explicit constants rather than Material's palette
/// (`docs/UI_KIT.md` § Colours).
const Color _budgetOk = Color(0xFF4CAF7D);
const Color _budgetWarn = Color(0xFFE0A030);
const Color _budgetDanger = Color(0xFFE05A5A);

/// One parameter of a request, as a labelled tile in the parameter grid.
class InspectorParam {
  const InspectorParam({required this.label, required this.value});

  final String label;
  final String value;
}

/// Which slice of a request's messages the list is showing.
enum InspectorMessageFilter { all, system, lorebook, history, depth }

/// The body of one request, whichever request it is.
///
/// This is the shape the Request Preview has always had — budget bar,
/// parameters, then the messages behind a filter bar — extracted so a *captured*
/// request wears it too. Before, a past request was a different screen from the
/// next one, which made two answers to the same question look like two
/// features.
///
/// [coverage] rides between the parameters and the messages: coverage is a
/// property of a request (which lorebook entries and memories it carried), so
/// it belongs inside the request rather than in a list of its own.
class RequestBodyView extends StatefulWidget {
  const RequestBodyView({
    super.key,
    required this.tokens,
    required this.contextSize,
    required this.paramsTitle,
    required this.params,
    required this.messages,
    this.coverage,
    this.footer,
    this.renderMarkdown = true,
    this.topInset = 0,
  });

  /// Prompt size and the window it has to fit into. A [contextSize] of 0 (a
  /// captured request whose connection is gone) drops the budget bar rather
  /// than drawing a meter against an unknown maximum.
  final int tokens;
  final int contextSize;

  /// Protocol name, or a generic "Parameters" when it is not known.
  final String paramsTitle;
  final List<InspectorParam> params;
  final List<InspectorMessage> messages;

  /// The coverage block for this request, between parameters and messages.
  final Widget? coverage;

  /// Trailing note under the list — a capture says there when it was truncated.
  final Widget? footer;

  final bool renderMarkdown;

  /// The inspector's floating-header height, prepended as a leading spacer.
  final double topInset;

  @override
  State<RequestBodyView> createState() => _RequestBodyViewState();
}

class _RequestBodyViewState extends State<RequestBodyView> {
  InspectorMessageFilter _filter = InspectorMessageFilter.all;

  @override
  Widget build(BuildContext context) {
    final filters = _availableFilters();
    final active = filters.contains(_filter)
        ? _filter
        : InspectorMessageFilter.all;
    final rows = _filtered(active);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: SizedBox(height: widget.topInset)),
        if (widget.contextSize > 0 || widget.tokens > 0)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            sliver: SliverToBoxAdapter(
              child: _BudgetPlaque(
                tokens: widget.tokens,
                contextSize: widget.contextSize,
                messageCount: widget.messages.length,
              ),
            ),
          ),
        if (widget.params.isNotEmpty) ...[
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverToBoxAdapter(
              child: InspectorSectionTitle(widget.paramsTitle),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverToBoxAdapter(
              child: _ParamsGrid(params: widget.params),
            ),
          ),
        ],
        if (widget.coverage != null)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
            sliver: SliverToBoxAdapter(child: widget.coverage!),
          ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          sliver: SliverToBoxAdapter(
            child: InspectorSectionTitle(
              'label_messages_count'.tr(args: ['${widget.messages.length}']),
            ),
          ),
        ),
        if (filters.length > 1)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GlazeFilterChipBar<InspectorMessageFilter>(
                current: active,
                options: filters,
                labelBuilder: _filterLabel,
                onSelected: (f) => setState(() => _filter = f),
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => InspectorMessageCard(
                index: i,
                message: rows[i],
                renderMarkdown: widget.renderMarkdown,
              ),
              childCount: rows.length,
            ),
          ),
        ),
        if (widget.footer != null)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            sliver: SliverToBoxAdapter(child: widget.footer!),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  /// Only the slices this request actually has. The built prompt knows which
  /// block every message came from and fills all five; a captured request knows
  /// role alone, and a chip bar of empty filters would promise a breakdown the
  /// record cannot give.
  ///
  /// One pass, not one per filter: a long prompt is a couple of hundred
  /// messages and this runs on every rebuild of the list.
  List<InspectorMessageFilter> _availableFilters() {
    var system = false, lorebook = false, history = false, depth = false;
    for (final message in widget.messages) {
      system |= message.isPlainSystem;
      lorebook |= message.isLorebook;
      history |= message.isHistory;
      depth |= message.isDepth;
    }
    return [
      InspectorMessageFilter.all,
      if (system) InspectorMessageFilter.system,
      if (lorebook) InspectorMessageFilter.lorebook,
      if (history) InspectorMessageFilter.history,
      if (depth) InspectorMessageFilter.depth,
    ];
  }

  /// Section filters read the post-processed message: a merged row carries the
  /// union of its sources' flags, so it still shows up under `history` or
  /// `lorebook` when one of the blocks folded into it was of that kind.
  List<InspectorMessage> _filtered(InspectorMessageFilter filter) =>
      switch (filter) {
        InspectorMessageFilter.all => widget.messages,
        InspectorMessageFilter.system =>
          widget.messages.where((m) => m.isPlainSystem).toList(),
        InspectorMessageFilter.lorebook =>
          widget.messages.where((m) => m.isLorebook).toList(),
        InspectorMessageFilter.history =>
          widget.messages.where((m) => m.isHistory).toList(),
        InspectorMessageFilter.depth =>
          widget.messages.where((m) => m.isDepth).toList(),
      };

  static String _filterLabel(InspectorMessageFilter filter) => switch (filter) {
    InspectorMessageFilter.all => 'filter_all'.tr(),
    InspectorMessageFilter.system => 'role_system'.tr(),
    InspectorMessageFilter.lorebook => 'filter_lorebook'.tr(),
    InspectorMessageFilter.history => 'filter_history'.tr(),
    InspectorMessageFilter.depth => 'label_depth'.tr(),
  };
}

/// How much of the context window this request spends.
class _BudgetPlaque extends StatelessWidget {
  const _BudgetPlaque({
    required this.tokens,
    required this.contextSize,
    required this.messageCount,
  });

  final int tokens;
  final int contextSize;
  final int messageCount;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final pct = contextSize > 0
        ? (tokens / contextSize * 100).clamp(0.0, 100.0)
        : 0.0;
    final accent = pct > 90
        ? _budgetDanger
        : pct > 75
        ? _budgetWarn
        : _budgetOk;

    return InspectorPlaque(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      accent: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$tokens',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: accent,
                ),
              ),
              if (contextSize > 0)
                Text(
                  ' / $contextSize ${'label_tokens'.tr()}',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                )
              else
                Text(
                  ' ${'label_tokens'.tr()}',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                ),
              const Spacer(),
              if (contextSize > 0) ...[
                Text(
                  '${pct.toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: accent,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                '$messageCount ${'requests_messages_short'.tr()}',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          if (contextSize > 0) ...[
            const SizedBox(height: 8),
            // Two boxes rather than a LinearProgressIndicator: the meter is
            // static, and the Material one drags in its own theming.
            Container(
              height: 6,
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: (pct / 100).clamp(0.0, 1.0),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The request's parameters, two tiles per row.
class _ParamsGrid extends StatelessWidget {
  const _ParamsGrid({required this.params});

  final List<InspectorParam> params;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = (constraints.maxWidth - 8) / 2;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final param in params)
              SizedBox(
                width: itemWidth,
                child: _ParamTile(param: param),
              ),
          ],
        );
      },
    );
  }
}

class _ParamTile extends StatelessWidget {
  const _ParamTile({required this.param});

  final InspectorParam param;

  @override
  Widget build(BuildContext context) {
    return InspectorPlaque(
      padding: const EdgeInsets.all(10),
      radius: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            param.label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 0.5,
              color: context.cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            param.value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: context.cs.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
