import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:easy_localization/easy_localization.dart';

import '../../core/models/character.dart';
import '../../core/state/character_provider.dart';
import '../../core/state/db_provider.dart';
import '../../core/utils/id_generator.dart';
import '../../core/utils/time_helpers.dart';
import '../../core/state/lorebook_provider.dart';
import '../../shared/shell/desktop/desktop_floating_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/sheet_view.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/generic_editor.dart';
import '../../shared/widgets/help_tip.dart';

/// Opens the editor for character [charId]: on desktop in a floating window of
/// its own, which leaves the rest of the app usable and can sit beside other
/// editors (opening one already open brings it to the front); on phones as the
/// editor's route.
Future<void> openCharacterEditor(BuildContext context, String charId) async {
  final view = Uri(
    path: 'character-editor',
    queryParameters: {'id': charId},
  ).toString();
  if (floatOnDesktop(context, view)) return;
  await context.push<void>('/character/$charId/edit');
}

/// Opens a blank editor for a new character, the way [openCharacterEditor]
/// opens an existing one.
Future<void> openCharacterCreator(BuildContext context) async {
  final view = Uri(
    path: 'character-editor',
    queryParameters: {'new': generateId()},
  ).toString();
  if (floatOnDesktop(context, view)) return;
  await context.push<void>('/character/create');
}

class CharacterEditorScreen extends ConsumerStatefulWidget {
  final String charId;
  final bool isNew;
  const CharacterEditorScreen({
    super.key,
    required this.charId,
    this.isNew = false,
  });

  @override
  ConsumerState<CharacterEditorScreen> createState() =>
      _CharacterEditorScreenState();
}

class _CharacterEditorScreenState extends ConsumerState<CharacterEditorScreen> {
  bool _loading = true;
  Character? _original;
  Map<String, dynamic> _item = {};
  List<String> _lorebookNames = [];
  late final String _effectiveId = widget.isNew ? generateId() : widget.charId;

  @override
  void initState() {
    super.initState();
    if (widget.isNew) {
      _item = {
        'name': '',
        'display_name': '',
        'description': '',
        'personality': '',
        'scenario': '',
        'first_mes': '',
        'alternate_greetings': <String>[],
        'mes_example': '',
        'system_prompt': '',
        'post_history_instructions': '',
        'creator': '',
        'creator_notes': '',
        'tags': <String>[],
        'avatarPath': null,
        'depth_prompt': '',
        'depth_prompt_depth': 4,
        'depth_prompt_role': 'system',
        'world': null,
        'talkativeness': 1.0,
      };
      _loading = false;
    } else {
      _loadCharacter();
    }
  }

  Future<void> _loadLorebookNames() async {
    final lorebooks = await ref.read(lorebooksProvider.future);
    if (mounted) {
      setState(() {
        _lorebookNames = lorebooks.map((lb) => lb.name).toList()..sort();
      });
    }
  }

  Future<void> _loadCharacter() async {
    final chars = await ref.read(charactersProvider.future);
    final char = chars.where((c) => c.id == widget.charId).firstOrNull;
    if (char != null && mounted) {
      _original = char;
      _item = {
        'name': char.name,
        'display_name': char.displayName ?? '',
        'description': char.description ?? '',
        'personality': char.personality ?? '',
        'scenario': char.scenario ?? '',
        'first_mes': char.firstMes ?? '',
        'alternate_greetings': List<String>.from(char.alternateGreetings),
        'mes_example': char.mesExample ?? '',
        'system_prompt': char.systemPrompt ?? '',
        'post_history_instructions': char.postHistoryInstructions ?? '',
        'creator': char.creator ?? '',
        'creator_notes': char.creatorNotes ?? '',
        'tags': List<String>.from(char.tags),
        'avatarPath': char.avatarPath,
        'depth_prompt': char.depthPrompt,
        'depth_prompt_depth': char.depthPromptDepth,
        'depth_prompt_role': char.depthPromptRole,
        'world': char.world,
        'talkativeness': char.extensions['talkativeness'] ?? 1.0,
      };
      setState(() => _loading = false);
      unawaited(_loadLorebookNames());
    } else if (mounted) {
      setState(() => _loading = false);
    }
  }

  void _goBack() {
    // A desktop window: close it.
    if (popDesktopWindow(context)) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/characters');
    }
  }

  void _saveAndClose() {
    if ((_item['name'] as String?)?.trim().isEmpty ?? true) {
      GlazeToast.show(context, 'error_name_required'.tr());
      return;
    }
    _save(_item);
    _goBack();
  }

  Future<void> _pickAvatar() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.image,
        withData: Platform.isAndroid || Platform.isIOS,
      );
      if (result == null || result.files.isEmpty) return;

      final selected = result.files.first;
      final bytes =
          selected.bytes ??
          (selected.path == null
              ? null
              : await File(selected.path!).readAsBytes());
      if (bytes == null) {
        throw const FormatException('The selected image could not be read');
      }

      final storage = await ref.read(imageStorageProvider.future);
      final savedPath = await storage.saveAvatar(_effectiveId, bytes);
      await FileImage(File(savedPath)).evict();
      final thumbPath = storage.thumbnailPath(savedPath);
      if (thumbPath != null) await FileImage(File(thumbPath)).evict();
      bumpAvatarVersion(ref);
      if (mounted) {
        setState(() {
          _item['avatarPath'] = savedPath;
          _item = Map.from(_item); // Force update
        });
        unawaited(_save(_item));
      }
    } catch (e) {
      if (mounted) {
        GlazeErrorDialog.show(
          context,
          e,
          prefix: 'error_avatar_import_failed_prefix'.tr(),
        );
      }
    }
  }

  Future<void> _save(Map<String, dynamic> item) async {
    if ((item['name'] as String?)?.trim().isEmpty ?? true) {
      return; // Do not auto-save if name is invalid
    }

    try {
      final tags =
          (item['tags'] as List<dynamic>?)?.map((t) => t.toString()).toList() ??
          [];
      final alternateGreetings =
          (item['alternate_greetings'] as List<dynamic>?)
              ?.map((t) => t.toString())
              .toList() ??
          [];

      final updated =
          _original?.copyWith(
            name: (item['name'] as String).trim(),
            displayName:
                (item['display_name'] as String?)?.trim().isEmpty ?? true
                ? null
                : (item['display_name'] as String).trim(),
            avatarPath: item['avatarPath'] as String?,
            description:
                (item['description'] as String?)?.trim().isEmpty ?? true
                ? null
                : (item['description'] as String).trim(),
            personality:
                (item['personality'] as String?)?.trim().isEmpty ?? true
                ? null
                : (item['personality'] as String).trim(),
            scenario: (item['scenario'] as String?)?.trim().isEmpty ?? true
                ? null
                : (item['scenario'] as String).trim(),
            firstMes: (item['first_mes'] as String?)?.trim().isEmpty ?? true
                ? null
                : (item['first_mes'] as String).trim(),
            mesExample: (item['mes_example'] as String?)?.trim().isEmpty ?? true
                ? null
                : (item['mes_example'] as String).trim(),
            systemPrompt:
                (item['system_prompt'] as String?)?.trim().isEmpty ?? true
                ? null
                : (item['system_prompt'] as String).trim(),
            postHistoryInstructions:
                (item['post_history_instructions'] as String?)
                        ?.trim()
                        .isEmpty ??
                    true
                ? null
                : (item['post_history_instructions'] as String).trim(),
            creator: (item['creator'] as String?)?.trim().isEmpty ?? true
                ? null
                : (item['creator'] as String).trim(),
            creatorNotes:
                (item['creator_notes'] as String?)?.trim().isEmpty ?? true
                ? null
                : (item['creator_notes'] as String).trim(),
            tags: tags,
            alternateGreetings: alternateGreetings,
            updatedAt: currentTimestampSeconds(),
            createdAt: _original?.createdAt ?? currentTimestampSeconds(),
            extensions: _extensionsFor(item, _original?.extensions),
            depthPrompt: (item['depth_prompt'] as String?)?.trim() ?? '',
            depthPromptDepth: item['depth_prompt_depth'] as int? ?? 4,
            depthPromptRole: item['depth_prompt_role'] as String? ?? 'system',
            world: item['world'] as String?,
          ) ??
          Character(
            id: _effectiveId,
            name: (item['name'] as String).trim(),
            displayName:
                (item['display_name'] as String?)?.trim().isEmpty ?? true
                ? null
                : (item['display_name'] as String).trim(),
            avatarPath: item['avatarPath'] as String?,
            description:
                (item['description'] as String?)?.trim().isEmpty ?? true
                ? null
                : (item['description'] as String).trim(),
            personality:
                (item['personality'] as String?)?.trim().isEmpty ?? true
                ? null
                : (item['personality'] as String).trim(),
            scenario: (item['scenario'] as String?)?.trim().isEmpty ?? true
                ? null
                : (item['scenario'] as String).trim(),
            firstMes: (item['first_mes'] as String?)?.trim().isEmpty ?? true
                ? null
                : (item['first_mes'] as String).trim(),
            mesExample: (item['mes_example'] as String?)?.trim().isEmpty ?? true
                ? null
                : (item['mes_example'] as String).trim(),
            systemPrompt:
                (item['system_prompt'] as String?)?.trim().isEmpty ?? true
                ? null
                : (item['system_prompt'] as String).trim(),
            postHistoryInstructions:
                (item['post_history_instructions'] as String?)
                        ?.trim()
                        .isEmpty ??
                    true
                ? null
                : (item['post_history_instructions'] as String).trim(),
            creator: (item['creator'] as String?)?.trim().isEmpty ?? true
                ? null
                : (item['creator'] as String).trim(),
            creatorNotes:
                (item['creator_notes'] as String?)?.trim().isEmpty ?? true
                ? null
                : (item['creator_notes'] as String).trim(),
            tags: tags,
            alternateGreetings: alternateGreetings,
            updatedAt: currentTimestampSeconds(),
            createdAt: currentTimestampSeconds(),
            extensions: _extensionsFor(item, null),
            depthPrompt: (item['depth_prompt'] as String?)?.trim() ?? '',
            depthPromptDepth: item['depth_prompt_depth'] as int? ?? 4,
            depthPromptRole: item['depth_prompt_role'] as String? ?? 'system',
            world: item['world'] as String?,
          );

      await ref.read(charactersProvider.notifier).save(updated);
      final avatarPath = item['avatarPath'] as String?;
      if (avatarPath != null && avatarPath.isNotEmpty) {
        await FileImage(File(avatarPath)).evict();
      }
    } catch (e) {
      if (mounted) {
        GlazeErrorDialog.show(
          context,
          e,
          prefix: 'error_save_failed_prefix'.tr(),
        );
      }
    }
  }

  /// Depths 0–20, plus the card's own value when an imported card uses a
  /// deeper one, so the selector can still show it.
  List<int> _depthOptions() {
    final current = _item['depth_prompt_depth'];
    return [
      for (var i = 0; i <= 20; i++) i,
      if (current is int && current > 20) current,
    ];
  }

  /// The card extensions to save. The depth prompt and the linked lorebook
  /// are stored there too (the repository writes the fields back into them),
  /// so a value cleared in the editor has to leave the extensions as well.
  Map<String, dynamic> _extensionsFor(
    Map<String, dynamic> item,
    Map<String, dynamic>? original,
  ) {
    final ext = <String, dynamic>{
      ...?original,
      'talkativeness': item['talkativeness'] is num
          ? (item['talkativeness'] as num).toDouble()
          : 1.0,
    };
    if ((item['depth_prompt'] as String?)?.trim().isEmpty ?? true) {
      ext.remove('depth_prompt');
    }
    if ((item['world'] as String?)?.isEmpty ?? true) ext.remove('world');
    return ext;
  }

  String _getFieldLabel(String field) => switch (field) {
    'name' => 'label_name'.tr(),
    'creator' => 'placeholder_author_name'.tr(),
    'tags' => 'label_tags'.tr(),
    'description' => 'label_description'.tr(),
    'personality' => 'label_personality'.tr(),
    'scenario' => 'label_scenario'.tr(),
    'first_mes' => 'label_first_mes'.tr(),
    'mes_example' => 'label_mes_example'.tr(),
    'system_prompt' => 'label_char_prompt'.tr().replaceAll(
      RegExp(r'Character|персонажа', caseSensitive: false),
      'role_system'.tr(),
    ),
    'post_history_instructions' =>
      "${'block_chat_history'.tr()} ${'guidance_placeholder'.tr().replaceAll('...', '')}",
    'creator_notes' =>
      '${'onboarding_placeholder_desc'.tr().split(' ')[0]} ${'label_description'.tr()}',
    'depth_prompt' =>
      '${'label_depth'.tr()} ${'placeholder_prompt_text'.tr().replaceAll('...', '')}',
    _ =>
      field
          .replaceAll('_', ' ')
          .replaceFirstMapped(
            RegExp(r'[a-z]'),
            (m) => m.group(0)!.toUpperCase(),
          ),
  };

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return SheetView(
        title: "${'action_edit'.tr()} ${'sheet_title_char_options'.tr()}",
        body: const Center(child: GlazeSpinner()),
      );
    }

    final config = [
      GenericEditorSection(
        title: null,
        fields: [
          GenericEditorField(
            key: 'name',
            label: 'label_name'.tr(),
            type: 'text',
          ),
          GenericEditorField(
            key: 'display_name',
            label: 'Display Name',
            type: 'text',
          ),
          GenericEditorField(
            key: 'creator',
            label: 'placeholder_author_name'.tr(),
            type: 'text',
          ),
          GenericEditorField(
            key: 'tags',
            label: 'label_tags'.tr(),
            type: 'tags',
            placeholder: 'tag1, tag2, tag3',
          ),
        ],
      ),
      GenericEditorSection(
        title: 'sheet_title_char_options'.tr(),
        fields: [
          GenericEditorField(
            key: 'description',
            label: 'label_description'.tr(),
            type: 'textarea',
            rows: 4,
            expandable: true,
          ),
          GenericEditorField(
            key: 'personality',
            label: 'label_personality'.tr(),
            type: 'textarea',
            rows: 4,
            expandable: true,
          ),
          GenericEditorField(
            key: 'scenario',
            label: 'label_scenario'.tr(),
            type: 'textarea',
            rows: 4,
            expandable: true,
          ),
        ],
      ),
      GenericEditorSection(
        title: "${'label_first_mes'.tr()} & ${'block_example_dialogue'.tr()}",
        fields: [
          GenericEditorField(
            key: 'first_mes',
            label: 'label_first_mes'.tr(),
            type: 'greeting_list',
          ),
          GenericEditorField(
            key: 'mes_example',
            label: 'label_mes_example'.tr(),
            type: 'textarea',
            rows: 6,
            expandable: true,
          ),
        ],
      ),
      GenericEditorSection(
        title: 'section_prompt_blocks'.tr(),
        fields: [
          GenericEditorField(
            key: 'system_prompt',
            label: _getFieldLabel('system_prompt'),
            type: 'textarea',
            rows: 6,
            expandable: true,
          ),
          GenericEditorField(
            key: 'post_history_instructions',
            label: _getFieldLabel('post_history_instructions'),
            type: 'textarea',
            rows: 4,
            expandable: true,
          ),
          GenericEditorField(
            key: 'creator_notes',
            label: _getFieldLabel('creator_notes'),
            type: 'textarea',
            rows: 3,
          ),
        ],
      ),
      GenericEditorSection(
        title: 'section_advanced_settings'.tr(),
        fields: [
          GenericEditorField(
            key: 'depth_prompt',
            label: _getFieldLabel('depth_prompt'),
            type: 'textarea',
            rows: 4,
            expandable: true,
          ),
          GenericEditorField(
            key: 'depth_prompt_role',
            label: "${'label_depth'.tr()} ${'label_role'.tr()}",
            type: 'select',
            options: [
              {'label': 'role_system'.tr(), 'value': 'system'},
              {'label': 'role_user'.tr(), 'value': 'user'},
              {'label': 'role_assistant'.tr(), 'value': 'assistant'},
            ],
          ),
          GenericEditorField(
            key: 'depth_prompt_depth',
            label: 'label_depth'.tr(),
            type: 'select',
            options: [
              for (final depth in _depthOptions())
                {'label': '$depth', 'value': depth},
            ],
          ),
          GenericEditorField(
            key: 'world',
            label: 'menu_lorebooks'.tr(),
            type: 'select',
            options: [
              {'label': 'label_none'.tr(), 'value': null},
              ..._lorebookNames.map((name) => {'label': name, 'value': name}),
            ],
          ),
          GenericEditorField(
            key: 'talkativeness',
            label:
                "${'tab_chat'.tr()} ${'label_probability'.tr().replaceAll(' (%)', '')} (0.0 - 1.0)",
            type: 'number',
          ),
        ],
      ),
    ];

    return SheetView(
      titleWidget: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.isNew
                ? "${'create_new'.tr()} ${'sheet_title_char_options'.tr()}"
                : "${'action_edit'.tr()} ${'sheet_title_char_options'.tr()}",
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: context.cs.onSurface,
            ),
          ),
          const HelpTip(term: 'character'),
        ],
      ),
      showBack: true,
      onBack: _goBack,
      actions: widget.isNew
          ? [
              SheetViewAction(
                icon: const Icon(Icons.check_rounded, size: 20),
                tooltip: 'btn_save'.tr(),
                onPressed: _saveAndClose,
              ),
            ]
          : const [],
      body: GenericEditor(
        item: _item,
        config: config,
        showAvatar: true,
        avatarField: 'avatarPath',
        avatarHint: 'hint_change_avatar'.tr(),
        avatarPlaceholder: (_item['name']?.toString().isNotEmpty ?? false)
            ? _item['name'].toString()[0].toUpperCase()
            : '?',
        onAvatarTap: _pickAvatar,
        onChanged: (values) {
          _item = values;
        },
        onSave: widget.isNew ? null : _save,
      ),
    );
  }
}
