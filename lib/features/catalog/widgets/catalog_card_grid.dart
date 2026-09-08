import 'package:flutter/material.dart';

import '../catalog_models.dart';
import 'catalog_card.dart';

/// Responsive card grid sliver shared by the catalog tab and the catalog search
/// results, so both render identical cards.
///
/// Uses an [IntrinsicHeight] row layout rather than a [GridView] so cards with
/// variable content heights align row-by-row (same behaviour as the original
/// inline grid in `catalog_grid.dart`).
class CatalogCardGridSliver extends StatelessWidget {
  final List<CatalogItem> items;
  final void Function(CatalogItem item) onTap;
  final EdgeInsets padding;

  const CatalogCardGridSliver({
    super.key,
    required this.items,
    required this.onTap,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 16),
  });

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: padding,
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final crossAxisCount = (constraints.crossAxisExtent / 212)
              .ceil()
              .clamp(1, 10);
          final rowCount = (items.length / crossAxisCount).ceil();

          return SliverList(
            delegate: SliverChildBuilderDelegate((_, i) {
              final startIndex = i * crossAxisCount;
              final rowItems = items
                  .skip(startIndex)
                  .take(crossAxisCount)
                  .toList();

              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: List.generate(crossAxisCount, (colIndex) {
                      final isLast = colIndex == crossAxisCount - 1;
                      return Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(right: isLast ? 0 : 12),
                          child: colIndex < rowItems.length
                              ? CatalogCard(
                                  item: rowItems[colIndex],
                                  onTap: () => onTap(rowItems[colIndex]),
                                )
                              : const SizedBox.shrink(),
                        ),
                      );
                    }),
                  ),
                ),
              );
            }, childCount: rowCount),
          );
        },
      ),
    );
  }
}
