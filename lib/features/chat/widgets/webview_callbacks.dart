typedef MessageContextCallback =
    void Function(
      int index,
      String messageId,
      bool isUser,
      bool isSystem,
      String content,
    );
typedef SwipeCallback = void Function(String id, String direction);
typedef GreetingCallback = void Function(String id, int direction);
typedef RegenerateCallback = void Function(String id, String mode);
typedef RerunCleanerCallback = void Function(String messageId);
typedef ToggleHiddenCallback = void Function(String id);
typedef InjectClickCallback = void Function(String id);
typedef MemoryClickCallback = void Function(String id);
typedef GuidedSwipeCallback = void Function(String id, String guidanceText);
typedef EditSaveCallback = void Function(String id, String text);
typedef EditCancelCallback = void Function(String id);
typedef EditFocusCallback = void Function(String id, bool focused);
typedef ImgActionCallback = void Function(String instruction, String messageId);
typedef ImgOptionsCallback =
    void Function(String src, String instruction, String messageId);
typedef ImgVoidCallback = void Function();
typedef HeaderScrollCallback = void Function(bool hidden);
typedef ScrollToBottomVisibilityCallback = void Function(bool visible);
typedef SelectionActionCallback = void Function(String action, String text);
typedef ImageClickCallback = void Function(String imageUrl);
typedef SelectionChangeCallback = void Function(List<String> ids);

class MessageActionsCallbacks {
  final MessageContextCallback? onMessageContext;
  final SwipeCallback? onSwipe;
  final SwipeCallback? onAgentSwipe;
  final GreetingCallback? onChangeGreeting;
  final RegenerateCallback? onRegenerate;
  final RerunCleanerCallback? onRerunCleaner;
  final ToggleHiddenCallback? onToggleHidden;
  final ToggleHiddenCallback? onToggleImageHidden;
  final InjectClickCallback? onInjectClick;
  final MemoryClickCallback? onMemoryClick;
  final GuidedSwipeCallback? onGuidedSwipe;

  const MessageActionsCallbacks({
    this.onMessageContext,
    this.onSwipe,
    this.onAgentSwipe,
    this.onChangeGreeting,
    this.onRegenerate,
    this.onRerunCleaner,
    this.onToggleHidden,
    this.onToggleImageHidden,
    this.onInjectClick,
    this.onMemoryClick,
    this.onGuidedSwipe,
  });
}

class EditActionsCallbacks {
  final EditSaveCallback? onEditSave;
  final EditCancelCallback? onEditCancel;
  final EditFocusCallback? onEditFocusChange;

  const EditActionsCallbacks({
    this.onEditSave,
    this.onEditCancel,
    this.onEditFocusChange,
  });
}

class ImageGenCallbacks {
  final ImgActionCallback? onImgRetry;
  final ImgActionCallback? onImgFind;
  final ImgActionCallback? onImgRegen;
  final ImgOptionsCallback? onImgOptions;
  final ImgVoidCallback? onImgCancel;
  final ImageClickCallback? onImgDownload;

  const ImageGenCallbacks({
    this.onImgRetry,
    this.onImgFind,
    this.onImgRegen,
    this.onImgOptions,
    this.onImgCancel,
    this.onImgDownload,
  });
}

class ScrollCallbacks {
  final HeaderScrollCallback? onHeaderScroll;
  final ScrollToBottomVisibilityCallback? onScrollToBottomVisibility;

  const ScrollCallbacks({this.onHeaderScroll, this.onScrollToBottomVisibility});
}

class MiscCallbacks {
  final ImgVoidCallback? onStop;
  final SelectionActionCallback? onSelectionAction;
  final ImageClickCallback? onImageClick;
  final SelectionChangeCallback? onSelectionChange;

  const MiscCallbacks({
    this.onStop,
    this.onSelectionAction,
    this.onImageClick,
    this.onSelectionChange,
  });
}
