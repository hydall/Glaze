import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/utils/error_format.dart';

/// Inline error box mirroring the chat's `.error-window` (see
/// `assets/chat_webview/styles.css`): red-bordered card, a header strip with an
/// `ERROR` label and a copy button, and the message in monospace below.
///
/// Use it where a failed action stays on screen — a sheet's action bar, a form
/// — instead of a toast or dialog that hides the text again.
class GlazeErrorBlock extends StatelessWidget {
  /// Already-formatted message. Callers holding a raw exception should use
  /// [GlazeErrorBlock.fromError] so the text matches the chat's wording.
  final String message;

  /// Header label. When null, the localized generic `ERROR` label is used.
  final String? label;

  const GlazeErrorBlock({
    super.key,
    required this.message,
    this.label,
  });

  /// Formats [error] with the shared [formatError] — the same helper the chat
  /// uses when it writes a failed generation into a message bubble.
  GlazeErrorBlock.fromError(
    Object error, {
    super.key,
    this.label,
  }) : message = formatError(error);

  static const _accent = Color(0xFFFF3B30);
  static const _text = Color(0xFFFFB3B3);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _accent.withValues(alpha: 0.1),
        border: Border.all(color: _accent),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            color: _accent.withValues(alpha: 0.2),
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label ?? 'error_source_generic'.tr(),
                    style: const TextStyle(
                      color: _accent,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () =>
                      Clipboard.setData(ClipboardData(text: message)),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.copy, size: 14, color: _accent),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: SelectableText(
              message,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.4,
                color: _text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
