import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/import/silly_tavern_preset_parser.dart';
import '../../core/llm/preset_macro_attribution.dart';
import '../../core/models/preset.dart';
import '../../core/state/active_selection_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/sheet_view.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_toast.dart';
import 'preset_connections_sheet.dart';
import 'preset_editor_screen.dart';
import 'preset_list_provider.dart';

class PresetListScreen extends ConsumerStatefulWidget {
  final bool startExpanded;

  /// Active chat, forwarded to the preset editor so the Author's Note block can
  /// edit the session-scoped note. Null when opened outside a chat.
  final String? charId;
  const PresetListScreen({
    super.key,
    this.startExpanded = false,
    this.charId,
  });

  @override
  ConsumerState<PresetListScreen> createState() => _PresetListScreenState();
}

class _PresetListScreenState extends ConsumerState<PresetListScreen> {
  Preset? _editingPreset;
  bool _isCreating = false;
  GlobalKey<PresetEditorBodyState> _editorKey = GlobalKey<PresetEditorBodyState>();

  bool get _inEditor => _isCreating || _editingPreset != null;

  void _openEditor(Preset? preset) {
    setState(() {
      _editingPreset = preset;
      _isCreating = preset == null;
      // Recreate the editor key so PresetEditorBody's initState fires
      // and picks up the new preset's blocks instead of the old ones.
      _editorKey = GlobalKey<PresetEditorBodyState>();
    });
  }

  void _closeEditor() {
    setState(() {
      _editingPreset = null;
      _isCreating = false;
    });
  }

  void _handleBack() {
    if (_inEditor) {
      final handled = _editorKey.currentState?.handleBack() ?? false;
      if (!handled) {
        _closeEditor();
      }
    } else {
      if (widget.startExpanded) {
        context.go('/tools');
      } else {
        Navigator.of(context).maybePop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final presets = ref.watch(presetListProvider);
    final activeId = ref.watch(activePresetIdProvider);

    return SheetView(
      startExpanded: widget.startExpanded,
      showRouteBackground: false,
      title: _inEditor
          ? (_editingPreset != null ? 'Edit Preset' : 'New Preset')
          : 'Presets',
      showBack: true,
      onBack: _handleBack,
      body: _inEditor
          ? PresetEditorBody(
              key: _editorKey,
              preset: _editingPreset,
              charId: widget.charId,
              onDeleted: _closeEditor,
            )
          : presets.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('${'title_error'.tr()}: $e')),
              data: (list) => _buildBody(context, ref, list, activeId),
            ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    List<Preset> list,
    String? activeId,
  ) {
    return Builder(
      builder: (context) => ListView.builder(
        padding: const EdgeInsets.fromLTRB(
          16,
          12,
          16,
          16,
        ).add(EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top,
          bottom: MediaQuery.paddingOf(context).bottom,
        )),
        itemCount: list.length + 1,
        itemBuilder: (_, i) {
          if (i == list.length) return _buildAddButton(context, ref);
          final preset = list[i];
          final isActive = activeId == preset.id;
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _PsCard(
              preset: preset,
              isActive: isActive,
              onActivate: () {
                if (!isActive) {
                  setActivePreset(ref, preset.id);
                }
              },
              onConnections: () => showPresetConnections(context, preset.id),
              onEdit: () => _openEditor(preset),
            ),
          );
        },
      ),
    );
  }

  Widget _buildAddButton(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Material(
        color: context.cs.primary,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: () => _showAddSheet(context, ref),
          borderRadius: BorderRadius.circular(14),
          splashColor: Colors.white.withValues(alpha: 0.1),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add, color: Colors.white, size: 20),
                SizedBox(width: 8),
                Text(
                  'Add / Import',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showAddSheet(BuildContext context, WidgetRef ref) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'Add Preset',
      items: [
        BottomSheetItem(
          icon: Icons.add_circle_outline,
          label: 'Create New Preset',
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _openEditor(null);
          },
        ),
        BottomSheetItem(
          icon: Icons.file_upload_outlined,
          label: 'Import from File',
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _importPreset();
          },
        ),
      ],
    );
  }

  Future<void> _importPreset() async {
    final ctx = context;
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        type: Platform.isIOS ? FileType.any : FileType.custom,
        allowedExtensions: Platform.isIOS ? null : ['json'],
        allowMultiple: true,
        withData: true,
      );
    } catch (_) {}
    if (!mounted) return;
    if (result == null || result.files.isEmpty) return;

    final notifier = ref.read(presetListProvider.notifier);
    final imported = <Preset>[];
    Object? lastError;
    var unreadable = 0;

    for (final picked in result.files) {
      try {
        String jsonString;
        if (picked.bytes != null && picked.bytes!.isNotEmpty) {
          jsonString = utf8.decode(picked.bytes!);
        } else if (picked.path != null && picked.path!.isNotEmpty) {
          jsonString = await File(picked.path!).readAsString();
        } else {
          unreadable++;
          continue;
        }

        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        final preset = parseSillyTavernPreset(json, picked.name);
        await notifier.add(preset);
        imported.add(preset);
      } catch (e) {
        lastError = e;
      }
    }

    if (!ctx.mounted) return;

    if (imported.isEmpty) {
      if (lastError != null) {
        GlazeErrorDialog.show(ctx, lastError, prefix: 'Import failed: ');
      } else if (unreadable > 0) {
        GlazeToast.show(ctx, 'Cannot read file');
      }
      return;
    }

    if (imported.length == 1 && result.files.length == 1) {
      final preset = imported.single;
      GlazeToast.show(
        ctx,
        'Imported "${preset.name}" (${preset.blocks.length} blocks)',
      );
      return;
    }

    final failed = result.files.length - imported.length;
    GlazeToast.show(
      ctx,
      'Imported ${imported.length} presets'
      '${failed > 0 ? ' — $failed failed' : ''}',
    );
  }
}

int _presetTokenCount(Preset preset) => presetOnlyTokenCount(preset);



// ─── ps-card ─────────────────────────────────────────────────────────────────

class _PsCard extends ConsumerWidget {
  final Preset preset;
  final bool isActive;
  final VoidCallback onActivate;
  final VoidCallback onConnections;
  final VoidCallback onEdit;

  const _PsCard({
    required this.preset,
    required this.isActive,
    required this.onActivate,
    required this.onConnections,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connections = ref.watch(presetConnectionsProvider);
    final hasCharBinding = connections.character.values.contains(preset.id);
    final hasChatBinding = connections.chat.values.contains(preset.id);

    return GlassSurface(
      enableRipple: true,
      tint: isActive
          ? Color.alphaBlend(
              context.cs.primary.withValues(alpha: 0.12),
              context.cs.surfaceContainerHighest,
            )
          : null,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: isActive
            ? context.cs.primary.withValues(alpha: 0.5)
            : context.cs.outline,
        width: isActive ? 2 : 1,
      ),
      onTap: onActivate,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Circular icon
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: context.cs.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.description_outlined,
                size: 20,
                color: context.cs.primary,
              ),
            ),
            const SizedBox(width: 12),
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    preset.name,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: context.cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _SmallBadge(
                        icon: Icons.description,
                        label: '${_presetTokenCount(preset)}',
                      ),
                      if (preset.author != null &&
                          preset.author!.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'by ${preset.author}',
                             style: TextStyle(
                               fontSize: 12,
                               color: context.cs.onSurfaceVariant,
                             ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Connection badge — tappable, colour shows binding type
            _ConnBadge(
              isActive: isActive,
              hasChatBinding: hasChatBinding,
              hasCharBinding: hasCharBinding,
              onTap: onConnections,
            ),
            const SizedBox(width: 8),
            // Edit button
            SizedBox(
              width: 34,
              height: 34,
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  onTap: onEdit,
                  borderRadius: BorderRadius.circular(8),
                   child: Icon(
                     Icons.edit_outlined,
                     size: 18,
                     color: context.cs.onSurfaceVariant,
                   ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── shared small widgets ─────────────────────────────────────────────────────

class _SmallBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  const _SmallBadge({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: context.cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: context.cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Tappable link badge that shows the preset's binding scope visually.
///
/// Colour logic (mirrors JS Glaze `getPresetConnectionType`):
///   orange  — chat-level binding active
///   purple  — character-level binding active (no chat binding)
///   green   — globally active (no specific bindings)
///   grey    — not active, no bindings
class _ConnBadge extends StatelessWidget {
  final bool isActive;
  final bool hasChatBinding;
  final bool hasCharBinding;
  final VoidCallback onTap;

  const _ConnBadge({
    required this.isActive,
    required this.hasChatBinding,
    required this.hasCharBinding,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color color;
    if (hasChatBinding) {
      color = const Color(0xFFFF9500); // orange — chat binding
    } else if (hasCharBinding) {
      color = const Color(0xFFAF52DE); // purple — character binding
    } else if (isActive) {
      color = const Color(0xFF34C759); // green — global active
    } else {
      color = context.cs.onSurfaceVariant.withValues(alpha: 0.5); // grey
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: (hasChatBinding || hasCharBinding || isActive)
              ? color.withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.link, size: 16, color: color),
      ),
    );
  }
}
