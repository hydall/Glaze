import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/models/memory_book.dart';
import '../../../shared/widgets/generic_editor.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/theme/app_colors.dart';

/// Editor for one memory entry or draft.
///
/// Was three bare `TextField`s — each with its own `InputDecoration` and a
/// `fillColor: Colors.white.withValues(alpha: 0.05)`, the exact hand-rolled
/// surface `docs/UI_KIT.md` names — plus a `TextButton`/`FilledButton` footer.
/// It is a [GenericEditor] field list now, so the rows are `MenuGroup` rows
/// like every other form in the app.
///
/// The keys field is a `tags` field rather than free text, which also retires
/// the comma-splitting this sheet used to do by hand, and the duplicated
/// caption that repeated the field's own label back at it.
class MemoryEntryEditorSheet extends StatefulWidget {
  final MemoryEntry entry;

  const MemoryEntryEditorSheet({super.key, required this.entry});

  @override
  State<MemoryEntryEditorSheet> createState() => _MemoryEntryEditorSheetState();
}

class _MemoryEntryEditorSheetState extends State<MemoryEntryEditorSheet> {
  late Map<String, dynamic> _values;

  @override
  void initState() {
    super.initState();
    _values = {
      'title': widget.entry.title,
      'keys': List<String>.from(widget.entry.keys),
      'content': widget.entry.content,
    };
  }

  void _save() {
    final content = (_values['content'] as String? ?? '').trim();
    if (content.isEmpty) {
      // Was a silent `return` — the button simply did nothing and never said
      // why, which reads as a broken button rather than a validation failure.
      GlazeToast.show(context, 'memory_books_content_required'.tr());
      return;
    }
    final keys = List<String>.from(_values['keys'] as List? ?? const []);
    final contentChanged = content != widget.entry.content.trim();
    final keyLookup = keys.map((key) => key.toLowerCase()).toSet();
    // Paragraph offsets are anchored to the old body, so any edit to it
    // invalidates every one of them; a key-only edit keeps the ones that
    // still have a key.
    final keyParagraphs = contentChanged
        ? const <String, List<int>>{}
        : {
            for (final entry in widget.entry.keyParagraphs.entries)
              if (keyLookup.contains(entry.key.toLowerCase()))
                entry.key: entry.value,
          };
    Navigator.pop(
      context,
      widget.entry.copyWith(
        title: (_values['title'] as String? ?? '').trim(),
        content: content,
        keys: keys,
        keyParagraphs: keyParagraphs,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GenericEditor(
          item: _values,
          // The host bottom sheet already scrolls, and lays this out with an
          // unbounded height — a scroll view of its own would not resolve.
          scrollable: false,
          padding: EdgeInsets.zero,
          onChanged: (values) => _values = values,
          config: [
            GenericEditorSection(
              fields: [
                GenericEditorField(
                  key: 'title',
                  label: 'label_block_name'.tr(),
                  placeholder: 'placeholder_block_name'.tr(),
                ),
                GenericEditorField(
                  key: 'keys',
                  type: 'tags',
                  label: 'search_type_keys'.tr(),
                  placeholder: 'hint_comma_separated'.tr(),
                ),
                GenericEditorField(
                  key: 'content',
                  type: 'textarea',
                  rows: 8,
                  expandable: true,
                  label: 'label_content'.tr(),
                  placeholder: 'placeholder_lore_content'.tr(),
                ),
              ],
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: _EditorButton(
                  label: 'btn_cancel'.tr(),
                  onTap: () => Navigator.pop(context),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _EditorButton(
                  label: 'btn_save'.tr(),
                  emphasised: true,
                  onTap: _save,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A glass tile acting as the button — the kit has no generic button, and a
/// `FilledButton` here rendered in stock Material grey whatever the preset.
class _EditorButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool emphasised;

  const _EditorButton({
    required this.label,
    required this.onTap,
    this.emphasised = false,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);
    return GlassSurface(
      borderRadius: radius,
      tint: emphasised ? context.cs.primary.withValues(alpha: 0.18) : null,
      border: Border.all(
        color: emphasised
            ? context.cs.primary.withValues(alpha: 0.3)
            : context.cs.outlineVariant,
      ),
      onTap: onTap,
      glowColor: context.cs.primary,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: emphasised ? context.cs.primary : context.cs.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}
