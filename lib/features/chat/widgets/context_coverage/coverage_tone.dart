import 'package:flutter/material.dart';

import '../../../../core/llm/lorebook_coverage.dart';
import '../../../../shared/theme/app_colors.dart';

/// The one colour vocabulary the coverage surfaces speak.
///
/// Before this the sheet used `Colors.green` / `Colors.orange` / `Colors.cyan`
/// straight from the Material palette, which reads as neon on a dark preset and
/// as barely-there pastel on a light one. These are picked per brightness and
/// used by every coverage widget, so a green dot means the same thing on the
/// card under the header as it does in the Prompt Inspector.
class CoverageTone {
  const CoverageTone._({
    required this.injected,
    required this.cutOff,
    required this.idle,
    required this.constant,
    required this.vector,
    required this.recursion,
  });

  final Color injected;
  final Color cutOff;
  final Color idle;
  final Color constant;
  final Color vector;
  final Color recursion;

  static CoverageTone of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return CoverageTone._(
      injected: dark ? const Color(0xFF4ADE80) : const Color(0xFF16A34A),
      cutOff: dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309),
      idle: context.cs.onSurfaceVariant,
      constant: dark ? const Color(0xFFC084FC) : const Color(0xFF7C3AED),
      vector: dark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
      recursion: dark ? const Color(0xFF22D3EE) : const Color(0xFF0E7490),
    );
  }

  /// The colour that carries an entry's state at a glance.
  Color forEntry(CoverageEntry entry) {
    if (entry.cutOff != null) return cutOff;
    if (!entry.activated) return idle;
    return entry.constant ? constant : injected;
  }
}
