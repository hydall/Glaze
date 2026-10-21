part of 'theme_editor_screen.dart';

// ─── Chat tab ─────────────────────────────────────────────────────────────────
//
// Drawn from a declaration (theme_settings_schema.dart): the theme's own when
// it declares one, the built-in kDefaultChatSettings otherwise. The tab's
// sub-tabs are picked from the dropdown pinned under the header
// ([_ChatSectionPicker]); this draws the groups of the one picked.

/// The declaration the Chat tab shows for [preset].
ThemeSettingsSchema _chatSchemaOf(ThemePreset preset) =>
    preset.settingsSchema ?? kDefaultChatSettingsSchema;

/// The sub-tab of [schema] named [id], or its first.
ThemeSettingsTab _chatTabOf(ThemeSettingsSchema schema, String? id) =>
    schema.tabs.firstWhere((t) => t.id == id, orElse: () => schema.tabs.first);

String _themeText(BuildContext context, ThemeText text) =>
    text.resolve(context.locale.languageCode, (key) => key.tr());

IconData _tabIcon(String? name) => switch (name) {
  'text_fields' => Icons.text_fields,
  'palette' => Icons.palette_outlined,
  'tune' => Icons.tune,
  'chat' => Icons.chat_bubble_outline,
  'image' => Icons.image_outlined,
  'brush' => Icons.brush_outlined,
  'star' => Icons.star_outline_rounded,
  'layers' => Icons.layers_outlined,
  'person' => Icons.person_outline_rounded,
  'auto_awesome' => Icons.auto_awesome_outlined,
  _ => Icons.tune,
};

bool get _isDesktopPlatform =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// The dropdown that picks the Chat tab's sub-tab, pinned under the header.
class _ChatSectionPicker extends StatelessWidget {
  final ThemePreset preset;
  final String? tabId;
  final ValueChanged<String> onChanged;

  const _ChatSectionPicker({
    required this.preset,
    required this.tabId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final schema = _chatSchemaOf(preset);
    final current = _chatTabOf(schema, tabId);
    final themed = preset.settingsSchema != null;
    return Row(
      children: [
        GlazeDropdownChip(
          leading: Icon(
            _tabIcon(current.icon),
            size: 16,
            color: context.cs.primary,
          ),
          label: _themeText(context, current.label),
          onTap: () => showGlazePickerSheet(
            context,
            title: 'tab_chat'.tr(),
            items: [
              for (final tab in schema.tabs)
                GlazePickerItem(
                  label: _themeText(context, tab.label),
                  icon: _tabIcon(tab.icon),
                  isActive: tab.id == current.id,
                  value: tab.id,
                ),
            ],
            onSelect: (v) => onChanged(v as String),
          ),
        ),
        if (themed) ...[
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'theme_settings_from_theme'.tr(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ChatTab extends ConsumerWidget {
  final ThemePreset preset;
  final void Function(ThemePreset Function(ThemePreset)) onUpdate;
  final String? tabId;
  final double topPadding;
  final double bottomPadding;

  const _ChatTab({
    required this.preset,
    required this.onUpdate,
    required this.tabId,
    required this.topPadding,
    required this.bottomPadding,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schema = _chatSchemaOf(preset);
    final tab = _chatTabOf(schema, tabId);
    final index = schema.tabs.indexOf(tab);
    final app = ref.watch(appSettingsProvider).value ?? const AppSettings();
    final fields = preset.toJson();

    Object? lookup(String name) {
      switch (name) {
        case 'desktop':
          return _isDesktopPlatform;
        case 'mobile':
          return !_isDesktopPlatform;
      }
      final own = name.startsWith('theme.') ? name.substring(6) : name;
      for (final item in schema.ownItems) {
        if (item.key == own) return themeSettingValue(item, preset.themeValues);
      }
      return fields[name];
    }

    bool visible(String? when) => evaluateThemeCondition(when, lookup);

    final rows = _ChatRows(
      context: context,
      preset: preset,
      onUpdate: onUpdate,
      app: app,
    );
    return TabSlideSwitcher(
      index: index,
      child: ListView(
        key: ValueKey('chat-tab-${tab.id}'),
        padding: EdgeInsets.fromLTRB(0, topPadding + 8, 0, bottomPadding),
        children: [
          for (final group in tab.groups)
            if (visible(group.when))
              MenuGroup(
                header: group.header == null
                    ? null
                    : _themeText(context, group.header!),
                items: [
                  for (final item in group.items)
                    if (visible(item.when)) ...rows.build(item),
                ],
              ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Builds the rows of one declared item.
class _ChatRows {
  final BuildContext context;
  final ThemePreset preset;
  final void Function(ThemePreset Function(ThemePreset)) onUpdate;
  final AppSettings app;

  const _ChatRows({
    required this.context,
    required this.preset,
    required this.onUpdate,
    required this.app,
  });

  String? _label(ThemeSettingItem item) =>
      item.label == null ? null : _themeText(context, item.label!);

  List<Widget> build(ThemeSettingItem item) {
    final rows = switch (item.kind) {
      ThemeSettingKind.field => _field(item.field!, _label(item)),
      ThemeSettingKind.subheader => [MenuSubHeader(_label(item)!)],
      ThemeSettingKind.note => [_note(_label(item)!)],
      _ => [_own(item)],
    };
    final description = item.description;
    if (description == null || item.kind == ThemeSettingKind.note) return rows;
    return [...rows, _note(_themeText(context, description))];
  }

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Text(
      text,
      style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
    ),
  );

  // ── The theme's own values ──

  void _setOwn(String key, Object? value) => onUpdate((p) {
    final next = Map<String, dynamic>.from(p.themeValues);
    if (value == null) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    return p.copyWith(themeValues: next);
  });

  Widget _own(ThemeSettingItem item) {
    final key = item.key!;
    final label = _label(item)!;
    final value = themeSettingValue(item, preset.themeValues);
    switch (item.kind) {
      case ThemeSettingKind.color:
        return _ColorRow(
          label: label,
          value: value as String?,
          palette: _presetColors,
          allowNull: true,
          nullLabel: item.defaultValue == null
              ? 'theme_auto'.tr()
              : 'theme_default_value'.tr(),
          onChanged: (v) => _setOwn(key, v),
        );
      case ThemeSettingKind.toggle:
        return _SwitchRow(
          label: label,
          value: value == true,
          onChanged: (v) => _setOwn(key, v),
        );
      case ThemeSettingKind.slider:
        return _SliderRow(
          label: label,
          value: (value as num).toDouble(),
          min: item.min,
          max: item.max,
          divisions: item.divisions ?? 100,
          unit: item.percent ? '%' : item.unit,
          displayMultiplier: item.percent ? 100 : 1,
          onChanged: (v) => _setOwn(key, v),
        );
      case ThemeSettingKind.select:
        return _FontModeRow(
          label: label,
          mode: value as String,
          modes: [for (final o in item.options) o.value],
          modeLabels: [
            for (final o in item.options) _themeText(context, o.label),
          ],
          onChanged: (v) => _setOwn(key, v),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  // ── The preset's own chat fields ──

  List<Widget> _field(String field, String? label) {
    switch (field) {
      case 'chatLayout':
        return [
          _LayoutRow(
            label: label ?? 'menu_chat_layout'.tr(),
            value: preset.chatLayout,
            onTap: () => showChatLayoutPicker(
              context,
              current: preset.chatLayout,
              onSelect: (layout) =>
                  onUpdate((p) => p.copyWith(chatLayout: layout)),
            ),
          ),
        ];
      case 'chatBgMode':
        return [
          _FontModeRow(
            label: label ?? 'theme_chat_bg'.tr(),
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
        ];
      case 'chatBgColor':
        return [
          _ColorRow(
            label: label ?? 'theme_chat_bg_color'.tr(),
            value: preset.chatBgColor,
            palette: _presetUiColors,
            allowNull: true,
            showPreviewOverlay: false,
            nullLabel: 'theme_auto'.tr(),
            onChanged: (v) => onUpdate((p) => p.copyWith(chatBgColor: v)),
          ),
        ];
      case 'chatBgImage':
        return [
          _BgImageRow(
            hasImage: preset.hasChatBgImage,
            onPicked: (dataUri) =>
                onUpdate((p) => p.copyWith(chatBgImage: dataUri)),
            onReset: () => onUpdate((p) => p.copyWith(chatBgImage: null)),
          ),
        ];
      case 'chatFontMode':
        return [
          _FontModeRow(
            label: label ?? 'tab_font'.tr(),
            mode: preset.chatFontMode,
            modes: const ['ui', 'glaze', 'system', 'custom', 'google'],
            modeLabels: [
              'theme_font_same_as_ui'.tr(),
              'theme_font_glaze'.tr(),
              'theme_font_system'.tr(),
              'theme_font_custom'.tr(),
              'theme_font_google'.tr(),
            ],
            onChanged: (v) async {
              if (v == 'custom') {
                await _pickCustomFont(
                  context,
                  onUpdate,
                  isUi: false,
                  preset: preset,
                );
              } else if (v == 'google') {
                await _pickGoogleFont(
                  context,
                  onUpdate,
                  isUi: false,
                  preset: preset,
                );
              } else {
                onUpdate((p) => p.copyWith(chatFontMode: v));
              }
            },
          ),
          if (preset.chatFontMode == 'google' &&
              preset.chatGoogleFontName != null)
            _GoogleFontDisplayRow(
              fontName: preset.chatGoogleFontName!,
              onTap: () => _pickGoogleFont(
                context,
                onUpdate,
                isUi: false,
                preset: preset,
              ),
              onClear: () => onUpdate(
                (p) => p.copyWith(chatFontMode: 'ui', chatGoogleFontName: null),
              ),
            ),
        ];
      case 'chatFontSize':
        return [
          _FontSizeRow(
            label: label ?? 'theme_chat_font_size'.tr(),
            value: preset.chatFontSize,
            min: 12,
            max: 24,
            onChanged: (v) => onUpdate((p) => p.copyWith(chatFontSize: v)),
          ),
        ];
      case 'chatLetterSpacing':
        return [
          _SliderRow(
            label: label ?? 'theme_chat_letter_spacing'.tr(),
            value: preset.chatLetterSpacing,
            min: -1,
            max: 3,
            divisions: 8,
            unit: 'px',
            onChanged: (v) => onUpdate((p) => p.copyWith(chatLetterSpacing: v)),
          ),
        ];
      case 'userMessageFontWeight':
        return [
          _SliderRow(
            label: label ?? 'theme_user_font_weight'.tr(),
            value: preset.userMessageFontWeight.toDouble(),
            min: 100,
            max: 900,
            divisions: 8,
            unit: '',
            onChanged: (v) => onUpdate(
              (p) => p.copyWith(userMessageFontWeight: _weightFromSlider(v)),
            ),
          ),
        ];
      case 'charMessageFontWeight':
        return [
          _SliderRow(
            label: label ?? 'theme_char_font_weight'.tr(),
            value: preset.charMessageFontWeight.toDouble(),
            min: 100,
            max: 900,
            divisions: 8,
            unit: '',
            onChanged: (v) => onUpdate(
              (p) => p.copyWith(charMessageFontWeight: _weightFromSlider(v)),
            ),
          ),
        ];
      case 'userBubbleColor':
        return [
          _ColorRow(
            label: label ?? 'theme_user_bubble'.tr(),
            value: preset.userBubbleColor,
            palette: _presetColors,
            allowNull: true,
            nullLabel: 'theme_auto'.tr(),
            allowGradient: true,
            gradient: preset.userBubbleGradient,
            onGradientChanged: (v) =>
                onUpdate((p) => p.copyWith(userBubbleGradient: v)),
            onChanged: (v) => onUpdate((p) => p.copyWith(userBubbleColor: v)),
          ),
        ];
      case 'charBubbleColor':
        return [
          _ColorRow(
            label: label ?? 'theme_char_bubble'.tr(),
            value: preset.charBubbleColor,
            palette: _presetColors,
            allowNull: true,
            nullLabel: 'theme_auto'.tr(),
            allowGradient: true,
            gradient: preset.charBubbleGradient,
            onGradientChanged: (v) =>
                onUpdate((p) => p.copyWith(charBubbleGradient: v)),
            onChanged: (v) => onUpdate((p) => p.copyWith(charBubbleColor: v)),
          ),
        ];
      case 'userBubbleRadius':
        return [
          _SliderRow(
            label: label ?? 'theme_user_bubble_radius'.tr(),
            value: preset.userBubbleRadius,
            min: 0,
            max: 36,
            divisions: 36,
            unit: 'px',
            onChanged: (v) => onUpdate((p) => p.copyWith(userBubbleRadius: v)),
          ),
        ];
      case 'charBubbleRadius':
        return [
          _SliderRow(
            label: label ?? 'theme_char_bubble_radius'.tr(),
            value: preset.charBubbleRadius,
            min: 0,
            max: 36,
            divisions: 36,
            unit: 'px',
            onChanged: (v) => onUpdate((p) => p.copyWith(charBubbleRadius: v)),
          ),
        ];
      case 'showUserAvatar':
        return [
          _SwitchRow(
            label: label ?? 'theme_user_avatar'.tr(),
            value: preset.showUserAvatar,
            onChanged: (v) => onUpdate((p) => p.copyWith(showUserAvatar: v)),
          ),
        ];
      case 'showCharAvatar':
        return [
          _SwitchRow(
            label: label ?? 'theme_char_avatar'.tr(),
            value: preset.showCharAvatar,
            onChanged: (v) => onUpdate((p) => p.copyWith(showCharAvatar: v)),
          ),
        ];
      case 'showUserName':
        return [
          _SwitchRow(
            label: label ?? 'theme_user_name'.tr(),
            value: preset.showUserName,
            onChanged: (v) => onUpdate((p) => p.copyWith(showUserName: v)),
          ),
        ];
      case 'showCharName':
        return [
          _SwitchRow(
            label: label ?? 'theme_char_name'.tr(),
            value: preset.showCharName,
            onChanged: (v) => onUpdate((p) => p.copyWith(showCharName: v)),
          ),
        ];
      // Tri-state, because these three also exist as app settings and the
      // preset wins over them (see chat_screen's `preset.x ?? app.x`). The
      // include switch is what "this preset overrides it" looks like; turning
      // it off clears the override and hands the row back to the app setting,
      // which is otherwise unreachable from the UI.
      case 'hideMessageId':
        return [
          _MetaOverrideRow(
            label: label ?? 'menu_show_msg_id'.tr(),
            overridden: preset.hideMessageId != null,
            shown: !(preset.hideMessageId ?? app.hideMessageId),
            onOverrideChanged: (on) => onUpdate(
              (p) => p.copyWith(hideMessageId: on ? app.hideMessageId : null),
            ),
            onChanged: (show) =>
                onUpdate((p) => p.copyWith(hideMessageId: !show)),
          ),
        ];
      case 'hideGenerationTime':
        return [
          _MetaOverrideRow(
            label: label ?? 'menu_show_gen_time'.tr(),
            overridden: preset.hideGenerationTime != null,
            shown: !(preset.hideGenerationTime ?? app.hideGenerationTime),
            onOverrideChanged: (on) => onUpdate(
              (p) => p.copyWith(
                hideGenerationTime: on ? app.hideGenerationTime : null,
              ),
            ),
            onChanged: (show) =>
                onUpdate((p) => p.copyWith(hideGenerationTime: !show)),
          ),
        ];
      case 'hideTokenCount':
        return [
          _MetaOverrideRow(
            label: label ?? 'menu_show_token_count'.tr(),
            overridden: preset.hideTokenCount != null,
            shown: !(preset.hideTokenCount ?? app.hideTokenCount),
            onOverrideChanged: (on) => onUpdate(
              (p) => p.copyWith(hideTokenCount: on ? app.hideTokenCount : null),
            ),
            onChanged: (show) =>
                onUpdate((p) => p.copyWith(hideTokenCount: !show)),
          ),
        ];
      case 'userQuoteColor':
        return [
          _textColor(
            label ?? 'theme_user_reply'.tr(),
            preset.userQuoteColor,
            (p, v) => p.copyWith(userQuoteColor: v),
          ),
        ];
      case 'charQuoteColor':
        return [
          _textColor(
            label ?? 'theme_char_reply'.tr(),
            preset.charQuoteColor,
            (p, v) => p.copyWith(charQuoteColor: v),
          ),
        ];
      case 'userTextColor':
        return [
          _textColor(
            label ?? 'theme_user_text'.tr(),
            preset.userTextColor,
            (p, v) => p.copyWith(userTextColor: v),
          ),
        ];
      case 'charTextColor':
        return [
          _textColor(
            label ?? 'theme_char_text'.tr(),
            preset.charTextColor,
            (p, v) => p.copyWith(charTextColor: v),
          ),
        ];
      case 'userItalicColor':
        return [
          _textColor(
            label ?? 'theme_user_italic'.tr(),
            preset.userItalicColor,
            (p, v) => p.copyWith(userItalicColor: v),
          ),
        ];
      case 'charItalicColor':
        return [
          _textColor(
            label ?? 'theme_char_italic'.tr(),
            preset.charItalicColor,
            (p, v) => p.copyWith(charItalicColor: v),
          ),
        ];
      // Desktop-only: message background opacity for layout-default. On
      // mobile the backdrop is always transparent (no impact on perf).
      case 'textBgOpacity':
        return [
          _SliderRow(
            label: label ?? 'theme_text_bg_opacity'.tr(),
            value: preset.textBgOpacity,
            min: 0.0,
            max: 0.8,
            divisions: 16,
            unit: '%',
            displayMultiplier: 100,
            onChanged: (v) => onUpdate((p) => p.copyWith(textBgOpacity: v)),
          ),
        ];
    }
    return const [];
  }

  Widget _textColor(
    String label,
    String? value,
    ThemePreset Function(ThemePreset p, String? v) set,
  ) {
    return _ColorRow(
      label: label,
      value: value,
      palette: _presetColors,
      allowNull: true,
      nullLabel: 'theme_auto'.tr(),
      onChanged: (v) => onUpdate((p) => set(p, v)),
    );
  }
}

/// The chat layout as a settings row; the picker shows both layouts.
class _LayoutRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;

  const _LayoutRow({
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isBubble = value == 'bubble';
    return InkWell(
      mouseCursor: SystemMouseCursors.click,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              isBubble ? Icons.chat_bubble_outline : Icons.view_stream_outlined,
              size: 18,
              color: context.cs.primary,
            ),
            const SizedBox(width: 12),
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
            Text(
              isBubble ? 'layout_bubble'.tr() : 'layout_default'.tr(),
              style: TextStyle(color: context.cs.primary, fontSize: 14),
            ),
            Icon(Icons.chevron_right, color: context.cs.primary),
          ],
        ),
      ),
    );
  }
}
