import 'package:flutter_riverpod/legacy.dart';

/// Whether the chat drawer is in edit mode — one pencil, both tabs, and the
/// composer's pinned row above them.
///
/// App-scoped rather than panel state because the row it also governs lives in
/// [ChatInputBar], a sibling of the drawer rather than a child: local state
/// could not have reached it. Readers that render outside the drawer gate on
/// the drawer being open as well, so a flag left standing by a swipe-to-close
/// cannot leave badges on a composer with no drawer under it.
final chatDrawerEditingProvider = StateProvider<bool>((ref) => false);
