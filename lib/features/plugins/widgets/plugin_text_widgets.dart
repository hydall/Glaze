import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/menu_group.dart';
import '../screens/plugin_hub_sheet.dart';

/// A plugin's own text (description, release notes) rendered as markdown.
/// Images are left out: a description must not make the app fetch from
/// wherever its author points.
class PluginMarkdown extends StatelessWidget {
  const PluginMarkdown(this.text, {super.key, this.color});

  final String text;

  /// Defaults to the theme's secondary text colour.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return GptMarkdown(
      text,
      style: TextStyle(
        fontSize: 13.5,
        height: 1.5,
        color: color ?? context.cs.onSurfaceVariant,
      ),
      onLinkTap: (url, _) {
        final uri = Uri.tryParse(url);
        if (uri == null || openPluginHubLinkInApp(uri)) return;
        launchUrl(uri, mode: LaunchMode.externalApplication);
      },
      imageBuilder: (_, _, _, _) => const SizedBox.shrink(),
    );
  }
}

/// A row that opens to show [text] as markdown under it; closed until
/// tapped unless [initiallyExpanded].
class PluginDescriptionItem extends StatefulWidget {
  const PluginDescriptionItem({
    super.key,
    required this.text,
    this.initiallyExpanded = false,
  });

  final String text;
  final bool initiallyExpanded;

  @override
  State<PluginDescriptionItem> createState() => _PluginDescriptionItemState();
}

class _PluginDescriptionItemState extends State<PluginDescriptionItem> {
  late bool _open = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MenuItem(
          icon: Icons.notes_rounded,
          label: 'plugins_description'.tr(),
          trailing: AnimatedRotation(
            turns: _open ? 0.5 : 0,
            duration: const Duration(milliseconds: 150),
            child: Icon(
              Icons.expand_more_rounded,
              color: context.cs.onSurfaceVariant,
            ),
          ),
          onTap: () => setState(() => _open = !_open),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: _open
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: PluginMarkdown(widget.text),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// The version row; with release notes it opens them.
MenuItem pluginVersionItem(
  BuildContext context, {
  required String version,
  String? releaseNotes,
}) => MenuItem(
  icon: Icons.tag_rounded,
  label: 'plugins_version'.tr(),
  subtitle: releaseNotes == null ? null : 'plugins_release_notes_hint'.tr(),
  value: version,
  onTap: () {
    if (releaseNotes != null) {
      showPluginReleaseNotes(context, releaseNotes);
    }
  },
);

Future<void> showPluginReleaseNotes(BuildContext context, String notes) =>
    GlazeBottomSheet.show<void>(
      context,
      title: 'plugins_release_notes'.tr(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: PluginMarkdown(notes),
      ),
    );
