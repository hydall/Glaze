import 'package:flutter/rendering.dart';

/// Grid delegate that fits as many fixed-ish columns as the width allows.
///
/// [SliverGridDelegateWithMaxCrossAxisExtent] would do the job, but it keeps
/// the aspect ratio and lets cells shrink below a comfortable size; this one
/// mirrors the CSS the Vue app used — `repeat(auto-fill, minmax(<min>, 1fr))` —
/// by choosing the column count from [minCellExtent] and then stretching the
/// cells to fill the row exactly.
class ResponsiveGridDelegate extends SliverGridDelegateWithFixedCrossAxisCount {
  const ResponsiveGridDelegate._({
    required super.crossAxisCount,
    required super.childAspectRatio,
    required super.mainAxisSpacing,
    required super.crossAxisSpacing,
  });

  /// Builds a delegate for [availableWidth], never dropping below [minColumns].
  factory ResponsiveGridDelegate({
    required double availableWidth,
    required double minCellExtent,
    required double childAspectRatio,
    double mainAxisSpacing = 10,
    double crossAxisSpacing = 10,
    int minColumns = 2,
  }) {
    final usable = availableWidth + crossAxisSpacing;
    final columns = (usable / (minCellExtent + crossAxisSpacing)).floor().clamp(
      minColumns,
      12,
    );
    return ResponsiveGridDelegate._(
      crossAxisCount: columns,
      childAspectRatio: childAspectRatio,
      mainAxisSpacing: mainAxisSpacing,
      crossAxisSpacing: crossAxisSpacing,
    );
  }
}
