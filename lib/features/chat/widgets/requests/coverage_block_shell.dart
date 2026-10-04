import 'package:flutter/material.dart';

import '../../../../shared/theme/app_colors.dart';
import 'inspector_surface.dart';

/// The collapsed line a coverage block shows inside a request, and the body it
/// opens into.
///
/// Both coverage blocks wear it — the one on a captured request (what that turn
/// carried) and the one on the next request (what would fire right now) — so
/// the two read as the same thing asked in two tenses.
///
/// [body] is a builder, not a widget: the lorebook half runs a scan and the
/// memory half reads a turn's diagnostics, and neither should happen for a
/// block nobody opened.
class CoverageBlockShell extends StatefulWidget {
  const CoverageBlockShell({
    super.key,
    required this.title,
    required this.subtitle,
    required this.body,
    this.icon = Icons.layers_outlined,
    this.enabled = true,
    this.initiallyExpanded = false,
  });

  final String title;
  final String subtitle;
  final WidgetBuilder body;
  final IconData icon;

  /// False when there is nothing to open — a background job's request recorded
  /// no coverage of its own.
  final bool enabled;

  /// Open on mount. The context card under the chat header deep-links into the
  /// next request *at* its coverage, so the block it lands on is already
  /// unfolded.
  final bool initiallyExpanded;

  @override
  State<CoverageBlockShell> createState() => _CoverageBlockShellState();
}

class _CoverageBlockShellState extends State<CoverageBlockShell> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final expanded = _expanded && widget.enabled;

    return InspectorPlaque(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: widget.enabled
                ? () => setState(() => _expanded = !_expanded)
                : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Row(
                children: [
                  Icon(widget.icon, size: 18, color: cs.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: cs.onSurface,
                          ),
                        ),
                        Text(
                          widget.subtitle,
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.enabled)
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 20,
                      color: cs.onSurfaceVariant,
                    ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: widget.body(context),
            ),
        ],
      ),
    );
  }
}
