import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/sheet_view.dart';
import 'lorebook_build_settings.dart';
import '../../../shared/widgets/glaze_sheet.dart';

/// Settings for the lorebook build, opened from the gear in the lorebook
/// capture sheet's header.
///
/// Everything that decides *how* a lorebook is rebuilt into entries lives here:
/// the connection and model the build runs on, and the system prompts it is
/// given. Keeping them one tap from the flow means a failed build can be
/// corrected where it failed. The JanitorAI account and the extraction source
/// are content-provider settings and stay on that screen.
Future<void> showJanitorExtractionSettingsSheet(BuildContext context) {
  return showGlazeSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (_) => const JanitorExtractionSettingsSheet(),
  );
}

class JanitorExtractionSettingsSheet extends StatelessWidget {
  const JanitorExtractionSettingsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return SheetView(
      title: 'catalog_extraction_settings_title'.tr(),
      startExpanded: true,
      body: Builder(
        builder: (inner) => ListView(
          padding: EdgeInsets.only(
            top: MediaQuery.paddingOf(inner).top + 12,
            bottom: MediaQuery.paddingOf(inner).bottom + 24,
          ),
          children: const [LorebookBuildLlmGroup(), LorebookBuildPromptsGroup()],
        ),
      ),
    );
  }
}
