import 'package:flutter/material.dart';

import '../chrome/chat_chrome_channel.dart';
import '../chrome/chrome_json.dart';

/// The one button a status card can carry (stop the cleaner, hide a stranded
/// indicator).
class ChatStatusCardAction {
  const ChatStatusCardAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
    this.size = 18,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  /// The glyph's colour; the theme's onSurfaceVariant when null.
  final Color? color;
  final double size;
}

/// One live status card under the chat header — drawn by the chat page (see
/// `assets/chat_webview/chrome/cards.js`), not by Flutter.
///
/// The cards used to be Flutter widgets laid over the chat WebView, which put
/// them above everything the page draws. Now each card's widget keeps its
/// logic (what it says, when it goes) and this shell hands the result to the
/// page as the chrome section [slot]: one rounded surface with an accent
/// outline, a spinner or an icon, the label and the optional [action]. A tap
/// on the action comes back as the `statusAction` intent.
///
/// It lays nothing out itself. Unmounting it takes the card off the page.
class ChatStatusCardShell extends StatefulWidget {
  const ChatStatusCardShell({
    super.key,
    required this.channel,
    required this.slot,
    required this.label,
    required this.icon,
    required this.accent,
    required this.showSpinner,
    this.action,
  });

  final ChatChromeChannel channel;

  /// The chrome section the card is drawn from: `statusCleaner`,
  /// `statusStudio` or `statusPostGen`, top to bottom.
  final String slot;
  final String label;
  final IconData icon;
  final Color accent;
  final bool showSpinner;
  final ChatStatusCardAction? action;

  @override
  State<ChatStatusCardShell> createState() => _ChatStatusCardShellState();
}

class _ChatStatusCardShellState extends State<ChatStatusCardShell> {
  VoidCallback? _removeIntent;
  late ChatChromeChannel _channel;
  late String _slot;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant ChatStatusCardShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel || oldWidget.slot != widget.slot) {
      _unbind();
      _bind();
    }
  }

  void _bind() {
    _channel = widget.channel;
    _slot = widget.slot;
    _removeIntent = _channel.on('statusAction', (data) {
      if (data['id'] == _slot) widget.action?.onPressed();
    });
  }

  void _unbind() {
    _removeIntent?.call();
    _removeIntent = null;
    _channel.set(_slot, null);
  }

  @override
  void dispose() {
    _unbind();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final action = widget.action;
    _channel.set(_slot, {
      'label': widget.label,
      'icon': chromeIcon(widget.icon),
      'accent': chromeColor(widget.accent),
      'spinner': widget.showSpinner,
      'action': action == null
          ? null
          : {
              'id': _slot,
              'icon': chromeIcon(action.icon),
              'tip': action.tooltip,
              'color': action.color == null ? null : chromeColor(action.color!),
              'size': action.size,
            },
    });
    return const SizedBox.shrink();
  }
}
