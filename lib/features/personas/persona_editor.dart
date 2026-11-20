import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/persona.dart';
import '../../core/state/active_selection_provider.dart';
import '../../core/state/db_provider.dart';
import '../../core/state/shared_prefs_provider.dart';
import '../../core/utils/id_generator.dart';
import '../../core/utils/time_helpers.dart';
import '../../shared/shell/desktop/desktop_floating_provider.dart';
import '../../shared/widgets/generic_editor.dart';
import '../../shared/widgets/glaze_scaffold.dart';
import '../../shared/widgets/glaze_spinner.dart';
import 'persona_list_provider.dart';

/// Opens the editor for [existing], or for a new persona, from outside the
/// Personas list: on desktop in a floating window of its own (opening one
/// already open brings it to the front), elsewhere as a page pushed on
/// [rootNavigator] or the nearest one.
void openPersonaEditor(
  BuildContext context, {
  Persona? existing,
  bool rootNavigator = true,
}) {
  final view = Uri(
    path: 'persona-editor',
    queryParameters: existing == null
        ? {'new': generateId()}
        : {'id': existing.id},
  ).toString();
  if (floatOnDesktop(context, view)) return;
  Navigator.of(context, rootNavigator: rootNavigator).push(
    MaterialPageRoute<void>(
      builder: (_) => _PersonaEditorPage(existing: existing),
    ),
  );
}

/// The persona editor in a desktop floating window (`persona-editor`): the
/// persona [personaId] names, or a new one when it is null.
class PersonaEditorWindow extends ConsumerWidget {
  final String? personaId;

  const PersonaEditorWindow({super.key, this.personaId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = personaId;
    if (id == null) return const _PersonaEditorPage();
    final personas = ref.watch(personaListProvider).value;
    if (personas == null) return const Center(child: GlazeSpinner());
    final persona = personas.where((p) => p.id == id).firstOrNull;
    if (persona == null) return const SizedBox.shrink();
    return _PersonaEditorPage(existing: persona);
  }
}

/// The persona editor's form: the persona [existing] names, or a new one.
/// Hosted in the Personas list's place (the way the Presets list hosts its
/// editor), in a desktop window, or on a page of its own.
class PersonaEditorBody extends ConsumerStatefulWidget {
  final Persona? existing;
  const PersonaEditorBody({super.key, this.existing});

  @override
  ConsumerState<PersonaEditorBody> createState() => _PersonaEditorBodyState();
}

class _PersonaEditorBodyState extends ConsumerState<PersonaEditorBody> {
  late Map<String, dynamic> _item;
  late final String _personaId;
  late final int _createdAt;
  late ProviderContainer _container;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // GenericEditor flushes pending changes from dispose(), after this element
    // has been deactivated. Keep a container captured while it is still active.
    _container = ProviderScope.containerOf(context);
  }

  List<GenericEditorSection> get _config => [
    GenericEditorSection(
      title: 'section_basic_info'.tr(),
      fields: [
        GenericEditorField(
          key: 'name',
          label: 'label_name'.tr(),
          placeholder: 'placeholder_enter_name'.tr(),
        ),
        GenericEditorField(
          key: 'display_name',
          label: 'Display Name',
          placeholder: 'Name shown in lists',
        ),
        GenericEditorField(
          key: 'prompt',
          label:
              "${'tab_personas'.tr()} ${'label_char_prompt'.tr().replaceAll(RegExp(r'Character |Персонажа ', caseSensitive: false), '')}",
          type: 'textarea',
          rows: 12,
          placeholder: 'placeholder_prompt_text'.tr(),
        ),
      ],
    ),
  ];

  @override
  void initState() {
    super.initState();
    _personaId = widget.existing?.id ?? generateId();
    _createdAt = widget.existing?.createdAt ?? currentTimestampSeconds();
    _item = {
      'name': widget.existing?.name ?? '',
      'display_name': widget.existing?.displayName ?? '',
      'prompt': widget.existing?.prompt ?? '',
      'avatarPath': widget.existing?.avatarPath,
    };
  }

  Future<void> _pickAvatar() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final filePath = result.files.first.path;
    if (filePath == null) return;

    final imageStorage = await ref.read(imageStorageProvider.future);
    final bytes = await File(filePath).readAsBytes();
    // Reusing persona_<id>.png leaves the WebView on its cached image and the
    // persona roster cannot observe a change because avatarPath stays equal.
    final savedPath = await imageStorage.saveAvatar(
      'persona_${_personaId}_${DateTime.now().microsecondsSinceEpoch}',
      bytes,
    );
    await FileImage(File(savedPath)).evict();
    final thumbPath = imageStorage.thumbnailPath(savedPath);
    if (thumbPath != null) await FileImage(File(thumbPath)).evict();

    setState(() {
      _item['avatarPath'] = savedPath;
    });
    _save(_item);
  }

  void _save(Map<String, dynamic> values) {
    final name = (values['name'] as String?)?.trim() ?? '';
    final displayName = (values['display_name'] as String?)?.trim() ?? '';
    final promptStr = (values['prompt'] as String?)?.trim() ?? '';

    final persona = Persona(
      id: _personaId,
      name: name.isEmpty ? 'unnamed_entry'.tr().split(' ')[0] : name,
      displayName: displayName.isEmpty ? null : displayName,
      prompt: promptStr.isEmpty ? null : promptStr,
      avatarPath: values['avatarPath'] as String?,
      createdAt: _createdAt,
    );

    _container.read(personaListProvider.notifier).updatePersona(persona);

    if (widget.existing == null) {
      _container.read(activePersonaIdProvider.notifier).state = _personaId;
      _container.read(sharedPreferencesProvider.future).then((prefs) {
        prefs.setString('activePersonaId', _personaId);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return GenericEditor(
      item: _item,
      config: _config,
      showAvatar: true,
      avatarHint: 'hint_change_avatar'.tr(),
      onAvatarTap: _pickAvatar,
      onChanged: (values) {
        _item = values;
      },
      onSave: (values) {
        _save(values);
      },
    );
  }
}

/// The title of the persona editor for [existing], or for a new persona.
String personaEditorTitle(Persona? existing) => existing != null
    ? "${'action_edit'.tr()} ${'tab_personas'.tr()}"
    : "${'create_new'.tr()} ${'tab_personas'.tr()}";

class _PersonaEditorPage extends StatelessWidget {
  final Persona? existing;
  const _PersonaEditorPage({this.existing});

  @override
  Widget build(BuildContext context) {
    return GlazeScaffold(
      title: personaEditorTitle(existing),
      onBack: () => Navigator.of(context).pop(),
      body: PersonaEditorBody(existing: existing),
    );
  }
}
