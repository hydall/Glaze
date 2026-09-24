import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/preset.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/utils/time_helpers.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/generic_editor.dart';
import '../../../shared/widgets/list_controls.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../presets/preset_list_provider.dart';
import '../chat_provider.dart';
import '../chat_session_service.dart';
import '../../../shared/widgets/glaze_sheet.dart';

/// Keeps the Author's Note enable state in sync across its homes. The note is
/// one entity for the chat: its `enabled` (and content) live on the session and
/// are mirrored onto the `authors_note` block of every preset, so the note
/// shows consistently no matter which preset is active. Role/depth/insertion
/// mode are per-preset and are NOT touched here.
Future<void> syncAuthorsNoteEnabled(
  WidgetRef ref, {
  required String? charId,
  required bool enabled,
}) async {
  if (charId != null) {
    final session = ref.read(chatProvider(charId)).value?.session;
    final note = session?.authorsNote;
    if (session != null && note != null && note.enabled != enabled) {
      final updated = await ref
          .read(chatRepoProvider)
          .mutateAuthorsNote(
            sessionId: session.id,
            updatedAt: currentTimestampSeconds(),
            mutate: (latestNote) => latestNote?.copyWith(enabled: enabled),
          );
      if (updated != null) {
        // Keep the session cache in sync — switchToSession returns the cached
        // ChatSession without re-reading the DB, so a stale entry would mask
        // the new enabled state (and note content) until the cache is evicted.
        ChatSessionService.updateCache(updated);
        ref.invalidate(chatProvider(charId));
      }
    }
  }
  final presets = ref.read(presetListProvider).value ?? const [];
  for (final preset in presets) {
    final idx = preset.blocks.indexWhere((b) => b.id == 'authors_note');
    if (idx == -1 || preset.blocks[idx].enabled == enabled) continue;
    final blocks = List<PresetBlock>.from(preset.blocks)
      ..[idx] = preset.blocks[idx].copyWith(enabled: enabled);
    await ref
        .read(presetListProvider.notifier)
        .updatePreset(preset.copyWith(blocks: blocks));
  }
}

class AuthorsNoteSheet extends ConsumerStatefulWidget {
  /// Author's note content + enabled live on the chat session, so a chat must
  /// be active to edit them. When [charId] is null (e.g. the sheet is opened
  /// from the preset editor outside a chat) the body shows a hint instead.
  /// Role / insertion / depth are per-preset: they are edited here too, on the
  /// `authors_note` block of the preset this chat resolves to, so the whole
  /// note is configured in one place.
  final String? charId;

  /// The preset whose block the injection settings edit, when the sheet is
  /// opened from an editor that already has one open. Left null in a chat, the
  /// sheet follows the preset that chat resolves to.
  final String? presetId;
  const AuthorsNoteSheet({super.key, this.charId, this.presetId});

  @override
  ConsumerState<AuthorsNoteSheet> createState() => _AuthorsNoteSheetState();
}

class _AuthorsNoteSheetState extends ConsumerState<AuthorsNoteSheet> {
  late Map<String, dynamic> _localItem;
  late bool _enabled;
  late final bool _hasSession;
  // Captured while the element is active so _performSave can still read
  // providers when invoked from GenericEditor.dispose() — by then ref.read
  // throws "Looking up a deactivated widget's ancestor is unsafe".
  //
  // Not `late final`: didChangeDependencies runs again whenever an inherited
  // widget above this one changes — opening a route over the sheet is enough —
  // and a second assignment to a late final field throws.
  late ProviderContainer _container;

  /// Local echo of the injection settings, so a change shows immediately
  /// instead of waiting for the preset list to reload after the write.
  /// Scoped to [_editedPresetId] — a different preset resolving under the
  /// sheet drops them and the block's own values are shown again.
  String? _editedPresetId;
  String? _role;
  String? _insertionMode;
  int? _depth;

  /// The write behind the settings above. The depth slider reports every tick,
  /// so its writes are coalesced instead of putting the whole preset once per
  /// notch; a picker flushes straight away.
  Timer? _blockSaveTimer;
  Preset? _pendingBlockPreset;
  PresetBlock? _pendingBlock;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container = ProviderScope.containerOf(context);
  }

  @override
  void initState() {
    super.initState();
    final session = widget.charId == null
        ? null
        : ref.read(chatProvider(widget.charId!)).value?.session;
    _hasSession = session != null;
    final note = session?.authorsNote;

    _enabled = note?.enabled ?? true;
    _localItem = {'content': note?.content ?? ''};
  }

  /// Toggle handler: persist the session note (via [_performSave], which writes
  /// the current [_enabled]) and mirror the new state onto every preset's block.
  void _setEnabled(bool v) {
    _performSave(_localItem);
    syncAuthorsNoteEnabled(ref, charId: null, enabled: v);
  }

  Future<void> _performSave(Map<String, dynamic> item) async {
    if (widget.charId == null) return;
    // Use the captured container, not ref — this method can be called from
    // GenericEditor.dispose() when the element is already deactivated.
    final session = _container
        .read(chatProvider(widget.charId!))
        .value
        ?.session;
    if (session == null) return;

    final content = (item['content'] as String?)?.trim() ?? '';
    // Preserve the session note's existing role/depth/insertion fields — they
    // are unused at runtime (preset-owned) but kept for backward compatibility.
    final updated = await _container
        .read(chatRepoProvider)
        .mutateAuthorsNote(
          sessionId: session.id,
          updatedAt: currentTimestampSeconds(),
          mutate: (existing) => content.isNotEmpty
              ? AuthorsNote(
                  content: content,
                  role: existing?.role ?? 'system',
                  insertionMode: existing?.insertionMode ?? 'relative',
                  depth: existing?.depth ?? 0,
                  enabled: _enabled,
                )
              : null,
        );
    if (updated == null) return;
    // Keep the session cache in sync — switchToSession returns the cached
    // ChatSession without re-reading the DB, so a stale entry would mask the
    // edited note content until the cache is evicted.
    ChatSessionService.updateCache(updated);
    _container.invalidate(chatProvider(widget.charId!));
  }

  List<GenericEditorSection> get _config => [
    GenericEditorSection(
      fields: [
        GenericEditorField(
          key: 'content',
          label: 'label_content'.tr(),
          type: 'textarea',
          placeholder: 'authors_note_placeholder'.tr(),
          rows: 6,
        ),
      ],
    ),
  ];

  /// The preset whose `authors_note` block the injection settings edit: the
  /// one this chat resolves to (chat binding → character binding → global
  /// active → first). Outside a chat there is no binding to follow, so the
  /// globally active preset is the one on screen.
  Preset? _effectivePreset() {
    final presets = ref.watch(presetListProvider).value;
    if (presets == null) return null;
    final pinned = widget.presetId;
    if (pinned != null) {
      return presets.where((p) => p.id == pinned).firstOrNull;
    }
    final charId = widget.charId;
    final sessionId = charId == null
        ? null
        : ref.watch(chatProvider(charId)).value?.session?.id;
    return getEffectivePreset(
      presets,
      charId,
      sessionId,
      ref.watch(activePresetIdProvider),
      ref.watch(presetConnectionsProvider),
    );
  }

  /// The block as it is shown: the stored one, with a just-made edit layered
  /// on top while the preset list reloads.
  PresetBlock _displayedBlock(Preset preset, PresetBlock stored) {
    if (_editedPresetId != preset.id) return stored;
    return stored.copyWith(
      role: _role ?? stored.role,
      insertionMode: _insertionMode ?? stored.insertionMode,
      depth: _depth ?? stored.depth,
    );
  }

  /// Writes role / insertion mode / depth onto the resolved preset's
  /// `authors_note` block. Content and enable are session-scoped and go
  /// through [_performSave] / [syncAuthorsNoteEnabled] instead.
  Future<void> _saveBlock(
    Preset preset, {
    String? role,
    String? insertionMode,
    int? depth,
    bool debounce = false,
  }) async {
    final index = preset.blocks.indexWhere((b) => b.id == 'authors_note');
    if (index == -1) return;
    final current = preset.blocks[index];
    // Layer the edit over what is on screen, not over the stored block: a
    // second change made before the list has reloaded would otherwise write
    // the first one back to its old value.
    final shown = _displayedBlock(preset, current);
    final updated = current.copyWith(
      role: role ?? shown.role,
      insertionMode: insertionMode ?? shown.insertionMode,
      depth: depth ?? shown.depth,
    );
    if (updated == current) return;
    setState(() {
      _editedPresetId = preset.id;
      _role = updated.role;
      _insertionMode = updated.insertionMode;
      _depth = updated.depth;
    });
    _pendingBlockPreset = preset;
    _pendingBlock = updated;
    _blockSaveTimer?.cancel();
    if (debounce) {
      _blockSaveTimer = Timer(
        const Duration(milliseconds: 400),
        _flushBlockSave,
      );
      return;
    }
    await _flushBlockSave();
  }

  /// Writes the block edit that is waiting, if any. Goes through the captured
  /// container rather than `ref`: it also runs from [dispose], when the sheet
  /// is closed on the same frame as the last change.
  Future<void> _flushBlockSave() async {
    _blockSaveTimer?.cancel();
    _blockSaveTimer = null;
    final preset = _pendingBlockPreset;
    final block = _pendingBlock;
    _pendingBlockPreset = null;
    _pendingBlock = null;
    if (preset == null || block == null) return;
    final index = preset.blocks.indexWhere((b) => b.id == 'authors_note');
    if (index == -1) return;
    final blocks = List<PresetBlock>.from(preset.blocks)..[index] = block;
    await _container
        .read(presetListProvider.notifier)
        .updatePreset(preset.copyWith(blocks: blocks));
  }

  @override
  void dispose() {
    _flushBlockSave();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preset = _effectivePreset();
    final block = preset?.blocks
        .where((b) => b.id == 'authors_note')
        .firstOrNull;

    return SheetView(
      title: 'magic_authors_notes'.tr(),
      showBack: true,
      actions: _hasSession
          ? [
              SheetViewAction(
                icon: Switch(
                  value: _enabled,
                  onChanged: (v) {
                    setState(() => _enabled = v);
                    _setEnabled(v);
                  },
                  activeThumbColor: context.cs.primary,
                ),
                onPressed: () {
                  setState(() => _enabled = !_enabled);
                  _setEnabled(_enabled);
                },
              ),
            ]
          : const [],
      // Builder, not this build's `context`: SheetView reports its measured
      // header height as MediaQuery padding to its body subtree only.
      body: Builder(
        builder: (innerContext) => ListView(
          padding: EdgeInsets.only(
            top: MediaQuery.paddingOf(innerContext).top + 4,
            bottom: MediaQuery.paddingOf(innerContext).bottom + 24,
          ),
          children: [
            if (_hasSession)
              GenericEditor(
                item: _localItem,
                config: _config,
                onChanged: (val) => setState(() => _localItem = val),
                onSave: _performSave,
                useWindows: false,
                scrollable: false,
              )
            else
              _buildNoSessionHint(),
            if (preset != null && block != null)
              _buildInjectionGroup(preset, block),
          ],
        ),
      ),
    );
  }

  /// Role / insertion mode / depth of the current preset's `authors_note`
  /// block. They used to be reachable only from the preset editor, which split
  /// one note across two screens; the group's hint spells out that these belong
  /// to the preset, not to the chat.
  Widget _buildInjectionGroup(Preset preset, PresetBlock stored) {
    final block = _displayedBlock(preset, stored);
    return MenuGroup(
      header: 'label_injection_point'.tr(),
      description: 'authors_note_role_hint'.tr(
        namedArgs: {'preset': preset.name},
      ),
      items: [
        MenuSelectorItem(
          label: 'label_role'.tr(),
          currentValue: _roleLabel(block.role),
          onTap: () => _pickRole(preset, block),
        ),
        MenuSelectorItem(
          label: 'label_insertion'.tr(),
          currentValue: _insertionLabel(block.insertionMode),
          onTap: () => _pickInsertion(preset, block),
        ),
        if (block.insertionMode == 'depth')
          MenuRangeItem(
            label: 'label_depth'.tr(),
            value: (block.depth ?? 1).toDouble(),
            min: 1,
            max: 20,
            divisions: 19,
            decimalPlaces: 0,
            editableValue: true,
            onChanged: (v) =>
                _saveBlock(preset, depth: v.round(), debounce: true),
          ),
      ],
    );
  }

  static String _roleLabel(String role) => switch (role) {
    'user' => 'User',
    'assistant' => 'Assistant',
    _ => 'System',
  };

  static String _insertionLabel(String mode) =>
      mode == 'depth' ? 'injection_depth'.tr() : 'injection_relative'.tr();

  void _pickRole(Preset preset, PresetBlock block) {
    showGlazePickerSheet(
      context,
      title: 'label_role'.tr(),
      items: [
        for (final role in const ['system', 'user', 'assistant'])
          GlazePickerItem(
            label: _roleLabel(role),
            isActive: block.role == role,
            value: role,
          ),
      ],
      onSelect: (value) => _saveBlock(preset, role: value as String),
    );
  }

  void _pickInsertion(Preset preset, PresetBlock block) {
    showGlazePickerSheet(
      context,
      title: 'label_insertion'.tr(),
      items: [
        for (final mode in const ['relative', 'depth'])
          GlazePickerItem(
            label: _insertionLabel(mode),
            isActive: block.insertionMode == mode,
            value: mode,
          ),
      ],
      onSelect: (value) => _saveBlock(
        preset,
        insertionMode: value as String,
        // A block that has never been placed at depth carries none; start it
        // at 1 so the slider has something to show.
        depth: value == 'depth' ? (block.depth ?? 1) : null,
      ),
    );
  }

  Widget _buildNoSessionHint() {
    return const Padding(
      padding: EdgeInsets.fromLTRB(32, 40, 32, 24),
      child: _NoSessionHint(),
    );
  }
}

/// Shown in place of the content editor outside a chat: the note's text lives
/// on the session, while the injection settings under it do not and stay
/// editable.
class _NoSessionHint extends StatelessWidget {
  const _NoSessionHint();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.chat_bubble_outline,
          size: 40,
          color: context.cs.onSurfaceVariant.withValues(alpha: 0.6),
        ),
        const SizedBox(height: 16),
        Text(
          "Author's note content is tied to a chat.\n"
          'Open a chat to edit it.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.4,
            color: context.cs.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

Future<void> showAuthorsNoteSheet(
  BuildContext context,
  String? charId, {
  String? presetId,
}) {
  return showGlazeSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => AuthorsNoteSheet(charId: charId, presetId: presetId),
  );
}
