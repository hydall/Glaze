import 'theme_settings_schema.dart';

/// The theme editor's built-in Chat screen, written the way a theme declares
/// its own (theme_settings_schema.dart). A theme that declares settings
/// replaces all of it; `docs/theme_template/theme.json` starts from this very
/// declaration, so a theme author has the whole built-in screen to cut down.
///
/// Labels starting with `@` are the app's own translations; a row bound to a
/// `field` with no label gets the app's label for that field.
const kDefaultChatSettings = <String, Object>{
  'tabs': [
    {
      'id': 'font',
      'label': '@tab_font',
      'icon': 'text_fields',
      'groups': [
        {
          'header': '@theme_chat_font',
          'items': [
            {'field': 'chatFontMode'},
            {'field': 'chatFontSize'},
            {'field': 'chatLetterSpacing'},
            {'field': 'userMessageFontWeight'},
            {'field': 'charMessageFontWeight'},
          ],
        },
      ],
    },
    {
      'id': 'colors',
      'label': '@tab_colors',
      'icon': 'palette',
      'groups': [
        {
          'header': '@theme_bubble_colors',
          'when': "chatLayout == 'bubble'",
          'items': [
            {'field': 'userBubbleColor'},
            {'field': 'charBubbleColor'},
            {'field': 'userBubbleRadius'},
            {'field': 'charBubbleRadius'},
          ],
        },
        {
          'header': '@theme_identity',
          'items': [
            {'field': 'showUserAvatar'},
            {'field': 'showCharAvatar'},
            {'field': 'showUserName'},
            {'field': 'showCharName'},
          ],
        },
        {
          'header': '@theme_message_meta',
          'items': [
            {'field': 'hideMessageId'},
            {'field': 'hideGenerationTime'},
            {'field': 'hideTokenCount'},
          ],
        },
        {
          'header': '@theme_reply_colors',
          'items': [
            {'field': 'userQuoteColor'},
            {'field': 'charQuoteColor'},
          ],
        },
        {
          'header': '@theme_text_colors',
          'items': [
            {'field': 'userTextColor'},
            {'field': 'charTextColor'},
          ],
        },
        {
          'header': '@theme_italic_colors',
          'items': [
            {'field': 'userItalicColor'},
            {'field': 'charItalicColor'},
          ],
        },
        {
          'header': '@theme_desktop_effects',
          'when': "desktop && chatLayout != 'bubble'",
          'items': [
            {'field': 'textBgOpacity'},
          ],
        },
      ],
    },
    {
      'id': 'general',
      'label': '@tab_general',
      'icon': 'tune',
      'groups': [
        {
          'header': '@menu_chat_layout',
          'items': [
            {'field': 'chatLayout'},
          ],
        },
        {
          'header': '@theme_chat_background',
          'items': [
            {'field': 'chatBgMode'},
            {'field': 'chatBgColor', 'when': "chatBgMode == 'color'"},
            {'field': 'chatBgImage', 'when': "chatBgMode == 'custom'"},
          ],
        },
      ],
    },
  ],
};

/// [kDefaultChatSettings], parsed once.
final ThemeSettingsSchema kDefaultChatSettingsSchema =
    ThemeSettingsSchema.parse(kDefaultChatSettings)!;
