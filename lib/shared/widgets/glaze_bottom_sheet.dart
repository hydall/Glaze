import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/haptics.dart';
import '../theme/app_colors.dart';
import '../../features/settings/app_settings_provider.dart';
import 'glass_surface.dart';
import 'top_edge_blur.dart';

// ── Data models ───────────────────────────────────────────────────────────────

class BottomSheetAction {
  final IconData icon;
  final Color? color;
  final VoidCallback onTap;

  const BottomSheetAction({
    required this.icon,
    this.color,
    required this.onTap,
  });
}

class BottomSheetItem {
  final String label;
  final IconData? icon;
  final Color? iconColor;
  final VoidCallback onTap;
  final bool isDestructive;
  final String? hint;
  final bool centered;
  final List<BottomSheetAction> actions;

  const BottomSheetItem({
    required this.label,
    this.icon,
    this.iconColor,
    required this.onTap,
    this.isDestructive = false,
    this.hint,
    this.centered = false,
    this.actions = const [],
  });
}

class BottomSheetSessionItem {
  final String title;
  final int count;
  final String time;
  final String preview;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onMore;

  const BottomSheetSessionItem({
    required this.title,
    required this.count,
    required this.time,
    required this.preview,
    this.isActive = false,
    required this.onTap,
    required this.onMore,
  });
}

class BottomSheetCardItem {
  final String label;
  final String? sublabel;
  final IconData? icon;
  final String? faviconUrl;
  final String? imageUrl;
  final String? badge;
  final bool isFeatured;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final List<BottomSheetAction> actions;

  const BottomSheetCardItem({
    required this.label,
    this.sublabel,
    this.icon,
    this.faviconUrl,
    this.imageUrl,
    this.badge,
    this.isFeatured = false,
    this.isActive = false,
    required this.onTap,
    this.onLongPress,
    this.actions = const [],
  });
}

class BottomSheetBigInfo {
  final IconData icon;
  final String description;
  final String? buttonText;
  final bool buttonDisabled;
  final VoidCallback? onButtonTap;

  const BottomSheetBigInfo({
    required this.icon,
    required this.description,
    this.buttonText,
    this.buttonDisabled = false,
    this.onButtonTap,
  });
}

class BottomSheetInput {
  final String placeholder;
  final String value;
  final String confirmLabel;
  final void Function(String) onConfirm;

  const BottomSheetInput({
    required this.placeholder,
    this.value = '',
    this.confirmLabel = 'Save',
    required this.onConfirm,
  });
}

typedef BottomSheetItemBuilder =
    BottomSheetItem Function(BuildContext context, int index);

// ── Public API ────────────────────────────────────────────────────────────────

class GlazeBottomSheet {
  static Future<T?> show<T>(
    BuildContext context, {
    String? title,
    Widget? headerAction,
    List<BottomSheetItem>? items,
    int? itemCount,
    BottomSheetItemBuilder? itemBuilder,
    List<BottomSheetItem>? itemsAsCards,
    List<BottomSheetSessionItem>? sessionItems,
    List<BottomSheetCardItem>? cardItems,
    BottomSheetBigInfo? bigInfo,
    BottomSheetInput? input,
    Widget? child,
    bool locked = false,
    bool isDismissible = true,
    int? scrollToIndex,
  }) {
    assert(
      (itemCount == null) == (itemBuilder == null),
      'itemCount and itemBuilder must be provided together.',
    );
    assert(
      itemBuilder == null || items == null,
      'items and itemBuilder cannot be used together.',
    );
    assert(
      itemCount == null || itemCount >= 0,
      'itemCount cannot be negative.',
    );
    assert(
      itemBuilder == null ||
          (itemsAsCards == null &&
              sessionItems == null &&
              cardItems == null &&
              bigInfo == null &&
              input == null &&
              child == null),
      'Lazy items cannot be combined with other sheet body content.',
    );
    assert(
      itemBuilder == null || scrollToIndex == null,
      'scrollToIndex is only supported for materialized items.',
    );
    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      enableDrag: !locked,
      isDismissible: isDismissible,
      isScrollControlled: true,
      builder: (_) => _GlazeBottomSheetContent(
        title: title,
        headerAction: headerAction,
        items: items,
        itemCount: itemCount,
        itemBuilder: itemBuilder,
        itemsAsCards: itemsAsCards,
        sessionItems: sessionItems,
        cardItems: cardItems,
        bigInfo: bigInfo,
        input: input,
        locked: locked,
        scrollToIndex: scrollToIndex,
        child: child,
      ),
    );
  }
}

// ── Sheet content ─────────────────────────────────────────────────────────────

class GlazeBottomSheetFrame extends ConsumerWidget {
  final Widget child;
  final bool showHandle;
  final double maxHeightFactor;

  /// Explicit pixel cap on the sheet height. When set it overrides
  /// [maxHeightFactor] — used when the sheet must fit a constrained slot (e.g.
  /// the color picker, which must not cover the pinned preview above it).
  final double? maxHeight;

  const GlazeBottomSheetFrame({
    super.key,
    required this.child,
    this.showHandle = true,
    this.maxHeightFactor = 0.95,
    this.maxHeight,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cap =
        maxHeight ?? MediaQuery.of(context).size.height * maxHeightFactor;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: cap),
      child: GlassSurface(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: context.cs.outlineVariant)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showHandle) _HandleBar(),
            Flexible(fit: FlexFit.loose, child: child),
          ],
        ),
      ),
    );
  }
}

class _GlazeBottomSheetContent extends ConsumerStatefulWidget {
  final String? title;
  final Widget? headerAction;
  final List<BottomSheetItem>? items;
  final int? itemCount;
  final BottomSheetItemBuilder? itemBuilder;
  final List<BottomSheetItem>? itemsAsCards;
  final List<BottomSheetSessionItem>? sessionItems;
  final List<BottomSheetCardItem>? cardItems;
  final BottomSheetBigInfo? bigInfo;
  final BottomSheetInput? input;
  final Widget? child;
  final bool locked;
  final int? scrollToIndex;

  const _GlazeBottomSheetContent({
    this.title,
    this.headerAction,
    this.items,
    this.itemCount,
    this.itemBuilder,
    this.itemsAsCards,
    this.sessionItems,
    this.cardItems,
    this.bigInfo,
    this.input,
    this.child,
    required this.locked,
    this.scrollToIndex,
  });

  @override
  ConsumerState<_GlazeBottomSheetContent> createState() =>
      _GlazeBottomSheetContentState();
}

class _GlazeBottomSheetContentState
    extends ConsumerState<_GlazeBottomSheetContent> {
  late final TextEditingController _inputController;
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final _headerKey = GlobalKey();
  final _scrollTargetKey = GlobalKey();
  double _headerH = 52; // Estimate initial height

  @override
  void initState() {
    super.initState();
    _inputController = TextEditingController(text: widget.input?.value ?? '');
    if (widget.input != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        FocusScope.of(context).requestFocus(_inputFocus);
      });
    }
    if (widget.scrollToIndex != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _scrollTargetKey.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            alignment: 0.5,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  void _measureHeader() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _headerKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final h = box.size.height;
      if (h != _headerH) {
        setState(() => _headerH = h);
      }
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    _inputFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool get _hasHeader => widget.title != null || widget.headerAction != null;

  Widget _buildLazyList(BuildContext context, EdgeInsets padding) {
    return CustomScrollView(
      controller: _scrollController,
      shrinkWrap: true,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16).add(padding),
          sliver: SliverList.builder(
            itemCount: widget.itemCount,
            itemBuilder: (context, index) => _LazyItemRow(
              item: widget.itemBuilder!(context, index),
              isFirst: index == 0,
              isLast: index == widget.itemCount! - 1,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    // The modal route wraps us in SafeArea(bottom: false), so the sheet must
    // reserve the system navigation-bar inset itself — otherwise (in
    // edge-to-edge) the last row sits under the nav bar. padding.bottom is 0
    // while the keyboard is up, so it never double-counts with bottomInset.
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final batterySaver = ref.watch(
      appSettingsProvider.select((s) => s.value?.batterySaver ?? false),
    );

    _measureHeader();

    final sheetBody = ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.95,
      ),
      child: GlassSurface(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: context.cs.outlineVariant)),
        child: Stack(
          children: [
            TopEdgeBlur(
              enabled: !batterySaver,
              height: _headerH + 8,
              sigma: 24,
              tintColor: context.cs.surface.withValues(alpha: 0.88),
              child: Padding(
                // Only the header is reserved as an *outer* inset. The
                // nav-bar/keyboard inset goes *inside* the scroll view as
                // content padding (below), so the viewport still reaches the
                // sheet's bottom edge: list rows stay visible scrolling behind
                // the nav bar, while the last row (e.g. Cancel/Save) rests
                // above it. Reserving it out here instead would shrink the
                // viewport and leave a dead strip no content can scroll into.
                padding: EdgeInsets.only(top: _headerH),
                child: RawScrollbar(
                  controller: _scrollController,
                  thumbColor: Colors.white.withValues(alpha: 0.15),
                  radius: const Radius.circular(3),
                  thickness: 4,
                  padding: const EdgeInsets.only(right: 3),
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(
                      context,
                    ).copyWith(scrollbars: false),
                    child: widget.itemBuilder != null
                        ? _buildLazyList(
                            context,
                            EdgeInsets.only(
                              bottom: bottomInset + safeBottom + 16,
                            ),
                          )
                        : SingleChildScrollView(
                            controller: _scrollController,
                            padding: EdgeInsets.only(
                              bottom: bottomInset + safeBottom + 16,
                            ),
                            // Isolates the sheet content in its own layer so a
                            // scroll only shifts the layer instead of re-recording
                            // every row each frame.
                            child: RepaintBoundary(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(height: 4),
                                  if (widget.child != null) widget.child!,
                                  if (widget.bigInfo != null)
                                    _BigInfo(info: widget.bigInfo!),
                                  if (widget.items != null &&
                                      widget.items!.isNotEmpty)
                                    _ItemsList(
                                      items: widget.items!,
                                      scrollToIndex: widget.scrollToIndex,
                                      scrollTargetKey: _scrollTargetKey,
                                    ),
                                  if (widget.itemsAsCards != null &&
                                      widget.itemsAsCards!.isNotEmpty)
                                    _ItemsCardList(items: widget.itemsAsCards!),
                                  if (widget.sessionItems != null &&
                                      widget.sessionItems!.isNotEmpty)
                                    GlazeSessionList(
                                      items: widget.sessionItems!,
                                    ),
                                  if (widget.cardItems != null &&
                                      widget.cardItems!.isNotEmpty)
                                    _CardList(items: widget.cardItems!),
                                  if (widget.input != null)
                                    _InputSection(
                                      input: widget.input!,
                                      controller: _inputController,
                                      focusNode: _inputFocus,
                                    ),
                                ],
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            ),

            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: KeyedSubtree(
                key: _headerKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _HandleBar(),
                    if (_hasHeader)
                      _Header(title: widget.title, action: widget.headerAction),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return sheetBody;
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _HandleBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          width: 32,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String? title;
  final Widget? action;

  const _Header({this.title, this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 12, 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title ?? '',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: context.cs.onSurface,
              ),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

class _ItemsList extends StatelessWidget {
  final List<BottomSheetItem> items;
  final int? scrollToIndex;
  final Key? scrollTargetKey;

  const _ItemsList({
    required this.items,
    this.scrollToIndex,
    this.scrollTargetKey,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          borderRadius: BorderRadius.circular(16),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (int i = 0; i < items.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  thickness: 1,
                  color: Colors.white.withValues(alpha: 0.06),
                ),
              KeyedSubtree(
                key: i == scrollToIndex ? scrollTargetKey : null,
                child: _ItemRow(item: items[i]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ItemRow extends StatefulWidget {
  final BottomSheetItem item;

  const _ItemRow({required this.item});

  @override
  State<_ItemRow> createState() => _ItemRowState();
}

class _ItemRowState extends State<_ItemRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () {
        setState(() => _pressed = false);
        Haptics.selectionClick();
        item.onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        color: _pressed
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            if (item.icon != null) ...[
              Icon(
                item.icon,
                size: 22,
                color:
                    item.iconColor ??
                    (item.isDestructive
                        ? const Color(0xFFFF4444)
                        : context.cs.onSurfaceVariant),
              ),
              const SizedBox(width: 16),
            ],
            Expanded(
              child: item.centered
                  ? Center(child: _ItemLabel(item: item))
                  : _ItemLabel(item: item),
            ),
            if (item.actions.isNotEmpty)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: item.actions
                    .map(
                      (a) => GestureDetector(
                        onTap: a.onTap,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Icon(
                            a.icon,
                            size: 22,
                            color: a.color ?? context.cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }
}

class _LazyItemRow extends StatelessWidget {
  final BottomSheetItem item;
  final bool isFirst;
  final bool isLast;

  const _LazyItemRow({
    required this.item,
    required this.isFirst,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.vertical(
        top: isFirst ? const Radius.circular(16) : Radius.zero,
        bottom: isLast ? const Radius.circular(16) : Radius.zero,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          border: Border(
            top: BorderSide(
              color: Colors.white.withValues(alpha: isFirst ? 0.1 : 0.06),
            ),
            left: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
            right: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
            bottom: isLast
                ? BorderSide(color: Colors.white.withValues(alpha: 0.1))
                : BorderSide.none,
          ),
        ),
        child: _ItemRow(item: item),
      ),
    );
  }
}

class _ItemsCardList extends StatelessWidget {
  final List<BottomSheetItem> items;

  const _ItemsCardList({required this.items});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        children: [
          for (int i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ItemCardRow(item: items[i]),
            ),
        ],
      ),
    );
  }
}

class _ItemCardRow extends StatefulWidget {
  final BottomSheetItem item;

  const _ItemCardRow({required this.item});

  @override
  State<_ItemCardRow> createState() => _ItemCardRowState();
}

class _ItemCardRowState extends State<_ItemCardRow> {
  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Material(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: () {
          Haptics.selectionClick();
          item.onTap();
        },
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              if (item.icon != null) ...[
                Icon(
                  item.icon,
                  size: 22,
                  color:
                      item.iconColor ??
                      (item.isDestructive
                          ? const Color(0xFFFF4444)
                          : context.cs.onSurfaceVariant),
                ),
                const SizedBox(width: 16),
              ],
              Expanded(
                child: item.centered
                    ? Center(child: _ItemLabel(item: item))
                    : _ItemLabel(item: item),
              ),
              if (item.actions.isNotEmpty)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: item.actions
                      .map(
                        (a) => GestureDetector(
                          onTap: a.onTap,
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Icon(
                              a.icon,
                              size: 22,
                              color: a.color ?? context.cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ItemLabel extends StatelessWidget {
  final BottomSheetItem item;

  const _ItemLabel({required this.item});

  @override
  Widget build(BuildContext context) {
    final color = item.isDestructive
        ? const Color(0xFFFF4444)
        : context.cs.onSurface;
    if (item.hint != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.label, style: TextStyle(fontSize: 16, color: color)),
          const SizedBox(height: 2),
          Text(
            item.hint!,
            style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
          ),
        ],
      );
    }
    return Text(item.label, style: TextStyle(fontSize: 16, color: color));
  }
}

class GlazeSessionList extends StatelessWidget {
  final List<BottomSheetSessionItem> items;

  const GlazeSessionList({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        children: [
          for (int i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: GlazeSessionRow(item: items[i]),
            ),
        ],
      ),
    );
  }
}

class GlazeSessionRow extends StatelessWidget {
  final BottomSheetSessionItem item;

  const GlazeSessionRow({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: item.onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            item.title,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: context.cs.onSurface,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Row(
                          children: [
                            Icon(
                              Icons.chat_bubble_outline,
                              size: 13,
                              color: context.cs.onSurfaceVariant,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              '${item.count}',
                              style: TextStyle(
                                fontSize: 12,
                                color: context.cs.onSurfaceVariant,
                              ),
                            ),
                            if (item.time.isNotEmpty) ...[
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: Text(
                                  '·',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: context.cs.onSurfaceVariant
                                        .withValues(alpha: 0.5),
                                  ),
                                ),
                              ),
                              Text(
                                item.time,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: context.cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.preview,
                      style: TextStyle(
                        fontSize: 13,
                        color: context.cs.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (item.isActive) ...[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: context.cs.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  GestureDetector(
                    onTap: item.onMore,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.more_vert,
                        size: 20,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CardList extends StatelessWidget {
  final List<BottomSheetCardItem> items;

  const _CardList({required this.items});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        children: items
            .map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _CardRow(item: item),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _CardRow extends StatefulWidget {
  final BottomSheetCardItem item;

  const _CardRow({required this.item});

  @override
  State<_CardRow> createState() => _CardRowState();
}

class _CardRowState extends State<_CardRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final hasImage = item.imageUrl != null;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        item.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      onLongPress: item.onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        constraints: hasImage ? const BoxConstraints(minHeight: 160) : null,
        decoration: BoxDecoration(
          color: _pressed
              ? context.cs.primary.withValues(alpha: 0.1)
              : item.isActive
              ? context.cs.primary.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.04),
          border: Border.all(
            color: item.isActive
                ? context.cs.primary.withValues(alpha: 0.4)
                : const Color(0xFF555555),
          ),
          borderRadius: BorderRadius.circular(12),
          image: hasImage
              ? DecorationImage(
                  image: NetworkImage(item.imageUrl!),
                  fit: BoxFit.cover,
                )
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            if (hasImage)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.3),
                        Colors.black.withValues(alpha: 0.8),
                      ],
                    ),
                  ),
                ),
              ),
            if (item.isFeatured)
              Positioned(
                top: 10,
                left: 12,
                child: Text(
                  'label_featured_preset'.tr(),
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.08 * 9,
                    color: Colors.white.withValues(alpha: 0.5),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if ((item.icon != null || item.faviconUrl != null) &&
                      !hasImage) ...[
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: context.cs.primary.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: item.faviconUrl != null
                          ? Image.network(
                              item.faviconUrl!,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) =>
                                  Icon(
                                    item.icon ?? Icons.api_rounded,
                                    size: 20,
                                    color: context.cs.primary,
                                  ),
                            )
                          : Icon(
                              item.icon,
                              size: 20,
                              color: context.cs.primary,
                            ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: _CardItemInfo(item: item, hasImage: hasImage),
                  ),
                  if (item.actions.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    _CardActions(actions: item.actions, hasImage: hasImage),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CardItemInfo extends StatelessWidget {
  final BottomSheetCardItem item;
  final bool hasImage;

  const _CardItemInfo({required this.item, required this.hasImage});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                item.label,
                style: TextStyle(
                  fontSize: hasImage ? 16 : 15,
                  fontWeight: FontWeight.w600,
                  color: hasImage ? Colors.white : context.cs.onSurface,
                  shadows: hasImage
                      ? [const Shadow(color: Colors.black87, blurRadius: 3)]
                      : null,
                ),
              ),
            ),
            if (item.badge != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: hasImage
                      ? Colors.white.withValues(alpha: 0.2)
                      : Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: hasImage
                      ? Border.all(color: Colors.white.withValues(alpha: 0.1))
                      : null,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.description_outlined,
                      size: 12,
                      color: hasImage
                          ? Colors.white
                          : context.cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      item.badge!,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: hasImage
                            ? Colors.white
                            : context.cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        if (item.sublabel != null) ...[
          const SizedBox(height: 2),
          Text(
            item.sublabel!,
            style: TextStyle(
              fontSize: 12,
              color: hasImage ? Colors.white70 : context.cs.onSurfaceVariant,
              shadows: hasImage
                  ? [const Shadow(color: Colors.black87, blurRadius: 2)]
                  : null,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

class _CardActions extends StatelessWidget {
  final List<BottomSheetAction> actions;
  final bool hasImage;

  const _CardActions({required this.actions, required this.hasImage});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: actions
          .map(
            (a) => GestureDetector(
              onTap: a.onTap,
              child: Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.all(6),
                decoration: hasImage
                    ? BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.4),
                        shape: BoxShape.circle,
                      )
                    : null,
                child: Icon(
                  a.icon,
                  size: 20,
                  color: hasImage
                      ? Colors.white
                      : (a.color ?? context.cs.onSurfaceVariant),
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

class _BigInfo extends StatelessWidget {
  final BottomSheetBigInfo info;

  const _BigInfo({required this.info});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        children: [
          Icon(
            info.icon,
            size: 64,
            color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            info.description,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              color: context.cs.onSurface,
              height: 1.5,
            ),
          ),
          if (info.buttonText != null) ...[
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: info.buttonDisabled ? null : info.onButtonTap,
                child: Text(info.buttonText!),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _InputSection extends StatelessWidget {
  final BottomSheetInput input;
  final TextEditingController controller;
  final FocusNode focusNode;

  const _InputSection({
    required this.input,
    required this.controller,
    required this.focusNode,
  });

  void _confirm(BuildContext context) {
    final value = controller.text.trim();
    if (value.isNotEmpty) {
      // Callers of BottomSheetInput.onConfirm are responsible for popping
      // the sheet themselves (so they can do it before/after their work as
      // needed). Don't pop here or we'd double-pop and unwind a real route.
      input.onConfirm(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        children: [
          TextField(
            controller: controller,
            focusNode: focusNode,
            style: TextStyle(color: context.cs.onSurface),
            decoration: InputDecoration(
              hintText: input.placeholder,
              hintStyle: TextStyle(color: context.cs.onSurfaceVariant),
            ),
            onSubmitted: (_) => _confirm(context),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => _confirm(context),
              child: Text(input.confirmLabel),
            ),
          ),
        ],
      ),
    );
  }
}
