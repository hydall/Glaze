import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';

import '../../../core/models/persona.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/character_provider.dart';
import '../../../core/state/chat_session_ops_provider.dart';
import '../../../features/personas/persona_list_provider.dart';
import '../../../shared/widgets/connection_sheet_widgets.dart';
import '../../../shared/widgets/help_tip.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';

class PersonaConnectionsSheet extends ConsumerStatefulWidget {
  final String personaId;
  const PersonaConnectionsSheet({super.key, required this.personaId});

  @override
  ConsumerState<PersonaConnectionsSheet> createState() =>
      _PersonaConnectionsSheetState();
}

class _PersonaConnectionsSheetState
    extends ConsumerState<PersonaConnectionsSheet> {
  @override
  Widget build(BuildContext context) {
    final personaListAsync = ref.watch(personaListProvider);
    final connections = ref.watch(personaConnectionsProvider);
    final activePersonaId = ref.watch(activePersonaIdProvider);
    final isGlobal = activePersonaId == widget.personaId;

    final charIds = connections.character.entries
        .where((e) => e.value == widget.personaId)
        .map((e) => e.key)
        .toList();
    final chatIds = connections.chat.entries
        .where((e) => e.value == widget.personaId)
        .map((e) => e.key)
        .toList();

    return personaListAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(child: Text("${'title_error'.tr()}: $error")),
      data: (personas) {
        final persona = personas.where((p) => p.id == widget.personaId).firstOrNull ?? Persona(id: widget.personaId, name: 'tab_personas'.tr());

        return SheetView(
          titleWidget: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  "${'header_connections'.tr()}: ${persona.name}",
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const HelpTip(term: 'connections'),
            ],
          ),
          showBack: true,
          fitContent: true,
          // Builder so `MediaQuery.paddingOf` reads the inset SheetView injects
          // *inside* itself (real safe-area top + floating header height). Using
          // the outer state `context` here would only see the safe-area top, so
          // the floating title overlapped the first section.
          body: Builder(
            builder: (context) => ListView(
            shrinkWrap: true,
            padding: EdgeInsets.only(
              top: MediaQuery.paddingOf(context).top + 4,
              bottom: 16 + MediaQuery.paddingOf(context).bottom,
            ),
            children: [
              ConnectionSection(
                icon: Icons.public,
                title: 'label_global'.tr(),
                child: ConnectionToggleRow(
                  label: 'label_global_enabled'.tr(),
                  value: isGlobal,
                  onChanged: (v) {
                    setActivePersona(ref, v ? widget.personaId : null);
                  },
                ),
              ),
              ConnectionSection(
                icon: Icons.person,
                title: 'header_characters'.tr(),
                onAdd: () => _addCharacterConnection(),
                child: charIds.isEmpty
                    ? ConnectionEmptyHint('no_char_connections'.tr())
                    : Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: charIds
                            .map((id) => ConnectionChip(
                                  id: id,
                                  futureLabel: _charName(id),
                                  onRemove: () => setPersonaConnection(
                                    ref, 'character', id, null,
                                  ),
                                ))
                            .toList(),
                      ),
              ),
              ConnectionSection(
                icon: Icons.chat,
                title: 'tab_dialogs'.tr(),
                onAdd: () => _addChatConnection(),
                child: chatIds.isEmpty
                    ? ConnectionEmptyHint('no_chat_connections'.tr())
                    : Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: chatIds
                            .map((id) => ConnectionChip(
                                  id: id,
                                  futureLabel: _chatLabel(id),
                                  onRemove: () => setPersonaConnection(
                                    ref, 'chat', id, null,
                                  ),
                                ))
                            .toList(),
                      ),
              ),
            ],
            ),
          ),
        );
      },
    );
  }

  Future<String> _charName(String id) async {
    final chars = ref.read(charactersProvider).value ?? [];
    final c = chars.where((c) => c.id == id).firstOrNull;
    return c?.name ?? id;
  }

  Future<String> _chatLabel(String sessionId) async {
    final sessions = ref.read(chatSessionOpsProvider).value ?? [];
    final s = sessions.where((s) => s.id == sessionId).firstOrNull;
    if (s == null) return sessionId;
    final chars = ref.read(charactersProvider).value ?? [];
    final char = chars.where((c) => c.id == s.characterId).firstOrNull;
    return '${char?.name ?? s.characterId} #${s.sessionIndex}';
  }

  void _addCharacterConnection() async {
    final chars = ref.read(charactersProvider).value ?? [];
    final connections = ref.read(personaConnectionsProvider);
    final existingIds = connections.character.entries
        .where((e) => e.value == widget.personaId)
        .map((e) => e.key)
        .toSet();

    final available =
        chars.where((c) => !existingIds.contains(c.id)).toList();
    if (available.isEmpty) {
      GlazeToast.show(
        context,
        "${'header_characters'.tr()}: ${'preset_selected'.tr()}",
      );
      return;
    }

    final selected = await GlazeBottomSheet.show<dynamic>(
      context,
      title: "${'header_connections'.tr()} ${'sheet_title_char_options'.tr()}",
      items: available
          .map((c) => BottomSheetItem(
                label: c.name,
                onTap: () => Navigator.of(context, rootNavigator: true).pop(c),
              ))
          .toList(),
    );

    if (selected != null) {
      await setPersonaConnection(ref, 'character', selected.id as String, widget.personaId);
    }
  }

  void _addChatConnection() async {
    final sessions = ref.read(chatSessionOpsProvider).value ?? [];
    final connections = ref.read(personaConnectionsProvider);
    final existingIds = connections.chat.entries
        .where((e) => e.value == widget.personaId)
        .map((e) => e.key)
        .toSet();

    final available =
        sessions.where((s) => !existingIds.contains(s.id)).toList();
    if (available.isEmpty) {
      GlazeToast.show(context, 'no_sessions'.tr());
      return;
    }

    final chars = ref.read(charactersProvider).value ?? [];

    final selected = await GlazeBottomSheet.show<dynamic>(
      context,
      title: "${'header_connections'.tr()} ${'tab_dialogs'.tr()}",
      items: available
          .map((s) {
        final char = chars.where((c) => c.id == s.characterId).firstOrNull;
        return BottomSheetItem(
          label: '${char?.name ?? s.characterId} #${s.sessionIndex}',
          onTap: () => Navigator.of(context, rootNavigator: true).pop(s),
        );
      }).toList(),
    );

    if (selected != null) {
      await setPersonaConnection(ref, 'chat', selected.id as String, widget.personaId);
    }
  }
}

void showPersonaConnections(BuildContext context, String personaId) {
  showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => PersonaConnectionsSheet(personaId: personaId),
  );
}
