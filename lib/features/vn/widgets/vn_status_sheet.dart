import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_tab_bar.dart';
import '../models/vn_document.dart';

/// The novel's status window: what the player read, the choices they made,
/// what they carry, and the chapters so far.
class VnStatusSheet extends StatefulWidget {
  const VnStatusSheet({
    super.key,
    required this.doc,
    required this.play,
    required this.persona,
  });

  final VnDocument doc;
  final VnPlayState? play;
  final VnPersona? persona;

  static Future<void> show(
    BuildContext context, {
    required VnDocument doc,
    required VnPlayState? play,
    required VnPersona? persona,
  }) {
    return GlazeBottomSheet.show<void>(
      context,
      title: 'vn_status'.tr(),
      child: VnStatusSheet(doc: doc, play: play, persona: persona),
    );
  }

  @override
  State<VnStatusSheet> createState() => _VnStatusSheetState();
}

class _VnStatusSheetState extends State<VnStatusSheet> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlazeTabBar(
            activeIndex: _tab,
            onChanged: (i) => setState(() => _tab = i),
            tabs: [
              GlazeTabItem(
                label: 'vn_status_journal'.tr(),
                icon: Icons.history_rounded,
              ),
              GlazeTabItem(
                label: 'vn_status_choices'.tr(),
                icon: Icons.call_split_rounded,
              ),
              GlazeTabItem(
                label: 'vn_status_inventory'.tr(),
                icon: Icons.backpack_outlined,
              ),
              GlazeTabItem(
                label: 'vn_status_story'.tr(),
                icon: Icons.auto_stories_outlined,
              ),
            ],
          ),
          const SizedBox(height: 16),
          switch (_tab) {
            0 => _journal(context),
            1 => _choices(context),
            2 => _inventory(context),
            _ => _story(context),
          },
        ],
      ),
    );
  }

  Widget _empty(BuildContext context, String key) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32),
    child: Text(
      key.tr(),
      textAlign: TextAlign.center,
      style: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 13),
    ),
  );

  /// Newest first, so the line just read is the first thing seen.
  Widget _journal(BuildContext context) {
    final entries = widget.play?.journal ?? const <VnJournalEntry>[];
    if (entries.isEmpty) return _empty(context, 'vn_status_empty');
    final muted = context.cs.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final e in entries.reversed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: switch (e.kind) {
              'scene' => Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '— ${e.text} —',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 0.6,
                    color: muted,
                  ),
                ),
              ),
              'say' => Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${e.who}: ',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: context.cs.primary,
                      ),
                    ),
                    TextSpan(text: e.text),
                  ],
                ),
                style: TextStyle(fontSize: 14, color: context.cs.onSurface),
              ),
              'choice' => Text(
                '➜ ${e.text}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: context.cs.primary,
                ),
              ),
              'item' => Text(
                e.text,
                style: TextStyle(fontSize: 13, color: muted),
              ),
              _ => Text(
                e.text,
                style: TextStyle(
                  fontSize: 14,
                  fontStyle: FontStyle.italic,
                  color: context.cs.onSurface.withValues(alpha: 0.85),
                ),
              ),
            },
          ),
      ],
    );
  }

  Widget _choices(BuildContext context) {
    final choices = widget.play?.choices ?? const <String>[];
    final flags = widget.play?.flags ?? const <String>[];
    if (choices.isEmpty && flags.isEmpty) {
      return _empty(context, 'vn_status_no_choices');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, c) in choices.indexed)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              radius: 12,
              backgroundColor: context.cs.primary.withValues(alpha: 0.16),
              child: Text(
                '${i + 1}',
                style: TextStyle(fontSize: 11, color: context.cs.primary),
              ),
            ),
            title: Text(c.substring(c.indexOf(': ') + 2)),
            subtitle: Text(c.substring(0, c.indexOf(': '))),
          ),
        if (flags.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'vn_status_flags'.tr(),
            style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final f in flags) Chip(label: Text(f))],
          ),
        ],
      ],
    );
  }

  Widget _inventory(BuildContext context) {
    final carried = widget.play?.inventory ?? const <String>[];
    if (carried.isEmpty) return _empty(context, 'vn_status_no_items');
    final items = widget.doc.items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final id in carried)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.inventory_2_outlined,
              color: context.cs.primary,
            ),
            title: Text(items[id]?.name ?? id),
            subtitle: (items[id]?.description ?? '').isEmpty
                ? null
                : Text(items[id]!.description),
          ),
      ],
    );
  }

  Widget _story(BuildContext context) {
    final persona = widget.persona;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (persona != null) ...[
          Text(
            'vn_status_playing_as'.tr(args: [persona.name]),
            style: TextStyle(fontSize: 13, color: context.cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
        ],
        for (final c in widget.doc.chapters)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('vn_preview_chapter'.tr(args: ['${c.number}'])),
            subtitle: c.summary.isEmpty ? null : Text(c.summary),
          ),
      ],
    );
  }
}
