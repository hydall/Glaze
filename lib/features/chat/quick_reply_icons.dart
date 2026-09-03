import 'package:flutter/material.dart';

/// The glyphs an Actions card can be given, by stable id.
///
/// A closed, hand-picked set rather than "any Material icon": the ids are
/// persisted with the card and the row that pins it, and the release build is
/// compiled with `--tree-shake-icons`, which keeps only the [IconData] the code
/// refers to *statically*. An icon chosen by codepoint at runtime would be
/// stripped from the font and render as a blank box in a release build — so
/// every offered glyph is written out here, in a const, by name.
///
/// Never rename a key. Drop one and the cards holding it fall back to their
/// built-in default, which is the same thing a card from a newer build does on
/// an older one.
const Map<String, IconData> kQuickReplyIcons = {
  'bolt': Icons.bolt,
  'continue': Icons.keyboard_double_arrow_right,
  'chat': Icons.chat_bubble_outline,
  'question': Icons.help_outline,
  'idea': Icons.lightbulb_outline,
  'star': Icons.star_outline,
  'heart': Icons.favorite_border,
  'fire': Icons.local_fire_department_outlined,
  'eye': Icons.visibility_outlined,
  'walk': Icons.directions_walk,
  'run': Icons.directions_run,
  'hand': Icons.back_hand_outlined,
  'mic': Icons.mic_none,
  'theatre': Icons.theater_comedy_outlined,
  'mask': Icons.masks_outlined,
  'sword': Icons.sports_martial_arts,
  'shield': Icons.shield_outlined,
  'magic': Icons.auto_fix_high_outlined,
  'sparkle': Icons.auto_awesome_outlined,
  'moon': Icons.nightlight_outlined,
  'sun': Icons.wb_sunny_outlined,
  'clock': Icons.schedule,
  'map': Icons.map_outlined,
  'door': Icons.meeting_room_outlined,
  'book': Icons.menu_book_outlined,
  'note': Icons.sticky_note_2_outlined,
  'search': Icons.search,
  'refresh': Icons.refresh,
  'skip': Icons.fast_forward_outlined,
  'flag': Icons.outlined_flag,
  'warning': Icons.warning_amber_outlined,
  'coffee': Icons.local_cafe_outlined,
};

/// The glyph for [iconId], or null when the card never chose one and when the
/// id came from a build that offered a glyph this one does not.
IconData? quickReplyIconById(String? iconId) =>
    iconId == null ? null : kQuickReplyIcons[iconId];
