/// Declarative registry of every JS->Dart callback the chat WebView
/// can invoke. Each entry maps a handler name to a [HandlerSpec] that
/// describes how to parse the incoming [args] and which
/// [ChatBridgeController] callback to dispatch to.
///
/// The host's `setupHandlers()` walks this map and registers one
/// `addJavaScriptHandler` per entry. Each entry's [kind] tells the
/// dispatcher which `_dispatchXxx` to use.
enum HandlerKind {
  /// Handler takes no arguments (e.g. onStop, onLoadMore, onImgCancel).
  noArgs,

  /// Handler takes a single boolean (e.g. onHeaderScroll).
  boolArg,

  /// Handler takes a single string (e.g. onLinkClick, onMemoryClick).
  stringArg,

  /// Handler takes a JSON object with named fields.
  jsonObject,

  /// Handler takes (String id, String text) pair.
  idStringPair,

  /// Handler takes (String id, int direction) pair.
  idIntPair,

  /// Handler takes (String id, bool focused) pair.
  idBoolPair,

  /// Handler takes (String id, String text) pair.
  idStringStringPair,

  /// Handler takes (String instruction, String messageId) pair.
  imageAction,

  /// Handler takes a JSON array of strings.
  idList,
}

class HandlerSpec {
  final HandlerKind kind;
  final String? debugPrint;

  const HandlerSpec(this.kind, {this.debugPrint});
}

/// Single source of truth for the JS handler names. The
/// `webview_callback_contract_test.dart` reads this indirectly via the
/// host file, so we keep the list here and the host just iterates it.
const Map<String, HandlerSpec> bridgeHandlers = {
  // Lifecycle & scroll
  'onWebViewReady': HandlerSpec(HandlerKind.noArgs),
  'onLoadMore': HandlerSpec(HandlerKind.noArgs),
  'onHeaderScroll': HandlerSpec(HandlerKind.boolArg),
  'onScrollToBottomVisibility': HandlerSpec(HandlerKind.boolArg),
  'onLinkClick': HandlerSpec(HandlerKind.stringArg),
  'onImageClick': HandlerSpec(HandlerKind.stringArg),
  'onImgDownload': HandlerSpec(HandlerKind.stringArg),
  // Message actions
  'onMessageContext': HandlerSpec(HandlerKind.jsonObject),
  'onSwipe': HandlerSpec(HandlerKind.jsonObject),
  'onAgentSwipe': HandlerSpec(HandlerKind.jsonObject),
  'onRegenerate': HandlerSpec(HandlerKind.idStringPair),
  'onChangeGreeting': HandlerSpec(HandlerKind.idIntPair),
  'onRerunCleaner': HandlerSpec(HandlerKind.stringArg),
  'onSelectionAction': HandlerSpec(HandlerKind.jsonObject),
  // Edit
  'onEditSave': HandlerSpec(HandlerKind.idStringPair),
  'onEditCancel': HandlerSpec(HandlerKind.stringArg),
  'onEditFocusChange': HandlerSpec(HandlerKind.idBoolPair),
  // Guided swipe / memory / lorebook
  'onGuidedSwipe': HandlerSpec(HandlerKind.idStringStringPair),
  'onMemoryClick': HandlerSpec(HandlerKind.stringArg),
  'onToggleHidden': HandlerSpec(HandlerKind.stringArg),
  'onToggleImageHidden': HandlerSpec(HandlerKind.stringArg),
  'onSelectionChange': HandlerSpec(HandlerKind.idList),
  'onInjectClick': HandlerSpec(HandlerKind.stringArg),
  // Image generation
  'onImgRetry': HandlerSpec(HandlerKind.imageAction),
  'onImgFind': HandlerSpec(HandlerKind.imageAction),
  'onImgRegen': HandlerSpec(
    HandlerKind.imageAction,
    debugPrint: '[BRIDGE] onImgRegen called, args=\$args',
  ),
  'onImgCancel': HandlerSpec(
    HandlerKind.noArgs,
    debugPrint: '[BRIDGE] onImgCancel called',
  ),
  'onImgOptions': HandlerSpec(HandlerKind.jsonObject),
  // Stop
  'onStop': HandlerSpec(HandlerKind.noArgs),
  // Ext blocks
  'onExtBlocksRunAll': HandlerSpec(HandlerKind.stringArg),
  'onExtBlockStop': HandlerSpec(HandlerKind.imageAction),
  'onExtBlockRegen': HandlerSpec(HandlerKind.imageAction),
  'onExtBlockRegenImage': HandlerSpec(HandlerKind.imageAction),
  'onExtBlockEdit': HandlerSpec(HandlerKind.imageAction),
  'onExtBlockDelete': HandlerSpec(HandlerKind.imageAction),
  // Interactive panels
  'onPanelResize': HandlerSpec(HandlerKind.jsonObject),
  'onPanelEvent': HandlerSpec(HandlerKind.jsonObject),
};
