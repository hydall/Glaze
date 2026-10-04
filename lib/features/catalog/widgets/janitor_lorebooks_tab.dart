import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../services/janitor_public_lorebook.dart';

/// Context passed to the catalog-preview Lorebooks tab and to the capture sheet.
/// Carries the JanitorAI character id, its source URL and the raw `/hampter`
/// metadata (for the attached `scripts`).
class JanitorLorebookArgs {
  final String characterId;
  final String sourceUrl;
  final Map<String, dynamic> meta;
  final bool definitionPublic;

  const JanitorLorebookArgs({
    required this.characterId,
    required this.sourceUrl,
    required this.meta,
    this.definitionPublic = false,
  });
}

/// The catalog preview's **Lorebooks** tab: an inventory of what the character
/// has, and nothing else.
///
/// Downloading a public book and capturing/rebuilding a closed one both happen
/// in the import flow — the Import button offers "Lorebooks" and "Character +
/// lorebooks", which open the capture sheet
/// (`showJanitorLorebookCaptureSheet`). Keeping the preview read-only means a
/// lorebook is only ever pulled as part of an import the user actually asked
/// for, instead of two places doing the same capture with different targets.
class JanitorLorebooksTab extends StatefulWidget {
  final JanitorLorebookArgs args;
  const JanitorLorebooksTab({super.key, required this.args});

  @override
  State<JanitorLorebooksTab> createState() => _JanitorLorebooksTabState();
}

class _JanitorLorebooksTabState extends State<JanitorLorebooksTab> {
  bool _loading = true;
  List<PublicLorebook> _books = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final books = await fetchPublicLorebooks(widget.args.meta);
    if (!mounted) return;
    setState(() {
      _books = books;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: GlazeSpinner(color: cs.primary),
            ),
            const SizedBox(width: 12),
            Text(
              'catalog_lorebooks_loading'.tr(),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    final public = _books.where((b) => b.accessible || b.isJs).toList();
    final closed = _books.where((b) => !b.accessible && !b.isJs).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (public.isEmpty && closed.isEmpty)
            Text(
              'catalog_lorebooks_none'.tr(),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            )
          else ...[
            if (public.isNotEmpty) ...[
              _Title('catalog_lorebooks_public'.tr(), cs: cs),
              const SizedBox(height: 8),
              for (final b in public) ...[
                _LorebookRow(book: b),
                const SizedBox(height: 8),
              ],
            ],
            if (closed.isNotEmpty) ...[
              if (public.isNotEmpty) const SizedBox(height: 12),
              _Title('catalog_lorebooks_closed'.tr(), cs: cs),
              const SizedBox(height: 8),
              for (final b in closed) ...[
                _LorebookRow(book: b),
                const SizedBox(height: 8),
              ],
            ],
            const SizedBox(height: 8),
            _ImportHint(cs: cs),
          ],
        ],
      ),
    );
  }
}

/// One lorebook, described but not actionable: icon by kind (downloadable /
/// scripted / locked), title, a one-line kind hint and the book's own
/// description when it has one.
class _LorebookRow extends StatelessWidget {
  final PublicLorebook book;
  const _LorebookRow({required this.book});

  IconData get _icon {
    if (!book.accessible && !book.isJs) return Icons.lock_outline;
    return book.isJs ? Icons.code_rounded : Icons.menu_book_rounded;
  }

  String get _subtitle {
    if (!book.accessible && !book.isJs) {
      return 'catalog_lorebook_kind_closed'.tr();
    }
    if (book.isJs) return 'catalog_lorebook_kind_scripted'.tr();
    return 'catalog_lorebook_kind_public'.tr(
      args: [book.entryCount.toString()],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final locked = !book.accessible && !book.isJs;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            _icon,
            size: 18,
            color: locked ? cs.onSurfaceVariant : cs.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  book.title.isEmpty ? 'Lorebook' : book.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                Text(
                  _subtitle,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
                if (book.description.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    book.description.trim(),
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.35,
                      color: cs.onSurfaceVariant.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Points at the Import button, which is where lorebooks are actually pulled.
class _ImportHint extends StatelessWidget {
  final ColorScheme cs;
  const _ImportHint({required this.cs});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.primary.withValues(alpha: 0.3)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, size: 16, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'catalog_lorebooks_import_hint'.tr(),
                style: TextStyle(
                  fontSize: 11,
                  height: 1.35,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
}

class _Title extends StatelessWidget {
  final String text;
  final ColorScheme cs;
  const _Title(this.text, {required this.cs});

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: cs.onSurface,
        ),
      );
}
