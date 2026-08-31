import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/shell/shell_header_provider.dart';
import '../../shared/shell/nav_height_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_scaffold.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../menu/search/menu_search_entry.dart';
import '../menu/search/menu_search_index.dart';
import '../menu/search/menu_search_results.dart';
import 'app_settings_provider.dart';
import 'settings_reset_service.dart';
import 'widgets/app_settings_groups.dart';

/// One flat screen of themed setting groups, with a header search over the very
/// same index the More tab searches — see `features/menu/search/`.
class AppSettingsScreen extends ConsumerStatefulWidget {
  /// Id of the row to scroll to and flash once, set when a More-tab search hit
  /// deep-links here. Ids are the ones in `menu_search_index.dart`.
  final String? highlightId;

  const AppSettingsScreen({super.key, this.highlightId});

  @override
  ConsumerState<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends ConsumerState<AppSettingsScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  bool _searchExpanded = false;
  String _searchQuery = '';

  /// Row to flash: the one the deep link named, then whatever a local search
  /// hit points at.
  late String? _highlight = widget.highlightId;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _openSearch() {
    setState(() => _searchExpanded = true);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _searchFocus.requestFocus(),
    );
  }

  void _closeSearch() {
    _searchCtrl.clear();
    setState(() {
      _searchExpanded = false;
      _searchQuery = '';
    });
  }

  /// A hit that lives on this screen closes the search and flashes its row in
  /// place; anything else (a whole screen of its own) opens normally.
  void _openHit(MenuSearchEntry entry) {
    final settingId = entry.settingId;
    if (settingId == null) {
      entry.open(context);
      return;
    }
    _searchCtrl.clear();
    setState(() {
      _searchExpanded = false;
      _searchQuery = '';
      _highlight = settingId;
    });
  }

  Future<void> _confirmReset() async {
    var confirmed = false;
    await GlazeBottomSheet.show<void>(
      context,
      title: 'settings_reset_title'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.restart_alt_rounded,
        description: 'settings_reset_confirm'.tr(),
        buttonText: 'settings_reset_action'.tr(),
        onButtonTap: () {
          confirmed = true;
          Navigator.of(context, rootNavigator: true).pop();
        },
      ),
    );
    if (!confirmed || !mounted) return;
    await resetGlazeSettings(ref);
    if (mounted) GlazeToast.show(context, 'settings_reset_done'.tr());
  }

  Widget _buildSearchField() => TextField(
    controller: _searchCtrl,
    focusNode: _searchFocus,
    autofocus: true,
    onChanged: (value) => setState(() => _searchQuery = value),
    textInputAction: TextInputAction.search,
    cursorColor: context.cs.primary,
    style: TextStyle(color: context.cs.onSurface, fontSize: 16),
    decoration: InputDecoration(
      isDense: true,
      border: InputBorder.none,
      hintText: 'menu_search_hint'.tr(),
      hintStyle: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 16),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    // GlazeScaffold draws this screen's own header; inside the desktop
    // floating window the frame supplies the title bar instead, so the space
    // reserved for a header would be a gap.
    final topPad = DetachedShellHost.of(context)
        ? 0.0
        : MediaQuery.of(context).padding.top + 74.0;
    final bottomPad = ref.watch(navHeightProvider) + 20;
    final searching = _searchQuery.trim().isNotEmpty;

    return GlazeScaffold(
      title: _searchExpanded ? null : 'section_settings'.tr(),
      titleWidget: _searchExpanded ? _buildSearchField() : null,
      useShellHeader: true,
      headerBranchIndex: 3,
      extendBodyBehindHeader: true,
      onBack: () => context.go('/menu'),
      showBackground: false,
      actions: [
        SizedBox(
          width: 44,
          height: 44,
          child: IconButton(
            icon: Icon(
              _searchExpanded ? Icons.close_rounded : Icons.search_rounded,
              size: 22,
            ),
            color: context.cs.primary,
            onPressed: _searchExpanded ? _closeSearch : _openSearch,
          ),
        ),
      ],
      body: settingsAsync.when(
        loading: () => const Center(child: GlazeSpinner()),
        error: (e, _) => Center(child: Text('${'title_error'.tr()}: $e')),
        data: (settings) {
          final padding = EdgeInsets.fromLTRB(0, topPad + 8, 0, bottomPad);
          if (searching) {
            return MenuSearchResults(
              padding: padding,
              onTap: _openHit,
              results: filterMenuSearchEntries(
                buildSettingsSearchIndex(),
                _searchQuery,
              ),
            );
          }
          // Not a lazy ListView: a deep-linked row scrolls *itself* into view
          // when it mounts (see SettingsHighlight), and a lazy list never
          // mounts the ones below the fold. Nine groups is cheap to build.
          return SingleChildScrollView(
            padding: padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: appSettingsGroups(
                context: context,
                settings: settings,
                highlightId: _highlight,
                onReset: _confirmReset,
              ),
            ),
          );
        },
      ),
    );
  }
}
