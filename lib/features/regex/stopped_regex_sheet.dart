import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../core/models/preset.dart';
import '../../core/navigation/router.dart' show rootNavigatorKey;
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_sheet.dart';
import 'regex_sheet.dart';

bool _showing = false;

/// Tells the user which display regexes were stopped for hanging on a message
/// (see `DisplayRegexWorker`) and offers the regex settings to fix them.
///
/// Raised from the chat bridge, which has no context of its own, so it shows
/// on the root navigator. One sheet at a time: a second batch that stops
/// another script while this one is up is not stacked over it.
Future<void> showStoppedRegexSheet(List<PresetRegex> scripts) async {
  if (scripts.isEmpty || _showing) return;
  final context = rootNavigatorKey.currentContext;
  if (context == null || !context.mounted) return;

  void close(BuildContext sheet) =>
      Navigator.of(sheet, rootNavigator: true).pop();
  final names = scripts.map((s) => '«${s.name.trim()}»').join(', ');

  _showing = true;
  try {
    await GlazeBottomSheet.show<void>(
      context,
      title: 'regex_stopped_title'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.timer_off_outlined,
        description: 'regex_stopped_body'.tr(args: [names]),
        buttonText: 'regex_stopped_open'.tr(),
        buttonIcon: Icons.tune,
        onButtonTap: () {
          close(context);
          showGlazeSheet<void>(
            context: context,
            useRootNavigator: true,
            backgroundColor: Colors.transparent,
            barrierColor: Colors.black54,
            isScrollControlled: true,
            builder: (_) => const RegexSheet(),
          );
        },
      ),
      items: [
        BottomSheetItem(
          label: 'regex_stopped_dismiss'.tr(),
          centered: true,
          onTap: () => close(context),
        ),
      ],
    );
  } finally {
    _showing = false;
  }
}
