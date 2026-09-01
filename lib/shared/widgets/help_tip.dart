import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/glossary/glossary_sheet.dart';
import '../../features/settings/app_settings_provider.dart';
import '../shell/desktop/desktop_glossary_popup.dart';
import '../shell/desktop/desktop_layout_provider.dart';

/// Small inline help button — opens the glossary at a specific term.
///
/// On desktop that is the floating glossary window, which outlives the sheet
/// the tip was tapped in and stays on top of it; elsewhere it is the usual
/// modal [GlossarySheet]. Hidden globally when `hideTooltips` is on in app
/// settings.
class HelpTip extends ConsumerWidget {
  final String term;
  final double size;
  final EdgeInsetsGeometry padding;

  const HelpTip({
    super.key,
    required this.term,
    this.size = 16,
    this.padding = const EdgeInsets.symmetric(horizontal: 4),
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidden = ref.watch(appSettingsProvider).value?.hideTooltips ?? false;
    if (hidden) return const SizedBox.shrink();

    return Padding(
      padding: padding,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => isDesktopLayout(context)
              ? openGlossaryPopup(ref, term: term)
              : GlossarySheet.show(context, initialTerm: term),
          child: SizedBox(
            width: 20,
            height: 20,
            child: Center(
              child: Icon(
                Icons.help_outline_rounded,
                size: size,
                color: const Color(0xFF99A2AD),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
