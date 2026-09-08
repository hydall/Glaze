import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../models/block_config.dart';
import 'section_label.dart';

class BlockTriggerPicker extends StatelessWidget {
  const BlockTriggerPicker({
    required this.selected,
    required this.onChanged,
    super.key,
  });

  final BlockTrigger selected;
  final ValueChanged<BlockTrigger> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SectionLabel('block_trigger_label'.tr()),
        SegmentedButton<BlockTrigger>(
          segments: [
            ButtonSegment(
              value: BlockTrigger.afterUser,
              label: Text('block_trigger_after_user'.tr()),
            ),
            ButtonSegment(
              value: BlockTrigger.afterAssistant,
              label: Text('block_trigger_after_assistant'.tr()),
            ),
            ButtonSegment(
              value: BlockTrigger.periodic,
              label: Text('block_trigger_periodic'.tr()),
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
