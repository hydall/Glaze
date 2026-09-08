import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/glossary/glossary_sheet.dart';
import '../../features/settings/app_settings_provider.dart';

/// Small inline help button — opens the [GlossarySheet] at a specific term.
/// Hidden globally when `hideTooltips` is on in app settings.
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
          onTap: () => GlossarySheet.show(context, initialTerm: term),
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
