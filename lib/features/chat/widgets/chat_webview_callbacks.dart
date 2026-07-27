import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../chat_provider.dart';
import 'webview_callbacks.dart';

/// Pass-through wiring for the chat WebView bridge callbacks
/// that forward user gestures to the parent widget's
/// [MessageActionsCallbacks], [EditActionsCallbacks],
/// [ImageGenCallbacks], [ScrollCallbacks], and [MiscCallbacks].
///
/// Extracted from `chat_webview_widget.dart` so `onWebViewCreated`
/// stays focused on bridge setup. The `onLinkClick`, `onLoadMore`,
/// and the message-id → index resolution in [onMessageContext] are
/// inlined here because they need access to Riverpod / launchUrl.
///
/// The class is a thin adapter: it captures the widget's `charId`,
/// a [WidgetRef] for the chat provider, the parent callbacks bag,
/// and exposes the typed functions the bridge expects.
class ChatWebViewCallbacks {
  ChatWebViewCallbacks({
    required this.ref,
    required this.charId,
    required this.messageActions,
    required this.editActions,
    required this.imageGenActions,
    required this.scrollActions,
    required this.miscActions,
  });

  final WidgetRef ref;
  final String charId;
  final MessageActionsCallbacks messageActions;
  final EditActionsCallbacks editActions;
  final ImageGenCallbacks imageGenActions;
  final ScrollCallbacks scrollActions;
  final MiscCallbacks miscActions;

  /// Resolve a message id to its index in the current chat messages
  /// list, then forward to `messageActions.onMessageContext`.
  /// Returns early if the id is no longer present (e.g. message
  /// was deleted by another path).
  void onMessageContext(String id, bool isUser, bool isSystem, String content) {
    final allMsgs = ref.read(chatProvider(charId)).value?.messages ?? const [];
    final idx = allMsgs.indexWhere((m) => m.id == id);
    if (idx < 0) return;
    messageActions.onMessageContext?.call(idx, id, isUser, isSystem, content);
  }

  void onSwipe(String id, String direction) {
    messageActions.onSwipe?.call(id, direction);
  }

  void onAgentSwipe(String id, String direction) {
    messageActions.onAgentSwipe?.call(id, direction);
  }

  void onChangeGreeting(String id, int direction) {
    messageActions.onChangeGreeting?.call(id, direction);
  }

  void onHeaderScroll(bool hidden) {
    scrollActions.onHeaderScroll?.call(hidden);
  }

  void onScrollToBottomVisibility(bool visible) {
    scrollActions.onScrollToBottomVisibility?.call(visible);
  }

  void onRegenerate(String id, String mode) {
    messageActions.onRegenerate?.call(id, mode);
  }

  void onRerunCleaner(String id) {
    messageActions.onRerunCleaner?.call(id);
  }

  void onSelectionAction(String action, String text) {
    miscActions.onSelectionAction?.call(action, text);
  }

  void onSelectionChange(List<String> ids) {
    miscActions.onSelectionChange?.call(ids);
  }

  void onEditSave(String id, String text) {
    editActions.onEditSave?.call(id, text);
  }

  void onEditCancel(String id) {
    editActions.onEditCancel?.call(id);
  }

  void onEditFocusChange(String id, bool focused) {
    editActions.onEditFocusChange?.call(id, focused);
  }

  void onImageClick(String imageUrl) {
    miscActions.onImageClick?.call(imageUrl);
  }

  void onGuidedSwipe(String id, String guidanceText) {
    messageActions.onGuidedSwipe?.call(id, guidanceText);
  }

  void onMemoryClick(String id) {
    messageActions.onMemoryClick?.call(id);
  }

  void onToggleHidden(String id) {
    messageActions.onToggleHidden?.call(id);
  }

  void onToggleImageHidden(String id) {
    messageActions.onToggleImageHidden?.call(id);
  }

  void onInjectClick(String id) {
    messageActions.onInjectClick?.call(id);
  }

  void onImgRetry(String instruction, String messageId) {
    imageGenActions.onImgRetry?.call(instruction, messageId);
  }

  void onImgFind(String instruction, String messageId) {
    imageGenActions.onImgFind?.call(instruction, messageId);
  }

  void onImgRegen(String instruction, String messageId) {
    imageGenActions.onImgRegen?.call(instruction, messageId);
  }

  void onImgOptions(String src, String instruction, String messageId) {
    imageGenActions.onImgOptions?.call(src, instruction, messageId);
  }

  void onImgCancel() {
    imageGenActions.onImgCancel?.call();
  }

  void onImgDownload(String src) {
    imageGenActions.onImgDownload?.call(src);
  }

  void onStop() {
    miscActions.onStop?.call();
  }

  void onLinkClick(String url) {
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  void onLoadMore() {
    ref.read(chatProvider(charId).notifier).loadOlderMessages();
  }
}
