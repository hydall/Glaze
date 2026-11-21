import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/folder.dart';
import '../../core/models/persona.dart';
import '../../core/services/persona_character_converter.dart';
import '../../core/state/active_selection_provider.dart';
import '../../core/state/folder_provider.dart';
import '../../core/utils/platform_paths.dart';
import '../../shared/shell/desktop/sidebar_sheet_provider.dart';
import '../../shared/state/preset_sort.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/folder_section.dart';
import '../../shared/widgets/glaze_action_button.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_list_item.dart';
import '../../shared/widgets/glaze_list_screen.dart';
import '../../shared/widgets/glaze_sheet.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/help_tip.dart';
import '../guides/guide_anchor.dart';
import '../guides/guide_service.dart';
import 'persona_connections_sheet.dart';
import 'persona_editor.dart';
import 'persona_list_controls.dart';
import 'persona_list_provider.dart';

export 'persona_editor.dart' show PersonaEditorWindow, openPersonaEditor;

class PersonaListScreen extends ConsumerStatefulWidget {
  final bool startExpanded;

  /// Opened from a chat: the active row is the persona that chat speaks as,
  /// and picking one rebinds the chat when a binding of its own or its
  /// character's overrides the global persona. Follows [lastOpenChatProvider],
  /// so a sidebar panel kept open across a session switch stays on the chat.
  final bool forChat;

  const PersonaListScreen({
    super.key,
    this.startExpanded = false,
    this.forChat = false,
  });

  @override
  ConsumerState<PersonaListScreen> createState() => _PersonaListScreenState();
}

/// The persona open in the list's place: an existing one, or a new one.
class _EditTarget {
  final Persona? persona;
  const _EditTarget(this.persona);
}

class _PersonaListScreenState extends ConsumerState<PersonaListScreen> {
  /// Folder currently being browsed, or null at the top level.
  String? _currentFolderId;

  /// The editor open in the list's place, as the Presets list opens its
  /// editor: inside the same sheet, never as a page over it.
  _EditTarget? _editing;
  Key _editorKey = UniqueKey();

  PersonaListFilters _filters = const PersonaListFilters();
  bool _reorderArmed = false;

  /// Selected persona ids while multi-selecting. Empty = not selecting.
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) maybeShowGuide(context, AppGuide.personas);
    });
  }

  // ── Navigation ─────────────────────────────────────────────────────────────

  void _openFolder(String id) => setState(() {
    _selected.clear();
    _currentFolderId = id;
  });

  void _leaveFolder() => setState(() {
    _selected.clear();
    _currentFolderId = null;
  });

  void _openEditor([Persona? persona]) => setState(() {
    _selected.clear();
    _editing = _EditTarget(persona);
    _editorKey = UniqueKey();
  });

  void _closeEditor() => setState(() => _editing = null);

  /// Unwinds one level per press — the editor, the selection, the folder —
  /// and only then leaves the screen.
  void _handleBack() {
    if (_editing != null) {
      _closeEditor();
      return;
    }
    if (_selected.isNotEmpty) {
      setState(_selected.clear);
      return;
    }
    if (_currentFolderId != null) {
      _leaveFolder();
      return;
    }
    if (widget.startExpanded) {
      closeExpandedToolScreen(context, ref);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  String? _folderName(String id) {
    final folders = ref.watch(foldersProvider(FolderDomain.persona)).value;
    return folders?.where((f) => f.id == id).firstOrNull?.name;
  }

  // ── Selection / reorder ────────────────────────────────────────────────────

  void _startSelection(String id) => setState(() {
    _reorderArmed = false;
    _selected.add(id);
  });

  void _toggleSelected(String id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  void _toggleReorderArmed() {
    final armed = !_reorderArmed;
    setState(() {
      _reorderArmed = armed;
      if (armed) _selected.clear();
    });
    if (armed) showGlazeDragHint(context);
  }

  void _onManualReorder(
    List<Persona> visible,
    List<Persona> all,
    int oldIndex,
    int newIndex,
  ) {
    if (oldIndex == newIndex) return;
    final sort = ref.read(personaSortProvider).value ?? const PresetSortState();
    final order = manualOrderAfterDrag(
      all: all,
      visible: visible,
      oldIndex: oldIndex,
      newIndex: newIndex,
      state: sort,
      idOf: (p) => p.id,
      nameOf: personaListName,
      createdAtOf: (p) => p.createdAt,
    );
    unawaited(ref.read(personaSortProvider.notifier).setManualOrder(order));
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  Widget _titleText(String text, {bool help = false}) => Row(
    children: [
      Flexible(
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: context.cs.onSurface,
          ),
        ),
      ),
      if (help) const HelpTip(term: 'persona'),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final editing = _editing;
    final folderId = _currentFolderId;
    final sort =
        ref.watch(personaSortProvider).value ?? const PresetSortState();

    return GlazeListScreen(
      startExpanded: widget.startExpanded,
      title: editing != null ? personaEditorTitle(editing.persona) : null,
      titleWidget: editing != null
          ? null
          : folderId != null
          ? _titleText(_folderName(folderId) ?? 'menu_personas'.tr())
          : _titleText('menu_personas'.tr(), help: true),
      canPop: editing == null && _selected.isEmpty && folderId == null,
      onBack: _handleBack,
      addLabel: "${'create_new'.tr()} ${'tab_personas'.tr()}",
      onAdd: () => _showAddMenu(context),
      decorateAdd: (child) =>
          GuideAnchor(id: GuideIds.personasAdd, child: child),
      controls: GlazeListControls(
        filterCount: _filters.activeCount,
        onFilter: () => _showFilterSheet(context),
        sort: GlazeListSort(
          mode: sort.mode,
          armed: _reorderArmed,
          onToggleReorder: _toggleReorderArmed,
          onSelect: (mode) =>
              unawaited(ref.read(personaSortProvider.notifier).setMode(mode)),
          onDisarm: () {
            if (_reorderArmed) setState(() => _reorderArmed = false);
          },
        ),
      ),
      selection: _selected.isEmpty
          ? null
          : GlazeListSelection(
              count: _selected.length,
              onCancel: () => setState(_selected.clear),
              onMore: () => _showSelectionActions(context),
            ),
      editing: editing != null,
      body: editing != null
          ? PersonaEditorBody(key: _editorKey, existing: editing.persona)
          : ref
                .watch(personaListProvider)
                .when(
                  skipLoadingOnReload: true,
                  loading: () => const Center(child: GlazeSpinner()),
                  error: (e, _) =>
                      Center(child: Text("${'title_error'.tr()}: $e")),
                  data: (all) => Builder(
                    builder: (context) => _buildList(context, all, sort),
                  ),
                ),
    );
  }

  Widget _buildList(
    BuildContext context,
    List<Persona> all,
    PresetSortState sort,
  ) {
    final folderId = _currentFolderId;
    final memberships =
        ref.watch(folderMembershipsProvider(FolderDomain.persona)).value ??
        FolderMemberships.empty;
    final hasFolders =
        (ref.watch(foldersProvider(FolderDomain.persona)).value ?? const [])
            .isNotEmpty;
    final connections = ref.watch(personaConnectionsProvider);
    final boundIds = {
      ...connections.character.values,
      ...connections.chat.values,
    };

    var list = folderId != null
        ? all
              .where((p) => memberships.membersIn(folderId).contains(p.id))
              .toList()
        // A persona filed into a folder lives there, not twice.
        : all.where((p) => memberships.foldersOf(p.id).isEmpty).toList();
    list = list
        .where((p) => _filters.matches(isBound: boundIds.contains(p.id)))
        .toList();
    list = sortPersonas(list, sort);

    final chatKey = widget.forChat ? ref.watch(lastOpenChatProvider) : null;
    final activeId = _activePersonaId(all, chatKey);
    final reordering = sort.mode == PresetSortMode.manual && _reorderArmed;
    final selecting = _selected.isNotEmpty;

    final header = <Widget>[
      if (folderId == null)
        FolderSection(
          domain: FolderDomain.persona,
          onOpenFolder: _openFolder,
          icon: Icons.person_outline,
        ),
      if (list.isEmpty)
        if (_filters.isActive)
          GlazeListEmptyNote(label: 'search_no_results'.tr())
        else if (folderId != null)
          const FolderEmptyState()
        else if (!hasFolders)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Column(
              children: [
                Text(
                  'no_results'.tr(),
                  style: TextStyle(color: context.cs.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                GlazeActionButton(
                  icon: Icons.add_rounded,
                  label: "${'create_new'.tr()} ${'tab_personas'.tr()}",
                  tone: GlazeActionTone.primary,
                  onTap: _openEditor,
                ),
              ],
            ),
          ),
    ];

    return GlazeListBody(
      levelKey: 'personas_${folderId ?? '#root'}',
      header: header,
      itemCount: list.length,
      itemKey: (i) => list[i].id,
      onReorder: reordering
          ? (oldIndex, newIndex) =>
                _onManualReorder(list, all, oldIndex, newIndex)
          : null,
      dragByLongPress: true,
      itemBuilder: (context, i) {
        final persona = list[i];
        final isActive = persona.id == activeId;
        return GuideAnchor(
          id: i == 0 ? GuideIds.personasRow : null,
          child: _PersonaRow(
            persona: persona,
            isActive: isActive,
            selecting: selecting,
            selected: _selected.contains(persona.id),
            onTap: selecting
                ? () => _toggleSelected(persona.id)
                : () => selectPersonaFor(
                    ref,
                    chatKey,
                    isActive ? null : persona.id,
                  ),
            onLongPress: reordering || selecting
                ? null
                : () => _startSelection(persona.id),
            onEdit: () => _openEditor(persona),
            onMore: () => _showPersonaMenu(context, persona),
            onConnections: () => showPersonaConnections(context, persona.id),
          ),
        );
      },
    );
  }

  /// The persona marked active: the one the chat speaks as when a binding
  /// decides it, otherwise the global selection.
  String? _activePersonaId(
    List<Persona> personas,
    EffectivePersonaChatKey? key,
  ) {
    final globalId = ref.watch(activePersonaIdProvider);
    if (key == null) return globalId;
    final connections = ref.watch(personaConnectionsProvider);
    if (!hasPersonaBinding(personas, connections, key)) return globalId;
    return getEffectivePersona(
      personas,
      key.charId,
      key.sessionId,
      globalId,
      connections,
    )?.id;
  }

  // ── Sheets ─────────────────────────────────────────────────────────────────

  void _showFilterSheet(BuildContext context) {
    showGlazeSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PersonaFilterSheet(
        filters: _filters,
        onApply: (f) {
          if (mounted) setState(() => _filters = f);
        },
      ),
    );
  }

  void _showAddMenu(BuildContext context) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'menu_personas'.tr(),
      items: [
        BottomSheetItem(
          label: "${'create_new'.tr()} ${'tab_personas'.tr()}",
          icon: Icons.add,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _openEditor();
          },
        ),
        BottomSheetItem(
          icon: Icons.create_new_folder_rounded,
          label: 'folder_new'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            showCreateFolderDialog(context, ref, FolderDomain.persona);
          },
        ),
      ],
    );
  }

  void _showPersonaMenu(BuildContext context, Persona persona) {
    GlazeBottomSheet.show<void>(
      context,
      title: personaListName(persona),
      items: [
        BottomSheetItem(
          label: 'action_add_to_folder'.tr(),
          icon: Icons.create_new_folder_outlined,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            showAddToFolderSheet(
              context,
              domain: FolderDomain.persona,
              targets: [persona.id],
            );
          },
        ),
        BottomSheetItem(
          label: 'action_clone_persona'.tr(),
          icon: Icons.copy_outlined,
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            await ref.read(personaListProvider.notifier).clone(persona);
          },
        ),
        BottomSheetItem(
          label: 'action_convert_to_character'.tr(),
          icon: Icons.person_outline,
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            await convertPersonaToCharacter(ref, persona);
            if (!context.mounted) return;
            GlazeToast.show(context, 'convert_to_character_done'.tr());
          },
        ),
        BottomSheetItem(
          label: 'action_delete'.tr(),
          icon: Icons.delete,
          isDestructive: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _deletePersonas([persona.id]);
          },
        ),
      ],
    );
  }

  void _showSelectionActions(BuildContext context) {
    final folderId = _currentFolderId;
    final ids = _selected.toList();
    GlazeBottomSheet.show<void>(
      context,
      title: '${ids.length} ${'selected_count'.tr()}',
      items: [
        BottomSheetItem(
          icon: Icons.create_new_folder_outlined,
          label: 'action_add_to_folder'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            showAddToFolderSheet(
              context,
              domain: FolderDomain.persona,
              targets: ids,
              onDone: () {
                if (mounted) setState(_selected.clear);
              },
            );
          },
        ),
        if (folderId != null)
          BottomSheetItem(
            icon: Icons.folder_off_outlined,
            label: 'action_remove_from_folder'.tr(),
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              final repo = ref.read(folderRepoProvider);
              for (final id in ids) {
                unawaited(repo.removeMember(folderId, id));
              }
              setState(_selected.clear);
            },
          ),
        BottomSheetItem(
          icon: Icons.delete_rounded,
          label: 'action_delete'.tr(),
          isDestructive: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _confirmDeleteSelected(context, ids);
          },
        ),
      ],
    );
  }

  void _confirmDeleteSelected(BuildContext context, List<String> ids) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'action_delete'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description: 'persona_delete_selected_confirm'.tr(
          args: ['${ids.length}'],
        ),
      ),
      items: [
        BottomSheetItem(
          label: 'btn_delete'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            setState(_selected.clear);
            _deletePersonas(ids);
          },
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }

  void _deletePersonas(List<String> ids) {
    final notifier = ref.read(personaListProvider.notifier);
    final folders = ref.read(folderRepoProvider);
    for (final id in ids) {
      unawaited(notifier.remove(id));
      unawaited(folders.deleteMembersForMember(FolderDomain.persona, id));
    }
  }
}

class _PersonaRow extends StatelessWidget {
  final Persona persona;
  final bool isActive;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback onEdit;
  final VoidCallback onMore;
  final VoidCallback onConnections;

  const _PersonaRow({
    required this.persona,
    required this.isActive,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onEdit,
    required this.onMore,
    required this.onConnections,
  });

  @override
  Widget build(BuildContext context) {
    final displayName = personaListName(persona);
    final rawAvatarPath = persona.avatarPath?.trim();
    final avatarPath = (rawAvatarPath != null && rawAvatarPath.isNotEmpty)
        ? resolveGlazeFilePath(rawAvatarPath)
        : null;
    final hasAvatar = avatarPath != null && avatarPath.isNotEmpty;
    final prompt = persona.prompt;

    return GlazeListItem(
      isActive: isActive,
      selected: selected,
      onTap: onTap,
      onLongPress: onLongPress,
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: context.cs.primary.withValues(alpha: 0.18),
        backgroundImage: hasAvatar ? FileImage(File(avatarPath)) : null,
        child: hasAvatar
            ? null
            : Text(
                displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: context.cs.onSurface,
                ),
              ),
      ),
      title: displayName,
      subtitle: prompt != null && prompt.isNotEmpty
          ? prompt.replaceAll('\n', ' ')
          : 'no_prompt'.tr(),
      trailing: selecting
          ? GlazeSelectionCheck(selected: selected)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(
                    Icons.link,
                    size: 18,
                    color: context.cs.onSurfaceVariant,
                  ),
                  tooltip: 'header_connections'.tr(),
                  onPressed: onConnections,
                ),
                IconButton(
                  icon: Icon(
                    Icons.edit_outlined,
                    size: 18,
                    color: context.cs.onSurfaceVariant,
                  ),
                  tooltip: 'action_edit'.tr(),
                  onPressed: onEdit,
                ),
                GlazeListMenuButton(onTap: onMore),
              ],
            ),
    );
  }
}
