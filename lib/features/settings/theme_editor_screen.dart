import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/shared_prefs_provider.dart';
import '../../shared/shell/nav_height_provider.dart';
import '../../shared/theme/theme_preset.dart';
import '../../shared/theme/theme_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_scaffold.dart';
import '../../shared/widgets/glaze_tab_bar.dart';
import '../../shared/widgets/swipe_tab_switcher.dart';
import '../../shared/widgets/tab_slide_switcher.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/menu_group.dart';
import 'app_settings_provider.dart';
import 'theme_preview.dart';
import 'widgets/chat_layout_picker.dart';

// ─── Palette (mirrors Glaze JS PRESET_COLORS / PRESET_UI_COLORS) ──────────────

const _presetColors = [
  '#7996CE', '#E0555D', '#4BB34B', '#FFA000',
  '#8858C9', '#333333', '#007AFF', '#FF2D55',
  '#FFFFFF', '#000000', '#19191A', '#B0B8C1',
];

const _presetUiColors = [
  '#FFFFFF', '#19191A', '#7996CE', '#E0555D',
  '#4BB34B', '#FFA000', '#8858C9', '#333333',
];

const _customColorHistoryKey = 'themeEditorCustomColorHistory';
const _customColorHistoryLimit = 6;

// ─── Color helpers ────────────────────────────────────────────────────────────

Color _hex(String hex) {
  final clean = hex.replaceFirst('#', '');
  if (clean.length == 6) return Color(int.parse('FF$clean', radix: 16));
  if (clean.length == 8) return Color(int.parse(clean, radix: 16));
  return const Color(0xFF7996CE);
}

String _toHex(Color c) {
  final r = (c.r * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  final g = (c.g * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  final b = (c.b * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#$r$g$b'.toUpperCase();
}

Future<void> _pickCustomFont(
  BuildContext context,
  void Function(ThemePreset Function(ThemePreset)) onUpdate, {
  required bool isUi,
  required ThemePreset preset,
}) async {
  try {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['ttf', 'otf', 'woff', 'woff2'],
      dialogTitle: 'theme_select_font'.tr(),
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes ?? (file.path != null ? await File(file.path!).readAsBytes() : null);
    if (bytes == null) return;
    final fontName = file.name.replaceAll(RegExp(r'\.(ttf|otf|woff2?)$', caseSensitive: false), '');
    final dataUri = 'data:font/ttf;base64,${base64Encode(bytes)}';
    if (isUi) {
      onUpdate((p) => p.copyWith(
        uiFontMode: 'custom',
        customFont: dataUri,
        customFontName: fontName,
      ));
    } else {
      onUpdate((p) => p.copyWith(
        chatFontMode: 'custom',
        chatFont: dataUri,
        chatFontName: fontName,
      ));
    }
  } catch (e) {
    if (context.mounted) {
        GlazeErrorDialog.show(context, e, prefix: 'theme_failed_load_font'.tr());
    }
  }
}

// ─── Main screen ──────────────────────────────────────────────────────────────

class ThemeEditorScreen extends ConsumerStatefulWidget {
  const ThemeEditorScreen({super.key});

  @override
  ConsumerState<ThemeEditorScreen> createState() => _ThemeEditorScreenState();
}

class _ThemeEditorScreenState extends ConsumerState<ThemeEditorScreen> {
  int _activeTab = 0;
  Timer? _saveTimer;

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  ThemePreset get _preset => ref.read(themeProvider).activePreset;

  /// Live-update: apply immediately to state, debounce disk write.
  void _update(ThemePreset Function(ThemePreset) fn) {
    final next = fn(_preset);
    ref.read(themeProvider.notifier).updatePreset(next);
  }

  @override
  Widget build(BuildContext context) {
    final preset = ref.watch(themeProvider).activePreset;
    final isDefault = preset.id == 'default';
    // Material You drives its palette from the system; colors are locked but
    // fonts and background/element effects stay editable.
    final colorsLocked = preset.isMaterialYou;
    final statusBar = MediaQuery.of(context).padding.top;
    final bottomPad = ref.watch(navHeightProvider) + 20;
    // Top bar: back arrow + general/chat tabs (replaces the full-width header).
    const tabRowHeight = 66.0;
    final warningHeight = (isDefault || colorsLocked) ? 62.0 : 0.0;
    final totalTopPadding = statusBar + tabRowHeight + warningHeight;

    return GlazeScaffold(
      extendBodyBehindHeader: true,
      hideHeader: true,
      onBack: () => Navigator.pop(context),
      body: Stack(
        children: [
          Positioned.fill(
            child: AbsorbPointer(
              absorbing: isDefault,
              child: Opacity(
                opacity: isDefault ? 0.45 : 1.0,
                child: _ColorsLockedScope(
                  locked: colorsLocked,
                  child: SwipeTabSwitcher(
                    index: _activeTab,
                    length: 2,
                    onChanged: (i) => setState(() => _activeTab = i),
                    child: TabSlideSwitcher(
                      index: _activeTab,
                      child: IndexedStack(
                        index: _activeTab,
                        children: [
                          _GeneralTab(
                            preset: preset,
                            onUpdate: _update,
                            topPadding: totalTopPadding,
                            bottomPadding: bottomPad,
                          ),
                          _ChatTab(
                            preset: preset,
                            onUpdate: _update,
                            topPadding: totalTopPadding,
                            bottomPadding: bottomPad,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 10, 16, 8),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.arrow_back_ios_new_rounded,
                            size: 20,
                          ),
                          color: context.cs.primary,
                          onPressed: () => Navigator.pop(context),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: GlazeTabBar(
                            tabs: [
                              GlazeTabItem(
                                  label: 'tab_general'.tr(), icon: Icons.tune),
                              GlazeTabItem(
                                  label: 'tab_chat'.tr(),
                                  icon: Icons.chat_bubble_outline),
                            ],
                            activeIndex: _activeTab,
                            onChanged: (i) => setState(() => _activeTab = i),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isDefault || colorsLocked)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: context.cs.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: context.cs.outlineVariant),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline,
                                size: 16, color: context.cs.onSurfaceVariant),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                isDefault
                                    ? 'theme_default_not_editable'.tr()
                                    : 'theme_material_you_colors_locked'.tr(),
                                style: TextStyle(
                                    fontSize: 12,
                                    color: context.cs.onSurfaceVariant),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── General Tab ─────────────────────────────────────────────────────────────

class _GeneralTab extends StatelessWidget {
  final ThemePreset preset;
  final void Function(ThemePreset Function(ThemePreset)) onUpdate;
  final double topPadding;
  final double bottomPadding;

  const _GeneralTab({
    required this.preset,
    required this.onUpdate,
    required this.topPadding,
    required this.bottomPadding,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(0, topPadding + 8, 0, bottomPadding),
      children: [
        MenuGroup(
          header: 'theme_accent_color'.tr(),
          items: [
            _ColorRow(
              label: 'theme_accent_label'.tr(),
              value: preset.accentColor,
              palette: _presetColors,
              allowNull: false,
              showPreviewOverlay: false,
              onChanged: (v) =>
                  onUpdate((p) => p.copyWith(accentColor: v ?? '#7996CE')),
            ),
          ],
        ),
        MenuGroup(
          header: 'theme_app_font'.tr(),
          items: [
            _FontModeRow(
              label: 'tab_font'.tr(),
              mode: preset.uiFontMode,
              modes: const ['glaze', 'system', 'custom', 'google'],
              modeLabels: ['theme_font_glaze'.tr(), 'theme_font_system'.tr(), 'theme_font_custom'.tr(), 'theme_font_google'.tr()],
              onChanged: (v) async {
                if (v == 'custom') {
                  await _pickCustomFont(context, onUpdate, isUi: true, preset: preset);
                } else if (v == 'google') {
                  await _pickGoogleFont(context, onUpdate, isUi: true, preset: preset);
                } else {
                  onUpdate((p) => p.copyWith(uiFontMode: v));
                }
              },
            ),
            if (preset.uiFontMode == 'google' && preset.googleFontName != null)
              _GoogleFontDisplayRow(
                fontName: preset.googleFontName!,
                onTap: () => _pickGoogleFont(context, onUpdate, isUi: true, preset: preset),
                onClear: () => onUpdate((p) => p.copyWith(uiFontMode: 'glaze', googleFontName: null)),
              ),
            _ColorRow(
              label: 'theme_ui_text_color'.tr(),
              value: preset.uiTextColor,
              palette: _presetUiColors,
              allowNull: true,
              showPreviewOverlay: false,
              nullLabel: 'theme_auto'.tr(),
              onChanged: (v) => onUpdate((p) => p.copyWith(uiTextColor: v)),
            ),
            _ColorRow(
              label: 'theme_ui_text_gray_color'.tr(),
              value: preset.uiTextGrayColor,
              palette: _presetUiColors,
              allowNull: true,
              showPreviewOverlay: false,
              nullLabel: 'theme_auto'.tr(),
              onChanged: (v) =>
                  onUpdate((p) => p.copyWith(uiTextGrayColor: v)),
            ),
            _FontSizeRow(
              label: 'Font Size',
              value: preset.uiFontSize,
              min: 12,
              max: 20,
              onChanged: (v) => onUpdate((p) => p.copyWith(uiFontSize: v)),
            ),
            _SliderRow(
              label: 'theme_letter_spacing'.tr(),
              value: preset.uiLetterSpacing,
              min: -1,
              max: 3,
              divisions: 8,
              unit: 'px',
              onChanged: (v) =>
                  onUpdate((p) => p.copyWith(uiLetterSpacing: v)),
            ),
            _SliderRow(
              label: 'theme_font_weight'.tr(),
              value: preset.uiFontWeight.toDouble(),
              min: 100,
              max: 900,
              divisions: 8,
              unit: '',
              onChanged: (v) => onUpdate(
                (p) => p.copyWith(uiFontWeight: _weightFromSlider(v)),
              ),
            ),
          ],
        ),
        MenuGroup(
          header: 'theme_ui_effects'.tr(),
          items: [
            MenuSubHeader('theme_background_effects'.tr()),
            _ColorRow(
              label: 'Color',
              value: preset.uiColor,
              palette: _presetUiColors,
              allowNull: true,
              showPreviewOverlay: false,
              nullLabel: 'theme_auto'.tr(),
              onChanged: (v) => onUpdate((p) => p.copyWith(uiColor: v)),
            ),
            _SliderRow(
              label: 'theme_opacity'.tr(),
              value: preset.elementOpacity,
              min: 0.1,
              max: 1.0,
              divisions: 18,
              unit: '%',
              displayMultiplier: 100,
              onChanged: (v) =>
                  onUpdate((p) => p.copyWith(elementOpacity: v)),
            ),
            _SliderRow(
              label: 'theme_blur'.tr(),
              value: preset.elementBlur,
              min: 0,
              max: 40,
              divisions: 40,
              unit: 'px',
              onChanged: (v) => onUpdate((p) => p.copyWith(elementBlur: v)),
            ),
            _SliderRow(
              label: 'theme_noise_opacity'.tr(),
              value: preset.noiseOpacity,
              min: 0,
              max: 0.15,
              divisions: 30,
              unit: '%',
              displayMultiplier: 100,
              onChanged: (v) =>
                  onUpdate((p) => p.copyWith(noiseOpacity: v)),
            ),
            _SliderRow(
              label: 'theme_noise_intensity'.tr(),
              value: preset.noiseIntensity,
              min: 0.1,
              max: 2,
              divisions: 19,
              unit: '',
              onChanged: (v) =>
                  onUpdate((p) => p.copyWith(noiseIntensity: v)),
            ),
            MenuSubHeader('theme_border'.tr()),
            _ColorRow(
              label: 'theme_border_color'.tr(),
              value: preset.borderColor,
              palette: _presetUiColors,
              allowNull: true,
              showPreviewOverlay: false,
              nullLabel: 'theme_auto'.tr(),
              onChanged: (v) => onUpdate((p) => p.copyWith(borderColor: v)),
            ),
            _SliderRow(
              label: 'theme_border_width'.tr(),
              value: preset.borderWidth,
              min: 0,
              max: 5,
              divisions: 10,
              unit: 'px',
              onChanged: (v) => onUpdate((p) => p.copyWith(borderWidth: v)),
            ),
            _SliderRow(
              label: 'theme_border_opacity'.tr(),
              value: preset.borderOpacity,
              min: 0,
              max: 1,
              divisions: 20,
              unit: '%',
              displayMultiplier: 100,
              onChanged: (v) =>
                  onUpdate((p) => p.copyWith(borderOpacity: v)),
            ),
          ],
        ),
        MenuGroup(
          header: 'theme_background_effects'.tr(),
          items: [
            if (!preset.hasBgImage)
              _ColorRow(
                label: 'theme_ui_color'.tr(),
                value: preset.bgColor,
                palette: _presetUiColors,
                allowNull: true,
                showPreviewOverlay: false,
                nullLabel: 'theme_auto'.tr(),
                onChanged: (v) => onUpdate((p) => p.copyWith(bgColor: v)),
              ),
            _BgImageRow(
              hasImage: preset.hasBgImage,
              onPicked: (dataUri) =>
                  onUpdate((p) => p.copyWith(bgImage: dataUri)),
              onReset: () => onUpdate((p) => p.copyWith(bgImage: null)),
            ),
            if (preset.hasBgImage) ...[
              _SliderRow(
                label: 'theme_dimming'.tr(),
                // 0 = untouched image, 1 = fully black overlay.
                value: preset.bgDim,
                min: 0,
                max: 1,
                divisions: 20,
                unit: '%',
                displayMultiplier: 100,
                onChanged: (v) => onUpdate((p) => p.copyWith(bgDim: v)),
              ),
              _SliderRow(
                label: 'theme_bg_blur'.tr(),
                value: preset.bgBlur,
                min: 0,
                max: 20,
                divisions: 20,
                unit: 'px',
                onChanged: (v) => onUpdate((p) => p.copyWith(bgBlur: v)),
              ),
            ],
            _SliderRow(
              label: 'theme_bg_noise_opacity'.tr(),
              value: preset.bgNoiseOpacity,
              min: 0,
              max: 0.2,
              divisions: 40,
              unit: '%',
              displayMultiplier: 100,
              onChanged: (v) =>
                  onUpdate((p) => p.copyWith(bgNoiseOpacity: v)),
            ),
            _SliderRow(
              label: 'theme_bg_noise_intensity'.tr(),
              value: preset.bgNoiseIntensity,
              min: 0.1,
              max: 2,
              divisions: 19,
              unit: '',
              onChanged: (v) =>
                  onUpdate((p) => p.copyWith(bgNoiseIntensity: v)),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

// ─── Chat Tab ─────────────────────────────────────────────────────────────────

class _ChatTab extends StatefulWidget {
  final ThemePreset preset;
  final void Function(ThemePreset Function(ThemePreset)) onUpdate;
  final double topPadding;
  final double bottomPadding;

  const _ChatTab({
    required this.preset,
    required this.onUpdate,
    required this.topPadding,
    required this.bottomPadding,
  });

  @override
  State<_ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<_ChatTab> {
  int _activeSubTab = 0;
  late final ScrollController _fontScrollController;
  late final ScrollController _colorsScrollController;

  @override
  void initState() {
    super.initState();
    _fontScrollController = ScrollController();
    _colorsScrollController = ScrollController();
  }

  @override
  void dispose() {
    _fontScrollController.dispose();
    _colorsScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeScrollController = _activeSubTab == 0
        ? _fontScrollController
        : _colorsScrollController;

    return Column(
      children: [
        SizedBox(height: widget.topPadding),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Hero(
            tag: 'theme_chat_preview',
            child: Material(
              type: MaterialType.transparency,
              child: ThemeChatPreview(
                preset: widget.preset,
                borderColor: context.cs.outlineVariant,
              ),
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            controller: activeScrollController,
            padding: EdgeInsets.only(bottom: widget.bottomPadding),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: _LayoutPickerRow(
                    value: widget.preset.chatLayout,
                    onTap: () => _showLayoutPicker(context),
                  ),
                ),
                _ChatBackgroundGroup(
                  preset: widget.preset,
                  onUpdate: widget.onUpdate,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: GlazeTabBar(
                    tabs: [
                      GlazeTabItem(label: 'tab_font'.tr(), icon: Icons.text_fields),
                      GlazeTabItem(label: 'tab_colors'.tr(), icon: Icons.palette_outlined),
                    ],
                    activeIndex: _activeSubTab,
                    onChanged: (i) => setState(() => _activeSubTab = i),
                  ),
                ),
                SwipeTabSwitcher(
                  index: _activeSubTab,
                  length: 2,
                  onChanged: (i) => setState(() => _activeSubTab = i),
                  child: TabSlideSwitcher(
                    index: _activeSubTab,
                    child: _activeSubTab == 0
                        ? _ChatFontTab(
                            preset: widget.preset,
                            onUpdate: widget.onUpdate,
                          )
                        : _ChatColorsTab(
                            preset: widget.preset,
                            onUpdate: widget.onUpdate,
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _showLayoutPicker(BuildContext context) {
    return showChatLayoutPicker(
      context,
      current: widget.preset.chatLayout,
      onSelect: (layout) =>
          widget.onUpdate((p) => p.copyWith(chatLayout: layout)),
    );
  }
}

// ─── Chat → Background (shown above the font/colors tabs) ─────────────────────

class _ChatBackgroundGroup extends StatelessWidget {
  final ThemePreset preset;
  final void Function(ThemePreset Function(ThemePreset)) onUpdate;

  const _ChatBackgroundGroup({required this.preset, required this.onUpdate});

  @override
  Widget build(BuildContext context) {
    return MenuGroup(
      header: 'theme_chat_background'.tr(),
      items: [
        _FontModeRow(
          label: 'theme_chat_bg'.tr(),
          mode: preset.chatBgMode,
          modes: const ['inherit', 'color', 'avatar', 'custom'],
          modeLabels: [
            'theme_chat_bg_inherit'.tr(),
            'theme_chat_bg_color'.tr(),
            'theme_chat_bg_avatar'.tr(),
            'theme_chat_bg_custom'.tr(),
          ],
          onChanged: (v) => onUpdate((p) => p.copyWith(chatBgMode: v)),
        ),
        if (preset.chatBgMode == 'color')
          _ColorRow(
            label: 'theme_chat_bg_color'.tr(),
            value: preset.chatBgColor,
            palette: _presetUiColors,
            allowNull: true,
            showPreviewOverlay: false,
            nullLabel: 'theme_auto'.tr(),
            onChanged: (v) => onUpdate((p) => p.copyWith(chatBgColor: v)),
          ),
        if (preset.chatBgMode == 'custom')
          _BgImageRow(
            hasImage: preset.hasChatBgImage,
            onPicked: (dataUri) =>
                onUpdate((p) => p.copyWith(chatBgImage: dataUri)),
            onReset: () => onUpdate((p) => p.copyWith(chatBgImage: null)),
          ),
      ],
    );
  }
}

// ─── Chat → Font ──────────────────────────────────────────────────────────────

class _ChatFontTab extends StatelessWidget {
  final ThemePreset preset;
  final void Function(ThemePreset Function(ThemePreset)) onUpdate;

  const _ChatFontTab({required this.preset, required this.onUpdate});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        MenuGroup(
          header: 'theme_chat_font'.tr(),
          items: [
            _FontModeRow(
              label: 'tab_font'.tr(),
              mode: preset.chatFontMode,
              modes: const ['ui', 'glaze', 'system', 'custom', 'google'],
              modeLabels: ['theme_font_same_as_ui'.tr(), 'theme_font_glaze'.tr(), 'theme_font_system'.tr(), 'theme_font_custom'.tr(), 'theme_font_google'.tr()],
              onChanged: (v) async {
                if (v == 'custom') {
                  await _pickCustomFont(context, onUpdate, isUi: false, preset: preset);
                } else if (v == 'google') {
                  await _pickGoogleFont(context, onUpdate, isUi: false, preset: preset);
                } else {
                  onUpdate((p) => p.copyWith(chatFontMode: v));
                }
              },
            ),
            if (preset.chatFontMode == 'google' && preset.chatGoogleFontName != null)
              _GoogleFontDisplayRow(
                fontName: preset.chatGoogleFontName!,
                onTap: () => _pickGoogleFont(context, onUpdate, isUi: false, preset: preset),
                onClear: () => onUpdate((p) => p.copyWith(chatFontMode: 'ui', chatGoogleFontName: null)),
              ),
            _FontSizeRow(
              label: 'theme_chat_font_size'.tr(),
              value: preset.chatFontSize,
              min: 12,
              max: 24,
              onChanged: (v) => onUpdate((p) => p.copyWith(chatFontSize: v)),
            ),
            _SliderRow(
              label: 'theme_chat_letter_spacing'.tr(),
              value: preset.chatLetterSpacing,
              min: -1,
              max: 3,
              divisions: 8,
              unit: 'px',
              onChanged: (v) =>
                  onUpdate((p) => p.copyWith(chatLetterSpacing: v)),
            ),
            _SliderRow(
              label: 'theme_user_font_weight'.tr(),
              value: preset.userMessageFontWeight.toDouble(),
              min: 100,
              max: 900,
              divisions: 8,
              unit: '',
              onChanged: (v) => onUpdate(
                (p) => p.copyWith(userMessageFontWeight: _weightFromSlider(v)),
              ),
            ),
            _SliderRow(
              label: 'theme_char_font_weight'.tr(),
              value: preset.charMessageFontWeight.toDouble(),
              min: 100,
              max: 900,
              divisions: 8,
              unit: '',
              onChanged: (v) => onUpdate(
                (p) => p.copyWith(charMessageFontWeight: _weightFromSlider(v)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

// ─── Chat → Colors ────────────────────────────────────────────────────────────

class _ChatColorsTab extends ConsumerWidget {
  final ThemePreset preset;
  final void Function(ThemePreset Function(ThemePreset)) onUpdate;

  const _ChatColorsTab({required this.preset, required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isBubble = preset.chatLayout == 'bubble';
    final appSettings = ref.watch(appSettingsProvider).value ?? const AppSettings();
    final hideMessageId = preset.hideMessageId ?? appSettings.hideMessageId;
    final hideGenerationTime =
        preset.hideGenerationTime ?? appSettings.hideGenerationTime;
    final hideTokenCount =
        preset.hideTokenCount ?? appSettings.hideTokenCount;
    return Column(
      children: [
        if (isBubble)
          MenuGroup(
            header: 'theme_bubble_colors'.tr(),
            items: [
              _ColorRow(
                label: 'theme_user_bubble'.tr(),
                value: preset.userBubbleColor,
                palette: _presetColors,
                allowNull: true,
                nullLabel: 'theme_auto'.tr(),
                allowGradient: true,
                gradient: preset.userBubbleGradient,
                onGradientChanged: (v) =>
                    onUpdate((p) => p.copyWith(userBubbleGradient: v)),
                onChanged: (v) =>
                    onUpdate((p) => p.copyWith(userBubbleColor: v)),
              ),
              _ColorRow(
                label: 'theme_char_bubble'.tr(),
                value: preset.charBubbleColor,
                palette: _presetColors,
                allowNull: true,
                nullLabel: 'theme_auto'.tr(),
                allowGradient: true,
                gradient: preset.charBubbleGradient,
                onGradientChanged: (v) =>
                    onUpdate((p) => p.copyWith(charBubbleGradient: v)),
                onChanged: (v) =>
                    onUpdate((p) => p.copyWith(charBubbleColor: v)),
              ),
              _SliderRow(
                label: 'theme_user_bubble_radius'.tr(),
                value: preset.userBubbleRadius,
                min: 0,
                max: 36,
                divisions: 36,
                unit: 'px',
                onChanged: (v) =>
                    onUpdate((p) => p.copyWith(userBubbleRadius: v)),
              ),
              _SliderRow(
                label: 'theme_char_bubble_radius'.tr(),
                value: preset.charBubbleRadius,
                min: 0,
                max: 36,
                divisions: 36,
                unit: 'px',
                onChanged: (v) =>
                    onUpdate((p) => p.copyWith(charBubbleRadius: v)),
              ),
            ],
          ),
        MenuGroup(
          header: 'theme_identity'.tr(),
          items: [
            _SwitchRow(
              label: 'theme_user_avatar'.tr(),
              value: preset.showUserAvatar,
              onChanged: (v) =>
                  onUpdate((p) => p.copyWith(showUserAvatar: v)),
            ),
            _SwitchRow(
              label: 'theme_char_avatar'.tr(),
              value: preset.showCharAvatar,
              onChanged: (v) =>
                  onUpdate((p) => p.copyWith(showCharAvatar: v)),
            ),
            _SwitchRow(
              label: 'theme_user_name'.tr(),
              value: preset.showUserName,
              onChanged: (v) =>
                  onUpdate((p) => p.copyWith(showUserName: v)),
            ),
            _SwitchRow(
              label: 'theme_char_name'.tr(),
              value: preset.showCharName,
              onChanged: (v) =>
                  onUpdate((p) => p.copyWith(showCharName: v)),
            ),
          ],
        ),
        MenuGroup(
          header: 'theme_message_meta'.tr(),
          items: [
            // Tri-state, because these three also exist as app settings and the
            // preset wins over them (see chat_screen's `preset.x ?? app.x`).
            // The include switch is what "this preset overrides it" looks like;
            // turning it off clears the override and hands the row back to the
            // app setting, which is otherwise unreachable from the UI.
            _MetaOverrideRow(
              label: 'menu_show_msg_id'.tr(),
              overridden: preset.hideMessageId != null,
              shown: !hideMessageId,
              onOverrideChanged: (on) => onUpdate(
                (p) => p.copyWith(
                  hideMessageId: on ? appSettings.hideMessageId : null,
                ),
              ),
              onChanged: (show) =>
                  onUpdate((p) => p.copyWith(hideMessageId: !show)),
            ),
            _MetaOverrideRow(
              label: 'menu_show_gen_time'.tr(),
              overridden: preset.hideGenerationTime != null,
              shown: !hideGenerationTime,
              onOverrideChanged: (on) => onUpdate(
                (p) => p.copyWith(
                  hideGenerationTime: on ? appSettings.hideGenerationTime : null,
                ),
              ),
              onChanged: (show) =>
                  onUpdate((p) => p.copyWith(hideGenerationTime: !show)),
            ),
            _MetaOverrideRow(
              label: 'menu_show_token_count'.tr(),
              overridden: preset.hideTokenCount != null,
              shown: !hideTokenCount,
              onOverrideChanged: (on) => onUpdate(
                (p) => p.copyWith(
                  hideTokenCount: on ? appSettings.hideTokenCount : null,
                ),
              ),
              onChanged: (show) =>
                  onUpdate((p) => p.copyWith(hideTokenCount: !show)),
            ),
          ],
        ),
        MenuGroup(
          header: 'theme_reply_colors'.tr(),
          items: [
            _ColorRow(
              label: 'theme_user_reply'.tr(),
              value: preset.userQuoteColor,
              palette: _presetColors,
              allowNull: true,
              nullLabel: 'theme_auto'.tr(),
              onChanged: (v) =>
                  onUpdate((p) => p.copyWith(userQuoteColor: v)),
            ),
            _ColorRow(
              label: 'theme_char_reply'.tr(),
              value: preset.charQuoteColor,
              palette: _presetColors,
              allowNull: true,
              nullLabel: 'theme_auto'.tr(),
              onChanged: (v) =>
                  onUpdate((p) => p.copyWith(charQuoteColor: v)),
            ),
          ],
        ),
        MenuGroup(
          header: 'theme_text_colors'.tr(),
          items: [
            _ColorRow(
              label: 'theme_user_text'.tr(),
              value: preset.userTextColor,
              palette: _presetColors,
              allowNull: true,
              nullLabel: 'theme_auto'.tr(),
              onChanged: (v) =>
                  onUpdate((p) => p.copyWith(userTextColor: v)),
            ),
            _ColorRow(
              label: 'theme_char_text'.tr(),
              value: preset.charTextColor,
              palette: _presetColors,
              allowNull: true,
              nullLabel: 'theme_auto'.tr(),
              onChanged: (v) =>
                  onUpdate((p) => p.copyWith(charTextColor: v)),
            ),
          ],
        ),
        MenuGroup(
          header: 'theme_italic_colors'.tr(),
          items: [
            _ColorRow(
              label: 'theme_user_italic'.tr(),
              value: preset.userItalicColor,
              palette: _presetColors,
              allowNull: true,
              nullLabel: 'theme_auto'.tr(),
              onChanged: (v) =>
                  onUpdate((p) => p.copyWith(userItalicColor: v)),
            ),
            _ColorRow(
              label: 'theme_char_italic'.tr(),
              value: preset.charItalicColor,
              palette: _presetColors,
              allowNull: true,
              nullLabel: 'theme_auto'.tr(),
              onChanged: (v) =>
                  onUpdate((p) => p.copyWith(charItalicColor: v)),
            ),
          ],
        ),
        // Desktop-only: message background opacity for layout-default.
        // On mobile the backdrop is always transparent (no impact on perf).
        if (!isBubble &&
            (Platform.isWindows || Platform.isLinux || Platform.isMacOS))
          MenuGroup(
            header: 'theme_desktop_effects'.tr(),
            items: [
              _SliderRow(
                label: 'theme_text_bg_opacity'.tr(),
                value: preset.textBgOpacity,
                min: 0.0,
                max: 0.8,
                divisions: 16,
                unit: '%',
                displayMultiplier: 100,
                onChanged: (v) =>
                    onUpdate((p) => p.copyWith(textBgOpacity: v)),
              ),
            ],
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}

// ─── Shared row widgets ───────────────────────────────────────────────────────

// ─── Slider row ───────────────────────────────────────────────────────────────

class _SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String unit;
  final double displayMultiplier;
  final ValueChanged<double> onChanged;

  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.unit,
    required this.onChanged,
    this.displayMultiplier = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final display = (value * displayMultiplier);
    final displayStr = display == display.roundToDouble()
        ? display.toInt().toString()
        : display.toStringAsFixed(1);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(label, style: TextStyle(fontSize: 15, color: context.cs.onSurfaceVariant, fontWeight: FontWeight.w400)),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              unit == '%' ? '$displayStr%' : unit.isEmpty ? displayStr : '$displayStr$unit',
              style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

/// A message-metadata row that can either follow the app setting or override it
/// for this preset.
///
/// The small include switch on the left is the override; the trailing switch is
/// the value, disabled while the row follows the app setting so it reads as
/// inherited rather than editable.
class _MetaOverrideRow extends StatelessWidget {
  final String label;
  final bool overridden;
  final bool shown;
  final ValueChanged<bool> onOverrideChanged;
  final ValueChanged<bool> onChanged;

  const _MetaOverrideRow({
    required this.label,
    required this.overridden,
    required this.shown,
    required this.onOverrideChanged,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return MenuSwitchItem(
      label: label,
      description: overridden
          ? 'theme_override_app_setting'.tr()
          : 'theme_follows_app_setting'.tr(),
      included: overridden,
      onIncludedChanged: onOverrideChanged,
      value: shown,
      onChanged: onChanged,
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                color: context.cs.onSurfaceVariant,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _LayoutPickerRow extends StatelessWidget {
  final String value;
  final VoidCallback onTap;

  const _LayoutPickerRow({
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isBubble = value == 'bubble';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: context.cs.surfaceContainerHighest.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: context.cs.outlineVariant),
          ),
          child: Row(
            children: [
              Icon(
                isBubble ? Icons.chat_bubble_outline : Icons.view_stream_outlined,
                size: 18,
                color: context.cs.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                  Text(
                    'menu_chat_layout'.tr(),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: context.cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isBubble ? 'layout_bubble'.tr() : 'layout_default'.tr(),
                      style: TextStyle(
                        fontSize: 12,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: context.cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Font size row (System / Custom toggle + slider) ─────────────────────────

class _FontSizeRow extends StatelessWidget {
  final String label;
  final dynamic value; // 'system' or num
  final double min;
  final double max;
  final ValueChanged<dynamic> onChanged;

  const _FontSizeRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  bool get _isSystem => value is String;
  double get _numVal => _isSystem ? 14.0 : (value as num).toDouble();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          child: Row(
            children: [
              SizedBox(
                width: 130,
                child: Text(label, style: TextStyle(fontSize: 15, color: context.cs.onSurfaceVariant, fontWeight: FontWeight.w400)),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => onChanged(_isSystem ? 14.0 : 'system'),
                child: Text(
                  _isSystem ? 'theme_system_font_size'.tr() : '${_numVal.toInt()}px',
                  style: TextStyle(color: context.cs.primary),
                ),
              ),
            ],
          ),
        ),
        if (!_isSystem)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const SizedBox(width: 130),
                Expanded(
                  child: Slider(
                    value: _numVal.clamp(min, max),
                    min: min,
                    max: max,
                    divisions: (max - min).toInt(),
                    onChanged: (v) => onChanged(v),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    '${_numVal.toInt()}px',
                    style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

int _weightFromSlider(double value) {
  return (((value / 100).round()) * 100).clamp(100, 900);
}

// ─── Font mode row ───────────────────────────────────────────────────────────

class _FontModeRow extends StatelessWidget {
  final String label;
  final String mode;
  final List<String> modes;
  final List<String> modeLabels;
  final ValueChanged<String> onChanged;

  const _FontModeRow({
    required this.label,
    required this.mode,
    required this.modes,
    required this.modeLabels,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(label, style: TextStyle(fontSize: 15, color: context.cs.onSurfaceVariant, fontWeight: FontWeight.w400)),
          ),
          const Spacer(),
          GestureDetector(
            onTap: () {
              GlazeBottomSheet.show<void>(
                context,
                title: label,
                items: List.generate(
                  modes.length,
                  (i) => BottomSheetItem(
                    label: modeLabels[i],
                    icon: modes[i] == mode ? Icons.check : null,
                    onTap: () {
                      Navigator.pop(context);
                      if (modes[i] != mode) onChanged(modes[i]);
                    },
                  ),
                ),
              );
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  modeLabels[modes.indexOf(mode).clamp(0, modeLabels.length - 1)],
                  style: TextStyle(color: context.cs.primary, fontSize: 14),
                ),
                Icon(Icons.arrow_drop_down, color: context.cs.primary),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Color row ───────────────────────────────────────────────────────────────

/// Propagates a "colors are locked" flag (built-in Material You theme) down to
/// every [_ColorRow] without threading a parameter through each call site.
class _ColorsLockedScope extends InheritedWidget {
  final bool locked;

  const _ColorsLockedScope({required this.locked, required super.child});

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_ColorsLockedScope>()
          ?.locked ??
      false;

  @override
  bool updateShouldNotify(_ColorsLockedScope oldWidget) =>
      oldWidget.locked != locked;
}

class _ColorRow extends ConsumerWidget {
  final String label;
  final String? value; // null = auto
  final List<String> palette;
  final bool allowNull;
  final String nullLabel;
  final bool showPreviewOverlay;
  final ValueChanged<String?> onChanged;
  // Gradient support (bubble rows). When [allowGradient] is true the picker
  // exposes a Solid/Gradient mode toggle. [gradient] is the encoded
  // "angle|#hex1|#hex2" string (null = solid mode).
  final bool allowGradient;
  final String? gradient;
  final ValueChanged<String?>? onGradientChanged;

  const _ColorRow({
    required this.label,
    required this.value,
    required this.palette,
    required this.allowNull,
    required this.onChanged,
    this.nullLabel = 'Auto',
    this.showPreviewOverlay = true,
    this.allowGradient = false,
    this.gradient,
    this.onGradientChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locked = _ColorsLockedScope.of(context);
    final gradientValue =
        allowGradient ? _decodeGradient(gradient) : null;
    final current = value != null && value!.isNotEmpty ? _hex(value!) : null;
    final textOnCurrent = current != null
        ? (current.computeLuminance() > 0.5 ? Colors.black : Colors.white)
        : context.cs.onSurfaceVariant;
    return Opacity(
      opacity: locked ? 0.4 : 1.0,
      child: InkWell(
        onTap: locked
            ? null
            : () => _openPicker(context, ref.read(themeProvider).activePreset),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: context.cs.onSurfaceVariant,
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
              if (locked)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(Icons.lock_outline,
                      size: 16, color: context.cs.onSurfaceVariant),
                ),
              Container(
                constraints: const BoxConstraints(minWidth: 48),
                height: 24,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: gradientValue == null
                      ? (current ?? Colors.transparent)
                      : null,
                  gradient: gradientValue,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: context.cs.outlineVariant.withValues(
                        alpha: (current == null && gradientValue == null)
                            ? 0.6
                            : 0.3),
                    width: 1,
                  ),
                ),
                child: (current == null && gradientValue == null)
                    ? Text(
                        nullLabel,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: textOnCurrent,
                        ),
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Decode the stored "angle|#hex1|#hex2" string into a [LinearGradient]
  /// for the row swatch. Returns null when absent/invalid.
  static LinearGradient? _decodeGradient(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.split('|');
    if (parts.length != 3) return null;
    final angle = double.tryParse(parts[0]);
    if (angle == null) return null;
    final rad = angle * 3.141592653589793 / 180.0;
    final dx = math.sin(rad);
    final dy = -math.cos(rad);
    return LinearGradient(
      begin: Alignment(-dx, -dy),
      end: Alignment(dx, dy),
      colors: [_hex(parts[1]), _hex(parts[2])],
    );
  }

  Future<void> _openPicker(BuildContext context, ThemePreset previewPreset) async {
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierDismissible: true,
        barrierColor: Colors.black54,
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (context, animation, secondaryAnimation) {
          return _ColorPickerOverlay(
            showPreviewOverlay: showPreviewOverlay,
            previewPreset: previewPreset,
            current: value,
            palette: palette,
            allowNull: allowNull,
            nullLabel: nullLabel,
            onChanged: onChanged,
            allowGradient: allowGradient,
            gradient: gradient,
            onGradientChanged: onGradientChanged,
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation,
            child: child,
          );
        },
      ),
    );
  }
}

class _ColorPickerOverlay extends StatefulWidget {
  final bool showPreviewOverlay;
  final ThemePreset previewPreset;
  final String? current;
  final List<String> palette;
  final bool allowNull;
  final String nullLabel;
  final ValueChanged<String?> onChanged;
  final bool allowGradient;
  final String? gradient;
  final ValueChanged<String?>? onGradientChanged;

  const _ColorPickerOverlay({
    required this.showPreviewOverlay,
    required this.previewPreset,
    required this.current,
    required this.palette,
    required this.allowNull,
    required this.nullLabel,
    required this.onChanged,
    this.allowGradient = false,
    this.gradient,
    this.onGradientChanged,
  });

  @override
  State<_ColorPickerOverlay> createState() => _ColorPickerOverlayState();
}

class _ColorPickerOverlayState extends State<_ColorPickerOverlay>
    with SingleTickerProviderStateMixin {
  static const double _dismissThreshold = 80;
  static const double _previewTop = 8.0;
  // Vertical gap between the preview's bottom edge and the sheet's top.
  static const double _previewGap = 8.0;
  // Never let the sheet collapse below this even if the preview is very tall.
  static const double _minSheetHeight = 220.0;

  final GlobalKey _previewKey = GlobalKey();
  double _previewHeight = 0;
  double _dragOffset = 0;
  bool _closing = false;

  Future<void> _close() async {
    if (_closing) return;
    setState(() {
      _closing = true;
      _dragOffset = 0;
    });
    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// Measure the rendered preview after layout so the sheet below can be capped
  /// to the remaining space (and scroll within it) instead of overlapping it.
  void _measurePreview() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _previewKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final h = box.size.height;
      if ((h - _previewHeight).abs() > 0.5) {
        setState(() => _previewHeight = h);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.showPreviewOverlay) _measurePreview();
    return SafeArea(
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availH = constraints.maxHeight;
          double? sheetMax;
          if (widget.showPreviewOverlay && _previewHeight > 0) {
            // Sheet has a fixed 12px top padding (the Padding below) on top of
            // the space taken by the preview.
            final reserved = _previewTop + _previewHeight + _previewGap + 12;
            sheetMax = (availH - reserved).clamp(_minSheetHeight, availH);
          }
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _close,
                ),
              ),
              if (widget.showPreviewOverlay)
                Positioned(
                  top: _previewTop,
                  left: 16.0,
                  right: 16.0,
                  child: KeyedSubtree(
                    key: _previewKey,
                    child: IgnorePointer(
                      child: Hero(
                        tag: 'theme_chat_preview',
                        child: Material(
                          type: MaterialType.transparency,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.28),
                                  blurRadius: 22,
                                  offset: const Offset(0, 10),
                                ),
                              ],
                            ),
                            child: ThemeChatPreview(
                              preset: widget.previewPreset,
                              borderColor: context.cs.outlineVariant
                                  .withValues(alpha: 0.75),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              Align(
                alignment: Alignment.bottomCenter,
                child: AnimatedSlide(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeInOutCubic,
                  offset: _closing
                      ? const Offset(0, 1.05)
                      : Offset(0, _dragOffset / 400),
                  child: Transform.translate(
                    offset: Offset(0, _dragOffset),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: (details) {
                        if (details.primaryDelta == null) return;
                        final next = (_dragOffset + details.primaryDelta!)
                            .clamp(0.0, 400.0);
                        setState(() => _dragOffset = next);
                      },
                      onVerticalDragEnd: (details) {
                        final velocity = details.primaryVelocity ?? 0;
                        if (_dragOffset > _dismissThreshold || velocity > 700) {
                          _close();
                          return;
                        }
                        setState(() => _dragOffset = 0);
                      },
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                        child: _ColorPickerSheet(
                          current: widget.current,
                          palette: widget.palette,
                          allowNull: widget.allowNull,
                          nullLabel: widget.nullLabel,
                          onChanged: widget.onChanged,
                          onClose: _close,
                          allowGradient: widget.allowGradient,
                          gradient: widget.gradient,
                          onGradientChanged: widget.onGradientChanged,
                          maxHeight: sheetMax,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ─── Background image row ─────────────────────────────────────────────────────

class _BgImageRow extends StatelessWidget {
  final bool hasImage;
  final ValueChanged<String> onPicked;
  final VoidCallback onReset;

  const _BgImageRow({
    required this.hasImage,
    required this.onPicked,
    required this.onReset,
  });

  Future<void> _pick(BuildContext context) async {
    try {
      // Picker is left unrestricted (FileType.any) so AVIF/WebP stay selectable
      // on every platform; the accepted formats are enforced below instead.
      final result = await FilePicker.pickFiles(
        type: FileType.any,
      dialogTitle: 'theme_select_image'.tr(),
      withData: true,
    );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.first;
      final path = picked.path;
      if (path == null) return;
      // Accept only formats that render reliably as a background. Anything else
      // (gif animations aside — those are fine — but mp4/webm/etc.) is rejected
      // here rather than silently saved with a wrong mime, which corrupts the
      // preset and makes the previous background reappear on the next change.
      const mimeByExt = <String, String>{
        'gif': 'image/gif',
        'jpg': 'image/jpeg',
        'jpeg': 'image/jpeg',
        'png': 'image/png',
        'avif': 'image/avif',
        'webp': 'image/webp',
      };
      final ext = picked.extension?.toLowerCase() ??
          path.split('.').last.toLowerCase();
      final mime = mimeByExt[ext];
      if (mime == null) {
        if (context.mounted) {
          GlazeErrorDialog.show(
            context,
            'theme_unsupported_image_format'.tr(),
          );
        }
        return;
      }
      final bytes = await File(path).readAsBytes();
      final dataUri = 'data:$mime;base64,${base64Encode(bytes)}';
      onPicked(dataUri);
    } catch (e) {
      if (context.mounted) {
        GlazeErrorDialog.show(context, e, prefix: 'theme_failed_load_image'.tr());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => _pick(context),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.image_outlined,
                    size: 22, color: const Color(0xFF99A2AD)),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    hasImage
                    ? 'theme_replace_background_image'.tr()
                    : 'theme_select_image'.tr(),
                    style: TextStyle(
                      color: context.cs.onSurfaceVariant,
                      fontSize: 15,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (hasImage)
          InkWell(
            onTap: onReset,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.delete_outline,
                      size: 22, color: Color(0xFFFF4444)),
                  SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      'theme_reset_background'.tr(),
                      style: TextStyle(
                        color: Color(0xFFFF4444),
                        fontSize: 15,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ─── Color picker bottom sheet ────────────────────────────────────────────────

class _ColorPickerSheet extends ConsumerStatefulWidget {
  final String? current;
  final List<String> palette;
  final bool allowNull;
  final String nullLabel;
  final ValueChanged<String?> onChanged;
  final Future<void> Function() onClose;
  final bool allowGradient;
  final String? gradient;
  final ValueChanged<String?>? onGradientChanged;

  /// Pixel cap so the sheet fits below the pinned preview and scrolls instead
  /// of overlapping it. Null = fall back to the default factor-based height.
  final double? maxHeight;

  const _ColorPickerSheet({
    required this.current,
    required this.palette,
    required this.allowNull,
    required this.nullLabel,
    required this.onChanged,
    required this.onClose,
    this.allowGradient = false,
    this.gradient,
    this.onGradientChanged,
    this.maxHeight,
  });

  @override
  ConsumerState<_ColorPickerSheet> createState() => _ColorPickerSheetState();
}

class _ColorPickerSheetState extends ConsumerState<_ColorPickerSheet> {
  late TextEditingController _hexCtrl;
  late String _committedHex;
  late String _lastCustomHex;
  List<String> _recentCustomHexes = const [];
  String? _error;
  bool _isHslMode = true;
  bool _showAdvancedEditor = false;
  late double _h, _s, _l;
  late int _r, _g, _b;
  bool _suppressSliderSync = false;

  // ── Gradient mode state ──
  bool _gradientMode = false;
  int _activeStop = 0; // 0 = first color, 1 = second color
  late Color _gColor1;
  late Color _gColor2;
  double _gAngle = 135;

  @override
  void initState() {
    super.initState();
    _committedHex = widget.current ?? '#7996CE';
    _lastCustomHex = _committedHex;
    _hexCtrl = TextEditingController(text: _committedHex);
    final currentColor = _hex(_committedHex);
    final hsl = HSLColor.fromColor(currentColor);
    _h = hsl.hue;
    _s = hsl.saturation;
    _l = hsl.lightness;
    _r = (currentColor.r * 255).round();
    _g = (currentColor.g * 255).round();
    _b = (currentColor.b * 255).round();
    _initGradientState(currentColor);
    _loadCustomColorHistory();
  }

  void _initGradientState(Color fallback) {
    _gColor1 = fallback;
    _gColor2 = _defaultSecondStop(fallback);
    final raw = widget.gradient;
    if (widget.allowGradient && raw != null && raw.isNotEmpty) {
      final parts = raw.split('|');
      if (parts.length == 3) {
        _gAngle = double.tryParse(parts[0]) ?? 135;
        _gColor1 = _parseHexSafe(parts[1]) ?? fallback;
        _gColor2 = _parseHexSafe(parts[2]) ?? _defaultSecondStop(fallback);
        _gradientMode = true;
        _showAdvancedEditor = true;
        _loadEditorFromColor(_gColor1);
      }
    }
  }

  /// A visibly-distinct second stop seeded from the first color so enabling
  /// gradient mode doesn't look like a flat color.
  static Color _defaultSecondStop(Color base) {
    final hsl = HSLColor.fromColor(base);
    final shift = hsl.lightness > 0.5 ? -0.22 : 0.22;
    return hsl
        .withLightness((hsl.lightness + shift).clamp(0.0, 1.0))
        .toColor();
  }

  /// Load the HSL/RGB/hex editor fields from [c] without emitting a change.
  void _loadEditorFromColor(Color c) {
    final hsl = HSLColor.fromColor(c);
    _h = hsl.hue;
    _s = hsl.saturation;
    _l = hsl.lightness;
    _r = (c.r * 255).round();
    _g = (c.g * 255).round();
    _b = (c.b * 255).round();
    _committedHex = _toHex(c);
    _setHexText(_committedHex);
    _error = null;
  }

  @override
  void dispose() {
    _hexCtrl.dispose();
    super.dispose();
  }

  void _setHexText(String hex) {
    if (_hexCtrl.text == hex) return;
    _hexCtrl.value = TextEditingValue(
      text: hex,
      selection: TextSelection.collapsed(offset: hex.length),
    );
  }

  void _syncFromColor(Color color, {required bool updateHsl}) {
    final hex = _toHex(color);
    _suppressSliderSync = true;
    if (updateHsl) {
      final hsl = HSLColor.fromColor(color);
      _h = hsl.hue;
      _s = hsl.saturation;
      _l = hsl.lightness;
    }
    _r = (color.r * 255).round();
    _g = (color.g * 255).round();
    _b = (color.b * 255).round();
    _committedHex = hex;
    if (_showAdvancedEditor) {
      _lastCustomHex = hex;
    }
    _setHexText(hex);
    setState(() => _error = null);
    _sink(hex);
    _suppressSliderSync = false;
  }

  /// Route an applied color to either the solid callback or the active
  /// gradient stop, depending on the current mode.
  void _sink(String hex) {
    if (_gradientMode) {
      final c = _parseHexSafe(hex) ?? const Color(0xFF7996CE);
      if (_activeStop == 0) {
        _gColor1 = c;
      } else {
        _gColor2 = c;
      }
      _emitGradient();
    } else {
      widget.onChanged(hex);
    }
  }

  void _emitGradient() {
    final g = BubbleGradient(_gAngle, _gColor1, _gColor2);
    widget.onGradientChanged?.call(g.encode());
  }

  void _setGradientMode(bool on) {
    if (on == _gradientMode) return;
    setState(() {
      _gradientMode = on;
      if (on) {
        _activeStop = 0;
        _showAdvancedEditor = true;
        _loadEditorFromColor(_gColor1);
        _emitGradient();
      } else {
        widget.onGradientChanged?.call(null);
        // Re-assert the solid color so the bubble falls back correctly.
        widget.onChanged(_committedHex.isEmpty ? null : _committedHex);
      }
    });
  }

  void _selectStop(int i) {
    if (i == _activeStop) return;
    setState(() {
      _activeStop = i;
      _showAdvancedEditor = true;
      _loadEditorFromColor(i == 0 ? _gColor1 : _gColor2);
    });
  }

  void _applyExternalColor(Color color) {
    _syncFromColor(color, updateHsl: true);
  }

  void _applyHslColor(Color color) {
    _syncFromColor(color, updateHsl: false);
  }

  void _onHexChanged(String hex) {
    final clean = hex.trim();
    if (clean.isEmpty) {
      setState(() => _error = null);
      if (widget.allowNull) widget.onChanged(null);
      return;
    }
    final h = clean.startsWith('#') ? clean : '#$clean';
    final parsed = _parseHexSafe(h);
    if (parsed == null) {
      setState(() => _error = clean.length >= 6 ? 'theme_invalid_hex_label'.tr() : null);
      return;
    }
    setState(() => _error = null);
    _applyExternalColor(parsed);
  }

  void _onHslChanged() {
    if (_suppressSliderSync) return;
    final color = HSLColor.fromAHSL(1.0, _h, _s.clamp(0.0, 1.0), _l.clamp(0.0, 1.0)).toColor();
    _applyHslColor(color);
  }

  void _onRgbChanged() {
    if (_suppressSliderSync) return;
    final color = Color.fromARGB(255, _r.clamp(0, 255), _g.clamp(0, 255), _b.clamp(0, 255));
    _applyExternalColor(color);
  }

  Color? _parseHexSafe(String hex) {
    try {
      final clean = hex.replaceFirst('#', '');
      if (clean.length == 6) return Color(int.parse('FF$clean', radix: 16));
      if (clean.length == 8) return Color(int.parse(clean, radix: 16));
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadCustomColorHistory() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final stored = prefs.getStringList(_customColorHistoryKey) ?? const [];
    final cleaned = stored
        .map((e) => e.trim().toUpperCase())
        .where((e) => RegExp(r'^#[0-9A-F]{6}$').hasMatch(e))
        .take(_customColorHistoryLimit)
        .toList();
    if (!mounted) return;
    setState(() {
      _recentCustomHexes = cleaned;
      if (cleaned.isNotEmpty) {
        _lastCustomHex = cleaned.first;
      }
    });
  }

  Future<void> _saveCustomColorHistory(String hex) async {
    final normalized = hex.trim().toUpperCase();
    if (!RegExp(r'^#[0-9A-F]{6}$').hasMatch(normalized)) return;
    final next = [
      normalized,
      ..._recentCustomHexes.where((item) => item.toUpperCase() != normalized),
    ].take(_customColorHistoryLimit).toList();
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setStringList(_customColorHistoryKey, next);
    if (!mounted) return;
    setState(() {
      _recentCustomHexes = next;
      _lastCustomHex = normalized;
    });
  }

  Future<void> _confirmAndClose() async {
    if (_showAdvancedEditor && _committedHex.trim().isNotEmpty) {
      await _saveCustomColorHistory(_committedHex);
    }
    if (!mounted) return;
    await widget.onClose();
  }

  bool _isPaletteSelected(String hex) {
    return _toHex(_hex(hex)).toUpperCase() == _committedHex.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final currentColor = _parseHexSafe(_committedHex) ?? const Color(0xFF7996CE);
    final isAutoSelected = widget.allowNull && _hexCtrl.text.trim().isEmpty;
    final primaryPalette = widget.palette.skip(1).take(5).toList();
    return GlazeBottomSheetFrame(
      maxHeightFactor: 0.82,
      maxHeight: widget.maxHeight,
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          top: 4,
          right: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom +
              MediaQuery.of(context).padding.bottom +
              8,
        ),
        child: SingleChildScrollView(
          child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          _PickerIconButton(
                            icon: Icons.arrow_back_rounded,
                            onTap: _confirmAndClose,
                            iconColor: cs.primary,
                            borderColor: cs.outlineVariant,
                            tintColor: cs.surface,
                            size: 56,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Container(
                              height: 56,
                              decoration: BoxDecoration(
                                color: _gradientMode ? null : currentColor,
                                gradient: _gradientMode
                                    ? LinearGradient(
                                        begin: Alignment.centerLeft,
                                        end: Alignment.centerRight,
                                        colors: [_gColor1, _gColor2],
                                      )
                                    : null,
                                borderRadius: BorderRadius.circular(28),
                                border: Border.all(
                                  color: cs.onSurfaceVariant.withValues(alpha: 0.45),
                                  width: 1.5,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (widget.allowGradient) ...[
                        _ModeToggle(
                          isGradient: _gradientMode,
                          onSolid: () => _setGradientMode(false),
                          onGradient: () => _setGradientMode(true),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (_gradientMode) ...[
                        _AngleDialRow(
                          angle: _gAngle,
                          onChanged: (v) {
                            _gAngle = v;
                            _emitGradient();
                            setState(() {});
                          },
                        ),
                        const SizedBox(height: 12),
                        _GradientStopToggle(
                          activeStop: _activeStop,
                          color1: _gColor1,
                          color2: _gColor2,
                          onSelect: _selectStop,
                        ),
                        const SizedBox(height: 8),
                      ],
                      Align(
                        alignment: Alignment.center,
                        child: SizedBox(
                          width: ((widget.allowNull ? 1 : 0) + primaryPalette.length + 1) * 44.0 +
                              ((widget.allowNull ? 1 : 0) + primaryPalette.length) * 10.0,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                alignment: WrapAlignment.start,
                                runAlignment: WrapAlignment.start,
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                if (widget.allowNull && !_gradientMode)
                                  GestureDetector(
                                    onTap: () {
                                      setState(() {
                                        _hexCtrl.clear();
                                        _error = null;
                                        _committedHex = '';
                                        _showAdvancedEditor = false;
                                      });
                                      widget.onChanged(null);
                                    },
                                    child: Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        color: Colors.transparent,
                                        border: isAutoSelected
                                            ? Border.all(
                                                color: cs.onSurfaceVariant.withValues(alpha: 0.45),
                                                width: 1.5,
                                              )
                                            : null,
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(Icons.auto_awesome,
                                          size: 18, color: cs.onSurfaceVariant),
                                    ),
                                  ),
                                ...primaryPalette.map((hex) {
                                  final color = _hex(hex);
                                  final isSelected = _isPaletteSelected(hex);
                                  return GestureDetector(
                                    onTap: () {
                                      _applyExternalColor(color);
                                      if (!_gradientMode) {
                                        setState(() => _showAdvancedEditor = false);
                                      }
                                    },
                                    child: Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        color: color,
                                        shape: BoxShape.circle,
                                        border: isSelected
                                            ? Border.all(
                                                color: cs.onSurfaceVariant.withValues(alpha: 0.45),
                                                width: 1.5,
                                              )
                                            : null,
                                      ),
                                    ),
                                  );
                                }),
                                GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      _showAdvancedEditor = !_showAdvancedEditor;
                                      if (_showAdvancedEditor) {
                                        _applyExternalColor(_hex(_lastCustomHex));
                                      }
                                    });
                                  },
                                  child: Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: _showAdvancedEditor
                                          ? currentColor
                                          : cs.surfaceContainerHighest.withValues(alpha: 0.35),
                                      shape: BoxShape.circle,
                                      border: _showAdvancedEditor
                                          ? Border.all(
                                              color: cs.onSurfaceVariant.withValues(alpha: 0.45),
                                              width: 1.5,
                                            )
                                          : null,
                                    ),
                                    child: Icon(
                                      Icons.edit_outlined,
                                      size: 18,
                                      color: _showAdvancedEditor
                                          ? (currentColor.computeLuminance() > 0.5
                                              ? Colors.black
                                              : Colors.white)
                                          : cs.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                                ],
                              ),
                              if (_recentCustomHexes.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                Wrap(
                                  alignment: WrapAlignment.start,
                                  runAlignment: WrapAlignment.start,
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: _recentCustomHexes.map((hex) {
                                    final color = _hex(hex);
                                    final isSelected = _showAdvancedEditor &&
                                        _committedHex.toUpperCase() == hex.toUpperCase();
                                    return GestureDetector(
                                      onTap: () {
                                        _applyExternalColor(color);
                                        setState(() {
                                          _lastCustomHex = hex;
                                          _showAdvancedEditor = true;
                                        });
                                      },
                                      child: Container(
                                        width: 44,
                                        height: 44,
                                        decoration: BoxDecoration(
                                          color: color,
                                          shape: BoxShape.circle,
                                          border: isSelected
                                              ? Border.all(
                                                  color: cs.onSurfaceVariant.withValues(alpha: 0.45),
                                                  width: 1.5,
                                                )
                                              : null,
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeInOutCubic,
                        alignment: Alignment.topCenter,
                        child: _showAdvancedEditor
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SizedBox(height: 16),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: GestureDetector(
                                          onTap: () => setState(() => _isHslMode = true),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(vertical: 8),
                                            decoration: BoxDecoration(
                                              color: _isHslMode ? cs.primary.withValues(alpha: 0.15) : Colors.transparent,
                                              borderRadius: const BorderRadius.horizontal(left: Radius.circular(8)),
                                              border: Border.all(color: cs.outlineVariant),
                                            ),
                                            child: Text(
                                              'HSL',
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                color: _isHslMode ? cs.primary : cs.onSurfaceVariant,
                                                fontWeight: FontWeight.w600,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: GestureDetector(
                                          onTap: () => setState(() => _isHslMode = false),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(vertical: 8),
                                            decoration: BoxDecoration(
                                              color: !_isHslMode ? cs.primary.withValues(alpha: 0.15) : Colors.transparent,
                                              borderRadius: const BorderRadius.horizontal(right: Radius.circular(8)),
                                              border: Border(
                                                top: BorderSide(color: cs.outlineVariant),
                                                right: BorderSide(color: cs.outlineVariant),
                                                bottom: BorderSide(color: cs.outlineVariant),
                                              ),
                                            ),
                                            child: Text(
                                              'RGB',
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                color: !_isHslMode ? cs.primary : cs.onSurfaceVariant,
                                                fontWeight: FontWeight.w600,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  if (_isHslMode) ...[
                                    _PickerSlider(
                                      label: 'Hue',
                                      value: _h,
                                      min: 0,
                                      max: 360,
                                      divisions: 360,
                                      display: '${_h.round()}\u00B0',
                                      onChanged: (v) { _h = v; _onHslChanged(); setState(() {}); },
                                    ),
                                    _PickerSlider(
                                      label: 'Saturation',
                                      value: _s * 100,
                                      min: 0,
                                      max: 100,
                                      divisions: 100,
                                      display: '${(_s * 100).round()}%',
                                      onChanged: (v) { _s = v / 100; _onHslChanged(); setState(() {}); },
                                    ),
                                    _PickerSlider(
                                      label: 'Lightness',
                                      value: _l * 100,
                                      min: 0,
                                      max: 100,
                                      divisions: 100,
                                      display: '${(_l * 100).round()}%',
                                      onChanged: (v) { _l = v / 100; _onHslChanged(); setState(() {}); },
                                    ),
                                  ] else ...[
                                    _PickerSlider(
                                      label: 'Red',
                                      value: _r.toDouble(),
                                      min: 0,
                                      max: 255,
                                      divisions: 255,
                                      display: '$_r',
                                      activeColor: const Color(0xFFFF4444),
                                      onChanged: (v) { _r = v.round(); _onRgbChanged(); setState(() {}); },
                                    ),
                                    _PickerSlider(
                                      label: 'Green',
                                      value: _g.toDouble(),
                                      min: 0,
                                      max: 255,
                                      divisions: 255,
                                      display: '$_g',
                                      activeColor: const Color(0xFF44BB44),
                                      onChanged: (v) { _g = v.round(); _onRgbChanged(); setState(() {}); },
                                    ),
                                    _PickerSlider(
                                      label: 'Blue',
                                      value: _b.toDouble(),
                                      min: 0,
                                      max: 255,
                                      divisions: 255,
                                      display: '$_b',
                                      activeColor: const Color(0xFF4488FF),
                                      onChanged: (v) { _b = v.round(); _onRgbChanged(); setState(() {}); },
                                    ),
                                  ],
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: _hexCtrl,
                                    decoration: InputDecoration(
                                      hintText: '#7996CE',
                                      labelText: 'theme_hex_color'.tr(),
                                      errorText: _error,
                                      prefixText:
                                          _hexCtrl.text.startsWith('#') ? null : '#',
                                      border: const OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                    onChanged: _onHexChanged,
                                  ),
                                  const SizedBox(height: 8),
                                ],
                              )
                            : const SizedBox(height: 8),
                      ),
                    ],
                  ),
          ),
        ),
    );
  }
}

/// Segmented Solid | Gradient toggle shown atop the bubble color picker.
class _ModeToggle extends StatelessWidget {
  final bool isGradient;
  final VoidCallback onSolid;
  final VoidCallback onGradient;

  const _ModeToggle({
    required this.isGradient,
    required this.onSolid,
    required this.onGradient,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: onSolid,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(
                color: !isGradient
                    ? cs.primary.withValues(alpha: 0.15)
                    : Colors.transparent,
                borderRadius:
                    const BorderRadius.horizontal(left: Radius.circular(8)),
                border: Border.all(color: cs.outlineVariant),
              ),
              child: Text(
                'theme_mode_solid'.tr(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: !isGradient ? cs.primary : cs.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: GestureDetector(
            onTap: onGradient,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(
                color: isGradient
                    ? cs.primary.withValues(alpha: 0.15)
                    : Colors.transparent,
                borderRadius:
                    const BorderRadius.horizontal(right: Radius.circular(8)),
                border: Border(
                  top: BorderSide(color: cs.outlineVariant),
                  right: BorderSide(color: cs.outlineVariant),
                  bottom: BorderSide(color: cs.outlineVariant),
                ),
              ),
              child: Text(
                'theme_mode_gradient'.tr(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isGradient ? cs.primary : cs.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Photoshop-style circular angle control for the gradient direction. The knob
/// is dragged around the ring; angle is measured in degrees clockwise from the
/// top (0° = upward), matching the gradient decode in [_ColorRow._decodeGradient].
class _AngleDialRow extends StatelessWidget {
  final double angle;
  final ValueChanged<double> onChanged;

  const _AngleDialRow({required this.angle, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        _AngleDial(angle: angle, onChanged: onChanged),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'theme_gradient_angle'.tr(),
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 2),
            Text(
              '${angle.round()}°',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                fontVariations: const [FontVariation('wght', 600)],
                color: cs.onSurface,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _AngleDial extends StatelessWidget {
  static const double size = 68;

  final double angle;
  final ValueChanged<double> onChanged;

  const _AngleDial({
    required this.angle,
    required this.onChanged,
  });

  void _update(Offset local) {
    final c = size / 2;
    final dx = local.dx - c;
    final dy = local.dy - c;
    if (dx == 0 && dy == 0) return;
    // 0° points up and increases clockwise: a = atan2(dx, -dy).
    var deg = math.atan2(dx, -dy) * 180.0 / math.pi;
    if (deg < 0) deg += 360;
    onChanged(deg.roundToDouble());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTapDown: (d) => _update(d.localPosition),
      onPanStart: (d) => _update(d.localPosition),
      onPanUpdate: (d) => _update(d.localPosition),
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _AngleDialPainter(
            angle: angle,
            ring: cs.outlineVariant,
            fill: cs.surfaceContainerHighest.withValues(alpha: 0.35),
            knob: cs.primary,
          ),
        ),
      ),
    );
  }
}

class _AngleDialPainter extends CustomPainter {
  final double angle;
  final Color ring;
  final Color fill;
  final Color knob;

  _AngleDialPainter({
    required this.angle,
    required this.ring,
    required this.fill,
    required this.knob,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 7;

    canvas.drawCircle(c, r, Paint()..color = fill);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = ring,
    );

    final rad = angle * math.pi / 180.0;
    final dir = Offset(math.sin(rad), -math.cos(rad));
    final knobCenter = c + dir * r;

    canvas.drawLine(
      c,
      knobCenter,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = knob,
    );
    canvas.drawCircle(c, 3, Paint()..color = knob);
    canvas.drawCircle(knobCenter, 6, Paint()..color = knob);
  }

  @override
  bool shouldRepaint(covariant _AngleDialPainter old) =>
      old.angle != angle ||
      old.ring != ring ||
      old.fill != fill ||
      old.knob != knob;
}

/// Two-swatch selector for which gradient stop the editor below is editing.
class _GradientStopToggle extends StatelessWidget {
  final int activeStop;
  final Color color1;
  final Color color2;
  final ValueChanged<int> onSelect;

  const _GradientStopToggle({
    required this.activeStop,
    required this.color1,
    required this.color2,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _stop(context,
              index: 0, color: color1, label: 'theme_gradient_color_1'.tr()),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _stop(context,
              index: 1, color: color2, label: 'theme_gradient_color_2'.tr()),
        ),
      ],
    );
  }

  Widget _stop(BuildContext context,
      {required int index, required Color color, required String label}) {
    final cs = Theme.of(context).colorScheme;
    final selected = activeStop == index;
    return GestureDetector(
      onTap: () => onSelect(index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? cs.primary
                : cs.outlineVariant.withValues(alpha: 0.6),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.35),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: selected ? cs.primary : cs.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PickerIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final Color iconColor;
  final Color borderColor;
  final Color tintColor;
  final double size;

  const _PickerIconButton({
    required this.icon,
    required this.onTap,
    required this.iconColor,
    required this.borderColor,
    required this.tintColor,
    this.size = 40,
  });

  @override
  State<_PickerIconButton> createState() => _PickerIconButtonState();
}

class _PickerIconButtonState extends State<_PickerIconButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _press;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 80),
      reverseDuration: const Duration(milliseconds: 150),
    );
    _scale = Tween<double>(begin: 1.0, end: 0.82).animate(
      CurvedAnimation(parent: _press, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: widget.onTap != null ? (_) => _press.forward() : null,
      onTapUp: widget.onTap != null ? (_) => _press.reverse() : null,
      onTapCancel: widget.onTap != null ? () => _press.reverse() : null,
      child: ScaleTransition(
        scale: _scale,
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: GlassSurface(
            borderRadius: BorderRadius.circular(widget.size / 2),
            tint: widget.tintColor,
            border: Border.all(color: widget.borderColor),
            child: Center(
              child: Icon(widget.icon, color: widget.iconColor, size: 20),
            ),
          ),
        ),
      ),
    );
  }
}

class _PickerSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final Color? activeColor;
  final ValueChanged<double> onChanged;

  const _PickerSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
    this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              activeColor: activeColor ?? cs.primary,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(display, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant), textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }
}

// ─── Google Fonts ─────────────────────────────────────────────────────────────

const _kPopularGoogleFonts = [
  'Roboto', 'Open Sans', 'Lato', 'Montserrat', 'Oswald',
  'Raleway', 'Poppins', 'Nunito', 'Ubuntu', 'Playfair Display',
  'Merriweather', 'PT Sans', 'Source Sans 3', 'Rubik', 'Work Sans',
  'Fira Sans', 'Quicksand', 'Barlow', 'Mulish', 'Karla',
  'Inconsolata', 'Bitter', 'Cabin', 'Lora', 'Josefin Sans',
  'Arimo', 'Dosis', 'Libre Baskerville', 'Oxygen', 'Crimson Text',
  'Exo 2', 'Abel', 'Comfortaa', 'Varela Round', 'Pacifico',
  'Lobster', 'Dancing Script', 'Satisfy', 'Caveat', 'Shadows Into Light',
  'Courier Prime', 'Space Mono', 'IBM Plex Mono', 'JetBrains Mono',
  'Anonymous Pro', 'Roboto Mono', 'Source Code Pro', 'Fira Code',
];

Future<void> _pickGoogleFont(
  BuildContext context,
  void Function(ThemePreset Function(ThemePreset)) onUpdate, {
  required bool isUi,
  required ThemePreset preset,
}) async {
  final selected = await showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _GoogleFontPickerSheet(),
  );
  if (selected != null && selected.isNotEmpty) {
    if (isUi) {
      onUpdate((p) => p.copyWith(uiFontMode: 'google', googleFontName: selected));
    } else {
      onUpdate((p) => p.copyWith(chatFontMode: 'google', chatGoogleFontName: selected));
    }
  }
}

class _GoogleFontPickerSheet extends StatefulWidget {
  @override
  State<_GoogleFontPickerSheet> createState() => _GoogleFontPickerSheetState();
}

class _GoogleFontPickerSheetState extends State<_GoogleFontPickerSheet> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final filtered = _kPopularGoogleFonts
        .where((f) => f.toLowerCase().contains(_query.toLowerCase()))
        .toList();
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: Container(
        color: cs.surface.withValues(alpha: 0.95),
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'theme_font_google'.tr(),
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      hintText: 'theme_search_fonts'.tr(),
                      prefixIcon: Icon(Icons.search, color: cs.onSurfaceVariant),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: filtered.length,
                    itemBuilder: (_, i) {
                      final font = filtered[i];
                      return ListTile(
                        title: Text(font, style: TextStyle(color: cs.onSurface)),
                        onTap: () => Navigator.pop(context, font),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GoogleFontDisplayRow extends StatelessWidget {
  final String fontName;
  final VoidCallback onTap;
  final VoidCallback onClear;

  const _GoogleFontDisplayRow({
    required this.fontName,
    required this.onTap,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        children: [
          const SizedBox(width: 130),
          Expanded(
            child: GestureDetector(
              onTap: onTap,
              child: Text(
                fontName,
                style: TextStyle(color: context.cs.primary, fontSize: 14),
              ),
            ),
          ),
          GestureDetector(
            onTap: onClear,
            child: Icon(Icons.close, size: 18, color: context.cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
