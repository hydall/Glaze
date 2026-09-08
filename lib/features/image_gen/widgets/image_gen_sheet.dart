import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/platform_paths.dart';
import '../../character_gallery/gallery_image_picker.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/help_tip.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../image_gen_models.dart';
import '../image_gen_provider.dart';
import 'connection_fields.dart';
import 'model_fields.dart';
import 'rows.dart' as rows;

class ImageGenSheet extends ConsumerStatefulWidget {
  const ImageGenSheet({super.key, this.charId});

  final String? charId;

  @override
  ConsumerState<ImageGenSheet> createState() => _ImageGenSheetState();
}

class _ImageGenSheetState extends ConsumerState<ImageGenSheet> {
  late ImageGenSettings _settings;
  bool _isFetchingModels = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _settings =
        ref.read(imageGenSettingsProvider).value ?? const ImageGenSettings();
  }

  void _update(ImageGenSettings s) {
    _settings = s;
    ref.read(imageGenSettingsProvider.notifier).save(s);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _showOptions<T>({
    required String title,
    required List<T> items,
    required String Function(T) labelBuilder,
    required bool Function(T) isSelected,
    required void Function(T) onSelected,
  }) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: context.cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final item = items[i];
                    final selected = isSelected(item);
                    return ListTile(
                      title: Text(labelBuilder(item)),
                      trailing: selected
                          ? Text(
                              'Active',
                              style: TextStyle(
                                fontSize: 12,
                                color: context.cs.primary,
                              ),
                            )
                          : null,
                      onTap: () {
                        Navigator.pop(context);
                        onSelected(item);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openApiTypeSelector() {
    _showOptions<ImageGenApiType>(
      title: 'API Type',
      items: ImageGenApiType.values,
      labelBuilder: (t) => switch (t) {
        ImageGenApiType.openai => 'OpenAI',
        ImageGenApiType.gemini => 'Gemini',
        ImageGenApiType.naistera => 'Naistera',
        ImageGenApiType.routmy => 'rout.my',
        ImageGenApiType.ruRoutmy => 'RU-rout.my',
      },
      isSelected: (t) => _settings.apiType == t,
      onSelected: (t) => _update(_settings.copyWith(apiType: t)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings;

    return SheetView(
      titleWidget: Row(
        children: [
          Text(
            'section_image_gen'.tr(),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const HelpTip(term: 'image-gen'),
          const Spacer(),
          Switch(
            value: s.enabled,
            onChanged: (v) => _update(s.copyWith(enabled: v)),
          ),
        ],
      ),
      fitContent: false,
      scrollController: _scrollController,
      enableHeaderBlur: false,
      body: s.enabled ? _buildBody(context, s) : const SizedBox.shrink(),
    );
  }

  Widget _buildBody(BuildContext context, ImageGenSettings s) {
    return Builder(
      builder: (context) => SingleChildScrollView(
        controller: _scrollController,
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 16,
          bottom: MediaQuery.paddingOf(context).bottom + 24,
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _buildPresetSelector(s.apiType),
              ),
            ),
            rows.ImageGenMenuGroup(
              title: 'Connection',
              children: _buildConnectionFields(s),
            ),
            rows.ImageGenMenuGroup(
              title: 'Model',
              children: _buildModelFields(s),
            ),
            if (s.apiType == ImageGenApiType.naistera &&
                NaisteraConstants.noRefModels.contains(s.naisteraModel))
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.05),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.2)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    'imggen_no_refs_hint'.tr(),
                    style: TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            if ((s.apiType == ImageGenApiType.naistera &&
                    !NaisteraConstants.noRefModels.contains(s.naisteraModel)) ||
                s.apiType == ImageGenApiType.routmy ||
                s.apiType == ImageGenApiType.ruRoutmy)
              ..._buildReferences(s),
            if (s.apiType != ImageGenApiType.naistera ||
                !NaisteraConstants.noRefModels.contains(s.naisteraModel))
              rows.ImageGenMenuGroup(
                title: 'Image Context',
                children: [
                  rows.ImageGenCheckboxRow(
                    label: 'Send previous images as context',
                    description: 'imggen_image_context_desc'.tr(),
                    value: s.imageContextEnabled,
                    onChanged: (v) =>
                        _update(s.copyWith(imageContextEnabled: v)),
                  ),
                  if (s.imageContextEnabled)
                    rows.ImageGenSelectorRow(
                      label: 'Context image count',
                      value: s.imageContextCount.toString(),
                      onTap: () {
                        _showOptions<int>(
                          title: 'Context image count',
                          items: [1, 2, 3],
                          labelBuilder: (i) => i.toString(),
                          isSelected: (i) => s.imageContextCount == i,
                          onSelected: (i) =>
                              _update(s.copyWith(imageContextCount: i)),
                        );
                      },
                    ),
                ],
              ),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: context.cs.surfaceContainerHighest.withValues(
                  alpha: 0.8,
                ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'AI must include image tags to trigger generation:',
                    style: TextStyle(
                      fontSize: 13,
                      color: context.cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '[IMG:GEN:{"prompt":"...","style":"anime"}]',
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: context.cs.primary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPresetSelector(ImageGenApiType selected) {
    final name = switch (selected) {
      ImageGenApiType.openai => 'OpenAI',
      ImageGenApiType.gemini => 'Gemini',
      ImageGenApiType.naistera => 'Naistera',
      ImageGenApiType.routmy => 'rout.my',
      ImageGenApiType.ruRoutmy => 'RU-rout.my',
    };
    return InkWell(
      onTap: _openApiTypeSelector,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: context.cs.primary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.cs.primary.withValues(alpha: 0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              name,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.cs.primary,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.keyboard_arrow_down,
              size: 20,
              color: context.cs.primary,
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildConnectionFields(ImageGenSettings s) {
    switch (s.apiType) {
      case ImageGenApiType.naistera:
        return buildNaisteraConnectionFields(s, _update);
      case ImageGenApiType.routmy:
        return buildRoutmyConnectionFields(s, isRu: false, onUpdate: _update);
      case ImageGenApiType.ruRoutmy:
        return buildRoutmyConnectionFields(s, isRu: true, onUpdate: _update);
      case ImageGenApiType.openai:
      case ImageGenApiType.gemini:
        return buildOpenaiConnectionFields(s, _update);
    }
  }

  List<Widget> _buildModelFields(ImageGenSettings s) {
    final showOptions = _showOptionsCallback();
    switch (s.apiType) {
      case ImageGenApiType.naistera:
        return buildNaisteraModelFields(s, _update, showOptions);
      case ImageGenApiType.routmy:
        return buildRoutmyModelFields(
          s,
          isRu: false,
          onUpdate: _update,
          showOptions: showOptions,
        );
      case ImageGenApiType.ruRoutmy:
        return buildRoutmyModelFields(
          s,
          isRu: true,
          onUpdate: _update,
          showOptions: showOptions,
        );
      case ImageGenApiType.openai:
        return buildOpenaiModelFields(
          context,
          s,
          isFetching: _isFetchingModels,
          onFetchModels: _onFetchModels,
          onUpdate: _update,
          showOptions: showOptions,
        );
      case ImageGenApiType.gemini:
        return buildGeminiModelFields(s, _update, showOptions);
    }
  }

  ShowOptionsCallback _showOptionsCallback() {
    return <T>({
      required String title,
      required List<T> items,
      required String Function(T) labelBuilder,
      required bool Function(T) isSelected,
      required void Function(T) onSelected,
    }) {
      _showOptions<T>(
        title: title,
        items: items,
        labelBuilder: labelBuilder,
        isSelected: isSelected,
        onSelected: onSelected,
      );
    };
  }

  Future<void> _onFetchModels() async {
    setState(() => _isFetchingModels = true);
    await Future<void>.delayed(const Duration(seconds: 1));
    if (mounted) {
      setState(() => _isFetchingModels = false);
    }
  }

  Future<String?> _pickReferenceImage() async {
    final source = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      backgroundColor: context.cs.surface,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                'Choose reference image',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('From device'),
              onTap: () => Navigator.pop(context, 'device'),
            ),
            if (widget.charId != null)
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('From card gallery'),
                onTap: () => Navigator.pop(context, 'gallery'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || source == null) return null;

    if (source == 'gallery') {
      final entry = await showCharacterGalleryImagePicker(
        context,
        charId: widget.charId!,
      );
      if (entry == null) return null;
      final path = resolveGlazeFilePath(entry.imagePath) ?? entry.imagePath;
      return _fileToDataUrl(File(path), path);
    }

    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final picked = result.files.single;
    final bytes =
        picked.bytes ??
        (picked.path == null ? null : await File(picked.path!).readAsBytes());
    if (bytes == null) return null;
    return 'data:${_imageMime(picked.name)};base64,${base64Encode(bytes)}';
  }

  Future<String?> _fileToDataUrl(File file, String path) async {
    try {
      if (!await file.exists()) return null;
      return 'data:${_imageMime(path)};base64,${base64Encode(await file.readAsBytes())}';
    } catch (_) {
      return null;
    }
  }

  String _imageMime(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/png';
  }

  List<Widget> _buildReferences(ImageGenSettings s) {
    final isRoutmy = s.apiType == ImageGenApiType.routmy;
    final isRuRoutmy = s.apiType == ImageGenApiType.ruRoutmy;

    final sendCharAvatar = isRoutmy
        ? s.routmySendCharAvatar
        : (isRuRoutmy ? s.ruRoutmySendCharAvatar : s.naisteraSendCharAvatar);
    final sendUserAvatar = isRoutmy
        ? s.routmySendUserAvatar
        : (isRuRoutmy ? s.ruRoutmySendUserAvatar : s.naisteraSendUserAvatar);

    final refs = (isRoutmy || isRuRoutmy)
        ? s.routmyAdditionalRefs
        : s.additionalReferences;

    return [
      rows.ImageGenMenuGroup(
        title: 'Reference Images',
        children: [
          rows.ImageGenCheckboxRow(
            label: 'imggen_send_char_avatar'.tr(),
            description: 'imggen_send_char_avatar_desc'.tr(),
            value: sendCharAvatar,
            onChanged: (v) {
              if (isRoutmy) {
                _update(s.copyWith(routmySendCharAvatar: v));
              } else if (isRuRoutmy) {
                _update(s.copyWith(ruRoutmySendCharAvatar: v));
              } else {
                _update(s.copyWith(naisteraSendCharAvatar: v));
              }
            },
          ),
          rows.ImageGenCheckboxRow(
            label: 'imggen_send_user_avatar'.tr(),
            description: 'imggen_send_user_avatar_desc'.tr(),
            value: sendUserAvatar,
            onChanged: (v) {
              if (isRoutmy) {
                _update(s.copyWith(routmySendUserAvatar: v));
              } else if (isRuRoutmy) {
                _update(s.copyWith(ruRoutmySendUserAvatar: v));
              } else {
                _update(s.copyWith(naisteraSendUserAvatar: v));
              }
            },
          ),
        ],
      ),
      rows.ImageGenMenuGroup(
        title: 'Additional References',
        trailing: Text(
          isRoutmy || isRuRoutmy ? '${refs.length}' : '${refs.length}/8',
          style: TextStyle(fontSize: 13, color: context.cs.onSurfaceVariant),
        ),
        children: [
          if (isRoutmy || isRuRoutmy)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'You can save any number of references. If more than '
                '$routmyMaxInjectedReferenceImages match, only the first '
                '$routmyMaxInjectedReferenceImages are sent.',
                style: TextStyle(
                  fontSize: 12,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
            ),
          for (int i = 0; i < refs.length; i++)
            rows.ImageGenReferenceRow(
              key: ValueKey('ref_$i'),
              refItem: refs[i],
              onNameChanged: (v) {
                final copy = List<ReferenceImage>.from(refs);
                copy[i] = copy[i].copyWith(name: v);
                if (isRoutmy || isRuRoutmy) {
                  _update(s.copyWith(routmyAdditionalRefs: copy));
                } else {
                  _update(s.copyWith(additionalReferences: copy));
                }
              },
              onMatchModeChanged: (v) {
                final copy = List<ReferenceImage>.from(refs);
                copy[i] = copy[i].copyWith(matchMode: v);
                if (isRoutmy || isRuRoutmy) {
                  _update(s.copyWith(routmyAdditionalRefs: copy));
                } else {
                  _update(s.copyWith(additionalReferences: copy));
                }
              },
              onPickImage: () async {
                final imageData = await _pickReferenceImage();
                if (imageData == null || !mounted) return;
                final copy = List<ReferenceImage>.from(refs);
                copy[i] = copy[i].copyWith(imageData: imageData);
                if (isRoutmy || isRuRoutmy) {
                  _update(s.copyWith(routmyAdditionalRefs: copy));
                } else {
                  _update(s.copyWith(additionalReferences: copy));
                }
              },
              onRemove: () {
                final copy = List<ReferenceImage>.from(refs);
                copy.removeAt(i);
                if (isRoutmy || isRuRoutmy) {
                  _update(s.copyWith(routmyAdditionalRefs: copy));
                } else {
                  _update(s.copyWith(additionalReferences: copy));
                }
              },
            ),
          if (isRoutmy || isRuRoutmy || refs.length < 8)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: InkWell(
                onTap: () {
                  final copy = List<ReferenceImage>.from(refs);
                  copy.add(
                    const ReferenceImage(
                      name: '',
                      imageData: '',
                      matchMode: 'match',
                    ),
                  );
                  if (isRoutmy || isRuRoutmy) {
                    _update(s.copyWith(routmyAdditionalRefs: copy));
                  } else {
                    _update(s.copyWith(additionalReferences: copy));
                  }
                },
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: context.cs.primary.withValues(alpha: 0.4),
                      style: BorderStyle.solid,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      '+ ${'imggen_add_ref'.tr()}',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: context.cs.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ];
  }
}
