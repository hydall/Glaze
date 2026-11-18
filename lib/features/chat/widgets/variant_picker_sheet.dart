import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/utils/think_tags.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../chat_provider.dart';

/// Which switcher under a message the picker serves. Matches the `kind` the
/// WebView sends with `onOpenVariants`.
enum VariantPickerKind {
  swipe,
  agentSwipe,
  greeting;

  static VariantPickerKind fromWire(String kind) => switch (kind) {
    'agent-swipe' => agentSwipe,
    'greeting' => greeting,
    _ => swipe,
  };
}

/// One row of the picker: the variation's text as the reader would see it and
/// an optional short tag shown next to its number (an error, a cleaned pass).
class VariantOption {
  final String text;
  final String? tag;

  const VariantOption(this.text, {this.tag});
}

const _previewLength = 240;

/// A one-paragraph preview of [raw]: reasoning dropped, whitespace collapsed,
/// cut to a couple of lines' worth so a long reply does not cost a long row.
String variantPreview(String raw) {
  final flat = stripThinkTags(raw).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= _previewLength) return flat;
  return '${flat.substring(0, _previewLength).trimRight()}…';
}

/// The green variations of [m]. The active one shows the message's live
/// content (an edit or a cleaned pass lands there, not in `swipes`); the others
/// show what switching to them would show — their stored active sub-swipe when
/// they have one, else the raw swipe text.
List<VariantOption> swipeVariantOptions(ChatMessage m) {
  return [
    for (var i = 0; i < m.swipes.length; i++)
      VariantOption(
        i == m.swipeId ? m.content : _storedSwipeText(m, i),
        tag: _swipeMeta(m, i)?['isError'] == true ? 'error' : null,
      ),
  ];
}

/// The blue sub-swipes (final / cleaned passes) of the active variation.
List<VariantOption> agentVariantOptions(ChatMessage m) {
  return [
    for (var i = 0; i < m.agentSwipes.length; i++)
      VariantOption(
        i == m.agentSwipeId ? m.content : m.agentSwipes[i].content,
        tag: m.agentSwipes[i].kind == 'cleaned' ? 'cleaned' : null,
      ),
  ];
}

Map<String, dynamic>? _swipeMeta(ChatMessage m, int i) =>
    i < m.swipesMeta.length ? m.swipesMeta[i] : null;

String _storedSwipeText(ChatMessage m, int i) {
  final meta = _swipeMeta(m, i);
  final stored = meta?['agentSwipes'];
  if (stored is List && stored.isNotEmpty) {
    final rawId = meta?['agentSwipeId'];
    final id = rawId is int ? rawId.clamp(0, stored.length - 1) : 0;
    final entry = stored[id];
    if (entry is Map && entry['content'] is String) {
      return entry['content'] as String;
    }
  }
  return m.swipes[i];
}

/// Opens the sheet behind the variation counter: every variation of the
/// tapped switcher with a preview, the current one highlighted. Picking one
/// jumps straight to it instead of stepping through the arrows.
Future<void> showVariantPickerSheet({
  required BuildContext context,
  required WidgetRef ref,
  required String charId,
  required String messageId,
  required String kind,
}) async {
  final pickerKind = VariantPickerKind.fromWire(kind);
  final notifier = ref.read(chatProvider(charId).notifier);
  final state = ref.read(chatProvider(charId)).value;
  if (state == null ||
      state.isGenerating ||
      state.isGeneratingImage ||
      state.isPostGenRunning) {
    return;
  }
  final index = state.messages.indexWhere((m) => m.id == messageId);
  if (index < 0) return;
  final message = state.messages[index];

  final List<VariantOption> options;
  final int current;
  switch (pickerKind) {
    case VariantPickerKind.swipe:
      options = swipeVariantOptions(message);
      current = message.swipeId;
    case VariantPickerKind.agentSwipe:
      options = agentVariantOptions(message);
      current = message.agentSwipeId;
    case VariantPickerKind.greeting:
      if (index != 0) return;
      final greetings = await notifier.greetingOptions();
      if (!context.mounted) return;
      options = [for (final g in greetings) VariantOption(g)];
      current = message.greetingIndex ?? 0;
  }
  if (options.length < 2) return;

  void pick(int target) {
    Navigator.of(context, rootNavigator: true).pop();
    if (target == current) return;
    switch (pickerKind) {
      case VariantPickerKind.swipe:
        unawaited(notifier.setSwipe(index, target));
      case VariantPickerKind.agentSwipe:
        unawaited(notifier.setAgentSwipe(index, target));
      case VariantPickerKind.greeting:
        unawaited(notifier.setGreeting(index, target - current));
    }
  }

  final title = switch (pickerKind) {
    VariantPickerKind.swipe => 'variant_picker_title'.tr(),
    VariantPickerKind.agentSwipe => 'variant_picker_agent_title'.tr(),
    VariantPickerKind.greeting => 'variant_picker_greeting_title'.tr(),
  };
  final itemKey = pickerKind == VariantPickerKind.greeting
      ? 'variant_picker_greeting_item'
      : 'variant_picker_item';

  await GlazeBottomSheet.show<void>(
    context,
    title: title,
    scrollToIndex: current.clamp(0, options.length - 1),
    cardItems: [
      for (var i = 0; i < options.length; i++)
        _card(
          label: itemKey.tr(namedArgs: {'n': '${i + 1}'}),
          option: options[i],
          isActive: i == current,
          onTap: () => pick(i),
        ),
    ],
  );
}

BottomSheetCardItem _card({
  required String label,
  required VariantOption option,
  required bool isActive,
  required VoidCallback onTap,
}) {
  final preview = variantPreview(option.text);
  final tag = option.tag == null ? null : 'variant_picker_${option.tag}'.tr();
  return BottomSheetCardItem(
    label: tag == null ? label : '$label · $tag',
    sublabel: preview.isEmpty ? 'variant_picker_empty'.tr() : preview,
    isActive: isActive,
    onTap: onTap,
  );
}
