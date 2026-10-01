import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/persona.dart';
import '../../core/state/active_selection_provider.dart';
import '../../core/state/db_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/utils/avatar_image.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/glaze_action_button.dart';
import '../../shared/widgets/glaze_scaffold.dart';
import '../personas/persona_list_provider.dart';
import 'models/vn_document.dart';
import 'vn_provider.dart';

/// Starts a novel: who the player is, then the idea, written at length in a
/// full-height editor. Creating files the novel in the chat list and opens
/// it, where the setup passes are written.
class VnNewScreen extends ConsumerStatefulWidget {
  const VnNewScreen({super.key});

  @override
  ConsumerState<VnNewScreen> createState() => _VnNewScreenState();
}

/// Headings the player can drop into the idea to describe it piece by piece.
const List<String> _kSectionKeys = [
  'vn_section_genre',
  'vn_section_setting',
  'vn_section_hero',
  'vn_section_characters',
  'vn_section_tone',
  'vn_section_start',
];

class _VnNewScreenState extends ConsumerState<VnNewScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  // Null until the player picks; then the persona id, or '' for none.
  String? _personaId;
  bool _creating = false;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Adds "Heading: " on a line of its own at the cursor.
  void _insertSection(String key) {
    final text = _controller.text;
    final sel = _controller.selection;
    final at = sel.isValid ? sel.start : text.length;
    final before = text.substring(0, at);
    final lead = before.isEmpty || before.endsWith('\n') ? '' : '\n';
    final insert = '$lead${key.tr()}: ';
    final end = sel.isValid ? sel.end : text.length;
    _controller.value = TextEditingValue(
      text: text.replaceRange(at, end, insert),
      selection: TextSelection.collapsed(offset: at + insert.length),
    );
    _focus.requestFocus();
  }

  Persona? _selected(List<Persona> personas) {
    final id = _personaId ?? ref.read(activePersonaIdProvider) ?? '';
    return personas.where((p) => p.id == id).firstOrNull;
  }

  Future<void> _create(List<Persona> personas) async {
    if (_creating) return;
    setState(() => _creating = true);
    final persona = _selected(personas);
    final router = GoRouter.of(context);
    final sessionId = await createVnSession(
      ref.read(chatRepoProvider),
      _controller.text,
      personaId: persona?.id,
      persona: persona == null
          ? null
          : VnPersona(
              name: (persona.displayName?.trim().isNotEmpty ?? false)
                  ? persona.displayName!.trim()
                  : persona.name,
              description: persona.prompt?.trim() ?? '',
            ),
    );
    if (!mounted) return;
    unawaited(router.pushReplacement('/vn/$sessionId'));
  }

  @override
  Widget build(BuildContext context) {
    final personas = ref.watch(personaListProvider).value ?? const <Persona>[];
    final selected = _selected(personas);
    return GlazeScaffold(
      title: 'vn_new'.tr(),
      showBack: true,
      onBack: () => context.pop(),
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _label(context, 'vn_new_persona'.tr()),
              SizedBox(
                height: 92,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _PersonaCard(
                      name: 'vn_new_no_persona'.tr(),
                      none: true,
                      selected: selected == null,
                      onTap: () => setState(() => _personaId = ''),
                    ),
                    for (final p in personas)
                      _PersonaCard(
                        name: (p.displayName?.trim().isNotEmpty ?? false)
                            ? p.displayName!
                            : p.name,
                        avatarPath: p.avatarPath,
                        selected: selected?.id == p.id,
                        onTap: () => setState(() => _personaId = p.id),
                      ),
                  ],
                ),
              ),
              if (selected?.prompt?.trim().isNotEmpty ?? false)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    selected!.prompt!.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.cs.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              _label(context, 'vn_new_idea'.tr()),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final key in _kSectionKeys)
                    ActionChip(
                      label: Text('+ ${key.tr()}'),
                      onPressed: () => _insertSection(key),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: GlassSurface(
                  borderRadius: BorderRadius.circular(14),
                  child: TextField(
                    controller: _controller,
                    focusNode: _focus,
                    expands: true,
                    maxLines: null,
                    minLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    keyboardType: TextInputType.multiline,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.45,
                      color: context.cs.onSurface,
                    ),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.all(14),
                      hintText: 'vn_new_idea_hint'.tr(),
                      hintMaxLines: 8,
                      hintStyle: TextStyle(
                        color: context.cs.onSurfaceVariant,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              GlazeActionButton(
                icon: Icons.auto_awesome,
                label: 'vn_generate_confirm'.tr(),
                tone: GlazeActionTone.primary,
                expand: true,
                busy: _creating,
                onTap: () => _create(personas),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: context.cs.onSurfaceVariant,
      ),
    ),
  );
}

class _PersonaCard extends StatelessWidget {
  const _PersonaCard({
    required this.name,
    required this.selected,
    required this.onTap,
    this.avatarPath,
    this.none = false,
  });

  /// The "no persona" card.
  final bool none;
  final String name;
  final String? avatarPath;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final image = glazeAvatarImage(avatarPath);
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 76,
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  width: 2,
                  color: selected ? context.cs.primary : Colors.transparent,
                ),
              ),
              child: CircleAvatar(
                radius: 26,
                backgroundColor: context.cs.primary.withValues(alpha: 0.16),
                backgroundImage: image,
                child: image == null
                    ? Icon(
                        none ? Icons.person_off_outlined : Icons.person_outline,
                        color: context.cs.primary,
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                color: selected
                    ? context.cs.onSurface
                    : context.cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
