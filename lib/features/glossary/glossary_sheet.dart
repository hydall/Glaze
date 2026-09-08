import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/glossary/glossary_models.dart';
import '../../core/glossary/glossary_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/sheet_view.dart';
import '../../shared/widgets/glass_surface.dart';
import '../settings/app_settings_provider.dart';

/// Bottom-sheet glossary viewer — port of `GlossarySheet.vue`.
///
/// Three-step navigation: categories → terms list → article.
/// When opened with [initialTerm], jumps straight to that article.
class GlossarySheet extends ConsumerStatefulWidget {
  final String? initialTerm;
  final bool startExpanded;

  const GlossarySheet({
    super.key,
    this.initialTerm,
    this.startExpanded = false,
  });

  /// Convenience launcher used by `HelpTip` and menu entries.
  static Future<void> show(
    BuildContext context, {
    String? initialTerm,
    bool startExpanded = false,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (_) =>
          GlossarySheet(initialTerm: initialTerm, startExpanded: startExpanded),
    );
  }

  @override
  ConsumerState<GlossarySheet> createState() => _GlossarySheetState();
}

enum _View { categories, terms, article }

class _NavFrame {
  final _View view;
  final GlossaryCategory? cat;
  final GlossaryTerm? term;
  const _NavFrame(this.view, this.cat, this.term);
}

class _GlossarySheetState extends ConsumerState<GlossarySheet> {
  _View _view = _View.categories;
  GlossaryCategory? _cat;
  GlossaryTerm? _term;
  String _query = '';
  bool _forward = true;
  final _stack = <_NavFrame>[];
  late bool _openedViaHelptip = widget.initialTerm != null;

  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _selectCategory(GlossaryCategory c) {
    setState(() {
      _forward = true;
      _stack.clear();
      _cat = c;
      _view = _View.terms;
    });
  }

  void _selectTerm(GlossaryTerm t, List<GlossaryCategory> all) {
    setState(() {
      _forward = true;
      _stack.add(_NavFrame(_view, _cat, _term));
      _cat = all.firstWhere(
        (c) => c.terms.any((tt) => tt.id == t.id),
        orElse: () => _cat ?? all.first,
      );
      _term = t;
      _view = _View.article;
    });
  }

  void _goToChip(String termId, List<GlossaryCategory> all) {
    final term = _findTerm(all, termId);
    if (term == null) return;
    setState(() {
      _forward = true;
      _stack.add(_NavFrame(_view, _cat, _term));
      _cat = all.firstWhere(
        (c) => c.terms.any((tt) => tt.id == termId),
        orElse: () => _cat ?? all.first,
      );
      _term = term;
      _view = _View.article;
    });
  }

  GlossaryTerm? _findTerm(List<GlossaryCategory> all, String id) {
    for (final c in all) {
      for (final t in c.terms) {
        if (t.id == id) return t;
      }
    }
    return null;
  }

  void _goBack() {
    if (_stack.isNotEmpty) {
      final prev = _stack.removeLast();
      setState(() {
        _forward = false;
        _view = prev.view;
        _cat = prev.cat;
        _term = prev.term;
      });
      return;
    }
    if (_openedViaHelptip) {
      // Use pop(), not maybePop(): when presented as a fullscreen route the
      // host SheetView wraps us in a PopScope with canPop:false, so maybePop()
      // re-invokes this same handler and spins an unbounded microtask loop
      // (hard UI freeze). pop() bypasses PopScope and dismisses the route.
      Navigator.of(context).pop();
      return;
    }
    if (_view == _View.categories) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _forward = false;
      if (_view == _View.article) {
        _term = null;
        _view = _View.terms;
      } else if (_view == _View.terms) {
        _cat = null;
        _view = _View.categories;
      }
    });
  }

  // ── Color/icon maps ─────────────────────────────────────────────────────

  static const Map<String, IconData> _categoryIcons = {
    'basics': Icons.layers_outlined,
    'characters': Icons.group_outlined,
    'chat': Icons.chat_bubble_outline,
    'presets': Icons.tune_rounded,
    'lorebooks': Icons.menu_book_outlined,
    'regex': Icons.code_rounded,
    'interface': Icons.edit_outlined,
    'faq': Icons.help_outline_rounded,
    'advanced': Icons.public_outlined,
  };

  static const Map<String, (Color, Color)> _categoryColors = {
    'basics': (Color(0x2E6495ED), Color(0xFF6495ED)),
    'characters': (Color(0x2EED8936), Color(0xFFED8936)),
    'chat': (Color(0x2EECC94B), Color(0xFFECC94B)),
    'presets': (Color(0x2E9F7AEA), Color(0xFF9F7AEA)),
    'lorebooks': (Color(0x2EED6464), Color(0xFFED6464)),
    'regex': (Color(0x2E38BDB2), Color(0xFF38BDB2)),
    'interface': (Color(0x2EED64A6), Color(0xFFED64A6)),
    'faq': (Color(0x2E48BB78), Color(0xFF48BB78)),
    'advanced': (Color(0x2EA0AEC0), Color(0xFFA0AEC0)),
  };

  IconData _iconFor(String id) =>
      _categoryIcons[id] ?? _categoryIcons['advanced']!;

  (Color, Color) _colorFor(String id) =>
      _categoryColors[id] ?? _categoryColors['basics']!;

  // ── Build ──────────────────────────────────────────────────────────────

  String _title() {
    if (_view == _View.terms && _cat != null) return _cat!.label;
    if (_view == _View.article && _term != null) return _term!.name;
    return _safeTr('menu_glossary', fallback: 'Glossary');
  }

  String _safeTr(String key, {required String fallback}) {
    try {
      final translated = key.tr();
      if (translated == key) return fallback;
      return translated;
    } catch (_) {
      return fallback;
    }
  }

  @override
  Widget build(BuildContext context) {
    final lang = ref.watch(appSettingsProvider).value?.language ?? 'en';
    final asyncCats = ref.watch(glossaryProvider(lang));

    return asyncCats.when(
      loading: () => SheetView(
        title: _safeTr('menu_glossary', fallback: 'Glossary'),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => SheetView(
        title: _safeTr('menu_glossary', fallback: 'Glossary'),
        body: Center(child: Text('${'title_error'.tr()}: $e')),
      ),
      data: (categories) {
        // If first build & we want to land on a specific term, resolve it.
        if (widget.initialTerm != null &&
            _view == _View.categories &&
            _term == null) {
          final t = _findTerm(categories, widget.initialTerm!);
          if (t != null) {
            _term = t;
            _cat = categories.firstWhere(
              (c) => c.terms.any((tt) => tt.id == widget.initialTerm),
              orElse: () => categories.first,
            );
            _view = _View.article;
            _openedViaHelptip = true;
          }
        }

        final bool showSearch = _view == _View.categories;

        return SheetView(
          title: _title(),
          showBack:
              _view != _View.categories ||
              ModalRoute.of(context) is! ModalBottomSheetRoute,
          onBack: _goBack,
          startExpanded: widget.startExpanded,
          headerBottom: showSearch ? _buildSearchBar(context) : null,
          body: Builder(
            builder: (innerContext) {
              final mediaPad = EdgeInsets.only(
                top: MediaQuery.paddingOf(innerContext).top,
                bottom: MediaQuery.paddingOf(innerContext).bottom,
              );
              return AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, anim) {
                  final offsetTween = Tween<Offset>(
                    begin: Offset(_forward ? 0.08 : -0.08, 0),
                    end: Offset.zero,
                  );
                  return FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: offsetTween.animate(anim),
                      child: child,
                    ),
                  );
                },
                child: _buildContent(innerContext, categories, mediaPad),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildSearchBar(BuildContext context) {
    return GlassSurface(
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: context.cs.outlineVariant),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(Icons.search, size: 18, color: context.cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  hintText: _safeTr('search', fallback: 'Search...'),
                  hintStyle: TextStyle(color: context.cs.onSurfaceVariant),
                ),
                style: TextStyle(fontSize: 15, color: context.cs.onSurface),
              ),
            ),
            if (_query.trim().isNotEmpty)
              GestureDetector(
                onTap: () {
                  _searchCtrl.clear();
                  setState(() => _query = '');
                },
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.close,
                    size: 14,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    List<GlossaryCategory> cats,
    EdgeInsets mediaPad,
  ) {
    switch (_view) {
      case _View.categories:
        return KeyedSubtree(
          key: const ValueKey('cats'),
          child: _query.trim().isEmpty
              ? _buildCategoriesGrid(context, cats, mediaPad)
              : _buildSearchResults(context, cats, mediaPad),
        );
      case _View.terms:
        return KeyedSubtree(
          key: ValueKey('terms-${_cat?.id}'),
          child: _buildTermsList(context, cats, mediaPad),
        );
      case _View.article:
        return KeyedSubtree(
          key: ValueKey('article-${_term?.id}'),
          child: _buildArticle(context, cats, mediaPad),
        );
    }
  }

  Widget _buildCategoriesGrid(
    BuildContext context,
    List<GlossaryCategory> cats,
    EdgeInsets mediaPad,
  ) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 80).add(mediaPad),
      children: [
        for (final c in cats) ...[
          _CategoryCard(
            label: c.label,
            count: c.terms.length,
            icon: _iconFor(c.id),
            colors: _colorFor(c.id),
            countLabel: _safeTr('glossary_terms', fallback: 'terms'),
            onTap: () => _selectCategory(c),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _buildSearchResults(
    BuildContext context,
    List<GlossaryCategory> cats,
    EdgeInsets mediaPad,
  ) {
    final q = _query.trim().toLowerCase();
    final results = <(GlossaryTerm, String)>[];
    for (final c in cats) {
      for (final t in c.terms) {
        final hit =
            t.name.toLowerCase().contains(q) ||
            (t.alt?.toLowerCase().contains(q) ?? false) ||
            t.desc.toLowerCase().contains(q);
        if (hit) results.add((t, c.label));
      }
    }
    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 40, 20, 40).add(mediaPad),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off,
              size: 32,
              color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 10),
            Text(
              _safeTr('no_results', fallback: 'No results'),
              style: TextStyle(
                fontSize: 14,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 80).add(mediaPad),
      itemCount: results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (_, i) {
        final (term, catLabel) = results[i];
        final sub = term.alt != null ? '$catLabel · ${term.alt}' : catLabel;
        return _TermTile(
          name: term.name,
          sub: sub,
          onTap: () => _selectTerm(term, cats),
        );
      },
    );
  }

  Widget _buildTermsList(
    BuildContext context,
    List<GlossaryCategory> cats,
    EdgeInsets mediaPad,
  ) {
    final terms = _cat?.terms ?? const [];
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 80).add(mediaPad),
      itemCount: terms.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (_, i) {
        final t = terms[i];
        return _TermTile(
          name: t.name,
          sub: t.alt,
          onTap: () => _selectTerm(t, cats),
        );
      },
    );
  }

  Widget _buildArticle(
    BuildContext context,
    List<GlossaryCategory> cats,
    EdgeInsets mediaPad,
  ) {
    final term = _term;
    if (term == null) return const SizedBox.shrink();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 80).add(mediaPad),
      children: [
        Text(
          term.name,
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: context.cs.onSurface,
            height: 1.15,
            letterSpacing: -0.5,
          ),
        ),
        if (term.alt != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: context.cs.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              term.alt!,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: context.cs.primary,
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Container(height: 1, color: Colors.white.withValues(alpha: 0.08)),
        const SizedBox(height: 16),
        _RichDescription(
          desc: term.desc,
          categories: cats,
          onChipTap: (id) => _goToChip(id, cats),
        ),
      ],
    );
  }
}

// ───────────────────── Helpers ─────────────────────

class _CategoryCard extends StatelessWidget {
  final String label;
  final int count;
  final String countLabel;
  final IconData icon;
  final (Color, Color) colors;
  final VoidCallback onTap;

  const _CategoryCard({
    required this.label,
    required this.count,
    required this.countLabel,
    required this.icon,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: context.cs.outlineVariant),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: colors.$1,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: colors.$2, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: context.cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$count $countLabel',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TermTile extends StatelessWidget {
  final String name;
  final String? sub;
  final VoidCallback onTap;

  const _TermTile({required this.name, this.sub, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: context.cs.outlineVariant),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: context.cs.onSurface,
                        ),
                      ),
                      if (sub != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          sub!,
                          style: TextStyle(
                            fontSize: 12,
                            color: context.cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Description renderer ────────────────────────────────────────────────

class _RichDescription extends StatelessWidget {
  final String desc;
  final List<GlossaryCategory> categories;
  final ValueChanged<String> onChipTap;

  const _RichDescription({
    required this.desc,
    required this.categories,
    required this.onChipTap,
  });

  static final _re = RegExp(
    r'\[\[([^\]|]+)(?:\|([^\]]*))?\]\]|\[([^\]]+)\]\((https?:\/\/[^)]+)\)|\[icon:([^\]]+)\]',
  );

  static const Map<String, IconData> _inlineIcons = {
    'triggered-items': Icons.layers_outlined,
  };

  GlossaryTerm? _lookup(String id) {
    for (final c in categories) {
      for (final t in c.terms) {
        if (t.id == id) return t;
      }
    }
    return null;
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    int lastEnd = 0;

    final baseStyle = TextStyle(
      fontSize: 15,
      height: 1.7,
      color: context.cs.onSurface.withValues(alpha: 0.9),
    );

    for (final m in _re.allMatches(desc)) {
      if (m.start > lastEnd) {
        spans.add(TextSpan(text: desc.substring(lastEnd, m.start)));
      }
      if (m.group(5) != null) {
        // inline icon
        final id = m.group(5)!;
        final icon = _inlineIcons[id] ?? Icons.layers_outlined;
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Icon(icon, size: 15, color: context.cs.onSurfaceVariant),
            ),
          ),
        );
      } else if (m.group(4) != null) {
        // external link
        final label = m.group(3)!;
        final url = m.group(4)!;
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _LinkChip(
              label: label,
              color: const Color(0xFF68D391),
              bg: const Color(0x2D48BB78),
              border: const Color(0x4D48BB78),
              onTap: () => _openLink(url),
            ),
          ),
        );
      } else {
        // term chip
        final termId = m.group(1)!;
        final display = m.group(2);
        final ref = _lookup(termId);
        final label = display ?? ref?.name ?? termId;
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _LinkChip(
              label: label,
              color: context.cs.primary,
              bg: context.cs.primary.withValues(alpha: 0.18),
              border: context.cs.primary.withValues(alpha: 0.28),
              onTap: () => onChipTap(termId),
            ),
          ),
        );
      }
      lastEnd = m.end;
    }
    if (lastEnd < desc.length) {
      spans.add(TextSpan(text: desc.substring(lastEnd)));
    }

    return RichText(
      text: TextSpan(style: baseStyle, children: spans),
    );
  }
}

class _LinkChip extends StatelessWidget {
  final String label;
  final Color color;
  final Color bg;
  final Color border;
  final VoidCallback onTap;

  const _LinkChip({
    required this.label,
    required this.color,
    required this.bg,
    required this.border,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            height: 1.5,
          ),
        ),
      ),
    );
  }
}
