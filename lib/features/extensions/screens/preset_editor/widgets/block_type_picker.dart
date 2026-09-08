import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../models/block_config.dart';
import 'section_label.dart';

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
    return Column(
      children: [
        SectionLabel('block_type_label'.tr()),
        SegmentedButton<BlockType>(
          segments: [
            ButtonSegment(
              value: BlockType.infoblock,
              label: Text('block_type_infoblock'.tr()),
              icon: const Icon(Icons.notes),
            ),
            ButtonSegment(
              value: BlockType.imageGen,
              label: Text('block_type_image'.tr()),
              icon: const Icon(Icons.image_outlined),
            ),
            ButtonSegment(
              value: BlockType.jsRunner,
              label: Text('block_type_js'.tr()),
              icon: const Icon(Icons.code),
            ),
            ButtonSegment(
              value: BlockType.interactive,
              label: Text('block_type_panel'.tr()),
              icon: const Icon(Icons.dashboard_customize_outlined),
            ),
          ],
          selected: {selected},
          onSelectionChanged: (s) => onChanged(s.first),
          style: ButtonStyle(visualDensity: VisualDensity.compact),
        ),
      ],
    );
  }
}
