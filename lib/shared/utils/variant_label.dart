import 'package:easy_localization/easy_localization.dart';

import '../../core/models/character.dart';

/// Display label for one variation: its name, or "Original" for the unnamed row
/// the variation group grew out of.
///
/// Shared so every variation picker — the variations sheet, the detail screen's
/// "which variation" prompt, the chat list's new-session prompt — names the same
/// row identically.
String variantLabel(Character variant) {
  final name = variant.variantName?.trim();
  return (name != null && name.isNotEmpty) ? name : 'variation_original'.tr();
}

/// Secondary line under [variantLabel] in a variation picker: how many chats the
/// variation has.
///
/// The chat count is what actually identifies the variation you meant —
/// variations of one character share a name stem and, usually, an avatar.
String variantPickerHint(int sessionCount) =>
    '$sessionCount ${'count_chats'.plural(sessionCount)}';
