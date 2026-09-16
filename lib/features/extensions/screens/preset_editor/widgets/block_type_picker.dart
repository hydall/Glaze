import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../../shared/widgets/menu_group.dart';
import '../../../models/block_config.dart';
import '../sections/upstream_block_sections.dart';

/// Human-readable name of a block type.
String blockTypeLabel(BlockType type) => switch (type) {
  BlockType.infoblock => 'block_type_infoblock'.tr(),
  BlockType.imageGen => 'block_type_image'.tr(),
  BlockType.jsRunner => 'block_type_js'.tr(),
  BlockType.interactive => 'block_type_interactive'.tr(),
  BlockType.rewrite => 'block_type_rewrite'.tr(),
  BlockType.accumulation => 'block_type_accumulation'.tr(),
};

/// Type row for the block editor.
///
/// This used to be a segmented control, which fitted four types across the
/// width and no more. With the original extension's rewrite and accumulation
/// types there are six, so the choice moved into a picker sheet, where each
/// option also has room for a name rather than an icon.
class BlockTypePicker extends StatelessWidget {
  const BlockTypePicker({
    required this.selected,
    required this.onChanged,
    super.key,
  });

  final BlockType selected;
  final ValueChanged<BlockType> onChanged;

  @override
  Widget build(BuildContext context) {
    return MenuSelectorItem(
      label: 'block_type_label'.tr(),
      currentValue: blockTypeLabel(selected),
      description: selected.isRunnable ? null : 'extblocks_not_executed'.tr(),
      onTap: () => pickBlockOption<BlockType>(
        context: context,
        title: 'block_type_label'.tr(),
        options: BlockType.values,
        current: selected,
        labelOf: blockTypeLabel,
        onPicked: onChanged,
      ),
    );
  }
}
