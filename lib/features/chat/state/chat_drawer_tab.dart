import 'package:flutter_riverpod/legacy.dart';

/// The two halves of the chat drawer. Values are ordered as they appear in the
/// tab strip, so `index` doubles as the strip's active index.
enum ChatDrawerTab { tools, actions }

/// Selected drawer tab.
///
/// App-scoped rather than panel state: the drawer panel is unmounted the moment
/// the drawer closes (see `renderDrawer` in `chat_screen.dart`), so local state
/// would snap back to Tools on every reopen. Kept here, the drawer comes back
/// on the tab the user left it on.
final chatDrawerTabProvider = StateProvider<ChatDrawerTab>(
  (ref) => ChatDrawerTab.tools,
);
