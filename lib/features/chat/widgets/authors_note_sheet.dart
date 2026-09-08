import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/preset.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/utils/time_helpers.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/generic_editor.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../presets/preset_list_provider.dart';
import '../chat_provider.dart';
import '../chat_session_service.dart';

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
  /// Role / depth / insertion mode are per-preset and edited in the preset.
  final String? charId;
  const AuthorsNoteSheet({super.key, this.charId});

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
  late final ProviderContainer _container;

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
        GenericEditorField(
          key: '__roleHint',
          label: '',
          type: 'info',
          text: 'authors_note_role_hint'.tr(),
        ),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
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
      body: _hasSession
          ? Builder(
              builder: (innerContext) => GenericEditor(
                item: _localItem,
                config: _config,
                onChanged: (val) => setState(() => _localItem = val),
                onSave: _performSave,
                useWindows: false,
                padding: EdgeInsets.only(
                  top: MediaQuery.paddingOf(innerContext).top + 4,
                  bottom: MediaQuery.paddingOf(innerContext).bottom + 24,
                ),
              ),
            )
          : _buildNoSessionHint(context),
    );
  }

  Widget _buildNoSessionHint(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        32,
        40,
        32,
        MediaQuery.paddingOf(context).bottom + 40,
      ),
      child: Column(
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
      ),
    );
  }
}

Future<void> showAuthorsNoteSheet(BuildContext context, String? charId) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => AuthorsNoteSheet(charId: charId),
  );
}
