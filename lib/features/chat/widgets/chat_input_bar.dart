import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/theme/theme_preset.dart';
import '../../../shared/theme/theme_provider.dart';
import '../../../shared/widgets/fullscreen_editor.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../chat_provider.dart'
    show ImpersonationState, impersonationStateProvider;
import 'chat_blur_region_tracker.dart';

Border _uiBorder(BuildContext context, ThemePreset preset) {
  final base = preset.borderParsed ?? context.cs.onSurface;
  return Border.all(
    color: base.withValues(alpha: preset.borderOpacity.clamp(0.0, 1.0)),
    width: preset.borderWidth,
  );
}

class ChatInputBar extends ConsumerStatefulWidget {
  /// Returns true only when the host accepted ownership of the send. The
  /// composer is cleared only in that case.
  final Future<bool> Function(String text) onSend;

  /// Guard invoked right before a send is dispatched. When it returns false the
  /// send is aborted and the composed text/image are kept intact so the host
  /// can show a prerequisite modal (e.g. "no provider selected") without losing
  /// what the user typed. When null, sending is always allowed.
  final bool Function()? canSend;
  final Future<bool> Function(String text, String? guidance)?
  onSendWithGuidance;
  final bool isGenerating;
  final bool isGeneratingImage;

  /// True while post-generation stages (cleaner, Ledger, image tags, etc.)
  /// are running. Keeps the Stop button pressable through the post-gen
  /// window without gating the message sync (which keys on [isGenerating]).
  final bool isPostGenRunning;
  final VoidCallback? onStop;
  final VoidCallback? onMagicDrawer;
  final Future<bool> Function(
    String text,
    String? guidanceText,
    String imageDataUrl,
  )?
  onSendWithImage;
  final VoidCallback? onFullScreen;

  /// Triggered by the account-circle button when the composer is empty.
  /// [guidance] carries the active guidance instruction when guidance mode is
  /// open (guided impersonation), otherwise null.
  final void Function(String? guidance)? onImpersonate;
  final bool virtualKeyboardSend;
  final bool enterToSend;
  final bool batterySaver;

  /// When true, the drawer button shows the active state. The host also uses
  /// this to interpret onMagicDrawer as a toggle.
  final bool isDrawerOpen;

  /// Optional focus node from the host so it can mediate keyboard ↔ drawer
  /// transitions (Telegram-style: keyboard and drawer replace each other).
  final FocusNode? focusNode;

  final String initialDraft;
  final ValueChanged<String>? onDraftChanged;

  final bool showSearchControls;
  final String searchQuery;
  final int searchMatchCount;
  final int searchCurrentIndex;
  final VoidCallback? onSearchNext;
  final VoidCallback? onSearchPrev;

  final bool isSelectionMode;
  final int selectedCount;
  final VoidCallback? onCancelSelection;
  final VoidCallback? onHideSelected;
  final VoidCallback? onDeleteSelected;
  final bool allSelectedHidden;
  final bool isEditingMessage;

  /// Chat/character id used to observe impersonation streaming state. When null
  /// the composer behaves as a plain input (e.g. theme preview, tests).
  final String? charId;

  const ChatInputBar({
    super.key,
    required this.onSend,
    this.canSend,
    this.onSendWithGuidance,
    required this.isGenerating,
    this.isGeneratingImage = false,
    this.isPostGenRunning = false,
    this.onStop,
    this.onMagicDrawer,
    this.onSendWithImage,
    this.onFullScreen,
    this.onImpersonate,
    this.virtualKeyboardSend = false,
    this.enterToSend = true,
    this.batterySaver = false,
    this.isDrawerOpen = false,
    this.focusNode,
    this.initialDraft = '',
    this.onDraftChanged,
    this.showSearchControls = false,
    this.searchQuery = '',
    this.searchMatchCount = 0,
    this.searchCurrentIndex = 0,
    this.onSearchNext,
    this.onSearchPrev,
    this.isSelectionMode = false,
    this.selectedCount = 0,
    this.onCancelSelection,
    this.onHideSelected,
    this.onDeleteSelected,
    this.allSelectedHidden = false,
    this.isEditingMessage = false,
    this.charId,
  });

  @override
  ConsumerState<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends ConsumerState<ChatInputBar> {
  static const double _keyboardDismissDragThreshold = 28;

  late final TextEditingController _controller;
  final _guidanceController = TextEditingController();
  bool _guidanceMode = false;
  Timer? _debounce;
  final _internalFocusNode = FocusNode();
  Uint8List? _attachedImageBytes;
  String? _attachedImageDataUrl;
  double _verticalDragDistance = 0;

  /// True while an impersonation stream is filling the composer. The input is
  /// locked and draft persistence is paused so the streamed text is not saved
  /// as the user's draft.
  bool _isImpersonating = false;
  bool _isDispatchingSend = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialDraft);
    _controller.addListener(_onTextChanged);
    _updateFocusNodeHandler();
  }

  void _onTextChanged() {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      // Do not persist streamed impersonation text as the user's draft.
      if (mounted && !_isImpersonating) {
        widget.onDraftChanged?.call(_controller.text);
      }
    });
    setState(() {});
  }

  Future<void> _pickImage() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    var bytes = file.bytes;
    if (bytes == null && file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (bytes == null || !mounted) return;
    final ext = (file.extension ?? 'png').toLowerCase();
    final mime = (ext == 'jpg' || ext == 'jpeg') ? 'image/jpeg' : 'image/png';
    final dataUrl = 'data:$mime;base64,${base64Encode(bytes)}';
    setState(() {
      _attachedImageBytes = bytes;
      _attachedImageDataUrl = dataUrl;
    });
  }

  void _clearImage() {
    setState(() {
      _attachedImageBytes = null;
      _attachedImageDataUrl = null;
    });
  }

  @override
  void didUpdateWidget(ChatInputBar old) {
    super.didUpdateWidget(old);
    if (old.enterToSend != widget.enterToSend ||
        old.isEditingMessage != widget.isEditingMessage ||
        old.focusNode != widget.focusNode) {
      _updateFocusNodeHandler();
    }
  }

  void _updateFocusNodeHandler() {
    final fn = widget.focusNode;
    final effective = _effectiveFocusNode;
    effective.canRequestFocus = !widget.isEditingMessage;
    if (widget.isEditingMessage && effective.hasFocus) {
      effective.unfocus();
    }
    if (fn == null || !widget.enterToSend) return;
    fn.onKeyEvent = (node, event) {
      if (widget.isEditingMessage) {
        return KeyEventResult.ignored;
      }
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.enter &&
          !HardwareKeyboard.instance.isShiftPressed) {
        _handleSend();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _guidanceController.dispose();
    _internalFocusNode.dispose();
    super.dispose();
  }

  FocusNode get _effectiveFocusNode => widget.focusNode ?? _internalFocusNode;

  void _resetVerticalDrag() {
    _verticalDragDistance = 0;
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0;
    if (delta <= 0) {
      _verticalDragDistance = 0;
      return;
    }
    _verticalDragDistance += delta;
  }

  void _handleVerticalDragEnd(BuildContext context) {
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (keyboardVisible &&
        _verticalDragDistance >= _keyboardDismissDragThreshold) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    _resetVerticalDrag();
  }

  /// Mirrors the streamed impersonation text into the composer and locks it
  /// while a stream is in flight. Registered once per build via [ref.listen].
  void _listenImpersonation() {
    final charId = widget.charId;
    if (charId == null) return;
    ref.listen<ImpersonationState>(impersonationStateProvider(charId), (
      prev,
      next,
    ) {
      if (!mounted) return;
      if (next.active) {
        if (!_isImpersonating) {
          setState(() => _isImpersonating = true);
        }
        if (_controller.text != next.text) {
          _controller.value = TextEditingValue(
            text: next.text,
            selection: TextSelection.collapsed(offset: next.text.length),
          );
        }
      } else {
        // Stream finished (or aborted): leave the text for the user to edit.
        if (_isImpersonating) {
          if (_controller.text != next.text && next.text.isNotEmpty) {
            _controller.value = TextEditingValue(
              text: next.text,
              selection: TextSelection.collapsed(offset: next.text.length),
            );
          }
          setState(() => _isImpersonating = false);
        }
      }
    });
  }

  Future<void> _handleSend() async {
    if (widget.isEditingMessage || _isDispatchingSend) return;
    final text = _controller.text;
    final hasImage = _attachedImageDataUrl != null;
    if (text.trim().isEmpty && !hasImage) return;
    // Prerequisites (e.g. a selected provider) failed: keep the composed text
    // and image so nothing is lost while the host shows its modal.
    if (widget.canSend != null && !widget.canSend!()) return;
    final imageDataUrl = _attachedImageDataUrl;
    _isDispatchingSend = true;
    bool accepted;
    try {
      if (imageDataUrl != null) {
        final guidance =
            _guidanceMode && _guidanceController.text.trim().isNotEmpty
            ? _guidanceController.text.trim()
            : null;
        accepted =
            await widget.onSendWithImage?.call(text, guidance, imageDataUrl) ??
            false;
      } else if (_guidanceMode && _guidanceController.text.trim().isNotEmpty) {
        accepted =
            await widget.onSendWithGuidance?.call(
              text,
              _guidanceController.text.trim(),
            ) ??
            false;
      } else {
        if (text.trim().isEmpty) return;
        accepted = await widget.onSend(text);
      }
    } finally {
      _isDispatchingSend = false;
    }
    if (!mounted || !accepted) return;
    // The user may edit the composer while the durable write is pending. Clear
    // only the exact payload that was accepted, never newer text.
    if (_controller.text != text || _attachedImageDataUrl != imageDataUrl) {
      return;
    }
    _controller.clear();
    _guidanceController.clear();
    setState(() {
      _attachedImageBytes = null;
      _attachedImageDataUrl = null;
    });
  }

  Future<void> _openFullscreenEditor() async {
    if (widget.onFullScreen != null) {
      widget.onFullScreen!.call();
      return;
    }

    await FullscreenEditorScreen.show(
      context,
      title: _guidanceMode
          ? 'chat_compose_message'.tr()
          : 'chat_message_title'.tr(),
      initialValue: _controller.text,
      hintText: _guidanceMode
          ? 'chat_long_message_hint'.tr()
          : 'chat_placeholder'.tr(),
      onChanged: (value) {
        if (!mounted) return;
        _controller.text = value;
        setState(() {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final preset = ref.watch(themeProvider.select((s) => s.activePreset));
    final scale = preset.uiFontSize is num
        ? preset.uiFontSizeValue / 15.0
        : 1.0;
    final letterSpacing = preset.uiLetterSpacing;
    final textColor = preset.uiTextParsed ?? context.cs.onSurface;
    final secondaryColor =
        preset.uiTextGrayParsed ?? context.cs.onSurfaceVariant;
    final uiBorder = _uiBorder(context, preset);

    _listenImpersonation();

    if (widget.showSearchControls) {
      final searchContent = BlurRegionTracker(
        id: 'input-pill',
        radius: 28,
        child: GlassSurface(
          enableRipple: true,
          blurViaWebView: true,
          borderRadius: BorderRadius.circular(28),
          tint: context.cs.surface,
          border: uiBorder,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Row(
              children: [
                const SizedBox(width: 18),
                Icon(Icons.search, size: 20, color: context.cs.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.searchMatchCount > 0
                        ? '${widget.searchCurrentIndex + 1} of ${widget.searchMatchCount} matches'
                        : 'search_no_results'.tr(),
                    style: TextStyle(
                      color: textColor,
                      fontSize: 16 * scale,
                      letterSpacing: letterSpacing,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.keyboard_arrow_up,
                    size: 24,
                    color: textColor,
                  ),
                  onPressed: widget.onSearchPrev,
                ),
                IconButton(
                  icon: Icon(
                    Icons.keyboard_arrow_down,
                    size: 24,
                    color: textColor,
                  ),
                  onPressed: widget.onSearchNext,
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      );
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Material(
            color: Colors.transparent,
            elevation: 0,
            borderRadius: BorderRadius.circular(28),
            child: searchContent,
          ),
        ),
      );
    }

    if (widget.isSelectionMode) {
      final selectionContent = BlurRegionTracker(
        id: 'input-pill',
        radius: 28,
        child: GlassSurface(
          enableRipple: true,
          blurViaWebView: true,
          borderRadius: BorderRadius.circular(28),
          tint: context.cs.surface,
          border: uiBorder,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Row(
              children: [
                const SizedBox(width: 8),
                _CircleBtn(
                  icon: Icons.close,
                  onTap: widget.onCancelSelection,
                  batterySaver: widget.batterySaver,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${widget.selectedCount} ${'selected_count'.tr()}',
                    style: TextStyle(
                      color: textColor,
                      fontSize: 16 * scale,
                      fontWeight: FontWeight.w600,
                      letterSpacing: letterSpacing,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _CircleBtn(
                  icon: widget.allSelectedHidden
                      ? Icons.visibility
                      : Icons.visibility_off,
                  onTap: widget.selectedCount > 0
                      ? widget.onHideSelected
                      : null,
                  color: widget.selectedCount > 0
                      ? context.cs.primary
                      : secondaryColor.withValues(alpha: 0.5),
                  batterySaver: widget.batterySaver,
                ),
                const SizedBox(width: 8),
                _CircleBtn(
                  icon: Icons.delete,
                  onTap: widget.selectedCount > 0
                      ? widget.onDeleteSelected
                      : null,
                  color: widget.selectedCount > 0
                      ? Colors.redAccent
                      : secondaryColor.withValues(alpha: 0.5),
                  batterySaver: widget.batterySaver,
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      );
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Material(
            color: Colors.transparent,
            elevation: 0,
            borderRadius: BorderRadius.circular(28),
            child: selectionContent,
          ),
        ),
      );
    }

    final hasContent =
        _controller.text.trim().isNotEmpty ||
        (_guidanceMode && _guidanceController.text.trim().isNotEmpty) ||
        _attachedImageDataUrl != null;
    final isGenerating =
        widget.isGenerating ||
        widget.isGeneratingImage ||
        widget.isPostGenRunning;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: (_) => _resetVerticalDrag(),
      onVerticalDragUpdate: _handleVerticalDragUpdate,
      onVerticalDragEnd: (_) => _handleVerticalDragEnd(context),
      onVerticalDragCancel: _resetVerticalDrag,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_attachedImageBytes != null) ...[
              _AttachedImagePreview(
                imageBytes: _attachedImageBytes!,
                onClear: _clearImage,
                border: uiBorder,
              ),
              const SizedBox(height: 8),
            ],
            if (_guidanceMode) ...[
              Container(
                constraints: const BoxConstraints(minHeight: 44),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.08),
                  border: Border.all(
                    color: Colors.orange.withValues(alpha: 0.3),
                    width: preset.borderWidth.clamp(1.0, double.infinity),
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: TextField(
                  controller: _guidanceController,
                  readOnly: widget.isEditingMessage,
                  canRequestFocus: !widget.isEditingMessage,
                  enableInteractiveSelection: !widget.isEditingMessage,
                  showCursor: !widget.isEditingMessage,
                  maxLines: 3,
                  minLines: 1,
                  textCapitalization: TextCapitalization.sentences,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  style: TextStyle(
                    fontSize: 14 * scale,
                    color: Colors.orange,
                    letterSpacing: letterSpacing,
                  ),
                  decoration: InputDecoration(
                    hintText: 'guidance_placeholder'.tr(),
                    hintStyle: TextStyle(
                      color: Colors.orange.withValues(alpha: 0.5),
                      fontSize: 14 * scale,
                      letterSpacing: letterSpacing,
                    ),
                    prefixIcon: Icon(
                      Icons.tips_and_updates_outlined,
                      color: Colors.orange.withValues(alpha: 0.7),
                      size: 20,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    filled: false,
                  ),
                ),
              ),
              const SizedBox(height: 6),
            ],
            Material(
              color: Colors.transparent,
              elevation: 0,
              borderRadius: BorderRadius.circular(28),
              child: BlurRegionTracker(
                id: 'input-pill',
                radius: 28,
                child: GlassSurface(
                  enableRipple: true,
                  blurViaWebView: true,
                  borderRadius: BorderRadius.circular(28),
                  tint: context.cs.surface,
                  border: _guidanceMode
                      ? Border.all(
                          color: Colors.orange.withValues(alpha: 0.3),
                          width: preset.borderWidth.clamp(1.0, double.infinity),
                        )
                      : uiBorder,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 56),
                    child: TextField(
                      controller: _controller,
                      focusNode: _effectiveFocusNode,
                      readOnly: widget.isEditingMessage || _isImpersonating,
                      canRequestFocus: !widget.isEditingMessage,
                      enableInteractiveSelection: !widget.isEditingMessage,
                      showCursor: !widget.isEditingMessage,
                      maxLines: 5,
                      minLines: 1,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: widget.virtualKeyboardSend
                          ? TextInputAction.send
                          : TextInputAction.newline,
                      onSubmitted: widget.virtualKeyboardSend
                          ? (_) => _handleSend()
                          : null,
                      style: TextStyle(
                        fontSize: 16 * scale,
                        color: textColor,
                        letterSpacing: letterSpacing,
                      ),
                      decoration: InputDecoration(
                        hintText: _guidanceMode
                            ? 'chat_guidance_message_hint'.tr()
                            : 'chat_placeholder'.tr(),
                        hintStyle: TextStyle(
                          color: secondaryColor,
                          fontSize: 16 * scale,
                          letterSpacing: letterSpacing,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 16,
                        ),
                        filled: false,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Null on desktop, where the drawer lives in the right
                    // sidebar instead — drop the button rather than leave a
                    // dead one behind.
                    if (widget.onMagicDrawer != null) ...[
                      _CircleBtn(
                        icon: Icons.auto_awesome,
                        onTap: widget.onMagicDrawer,
                        color: widget.isDrawerOpen ? Colors.amber : null,
                        batterySaver: widget.batterySaver,
                        blurRegionId: 'btn-magic',
                      ),
                      const SizedBox(width: 8),
                    ],
                    _CircleBtn(
                      icon: Icons.attach_file,
                      onTap: _pickImage,
                      batterySaver: widget.batterySaver,
                      blurRegionId: 'btn-attach',
                    ),
                    const SizedBox(width: 8),
                    _CircleBtn(
                      icon: Icons.fullscreen,
                      onTap: _openFullscreenEditor,
                      batterySaver: widget.batterySaver,
                      blurRegionId: 'btn-fullscreen',
                    ),
                    const SizedBox(width: 8),
                    _CircleBtn(
                      icon: Icons.north_east,
                      onTap: () => setState(() {
                        _guidanceMode = !_guidanceMode;
                        if (!_guidanceMode) _guidanceController.clear();
                      }),
                      color: _guidanceMode ? Colors.orange : null,
                      batterySaver: widget.batterySaver,
                      blurRegionId: 'btn-guidance',
                    ),
                  ],
                ),
                _SendBtn(
                  icon: isGenerating
                      ? Icons.stop_rounded
                      : hasContent
                      ? (_guidanceMode && _controller.text.trim().isEmpty
                            ? Icons.check_rounded
                            : Icons.send_rounded)
                      : Icons.account_circle_rounded,
                  batterySaver: widget.batterySaver,
                  onTap: () {
                    if (isGenerating) {
                      widget.onStop?.call();
                    } else if (widget.isEditingMessage) {
                      return;
                    } else if (hasContent) {
                      _handleSend();
                    } else {
                      final guidance =
                          _guidanceMode &&
                              _guidanceController.text.trim().isNotEmpty
                          ? _guidanceController.text.trim()
                          : null;
                      widget.onImpersonate?.call(guidance);
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachedImagePreview extends StatelessWidget {
  final Uint8List imageBytes;
  final VoidCallback onClear;
  final BoxBorder? border;

  const _AttachedImagePreview({
    required this.imageBytes,
    required this.onClear,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 150, maxHeight: 150),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border:
              border ?? Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(imageBytes, fit: BoxFit.contain),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: GestureDetector(
                onTap: onClear,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, color: Colors.white, size: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CircleBtn extends ConsumerStatefulWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final Color? color;
  final bool batterySaver;

  /// When set, the button's rect is mirrored into the chat WebView as a
  /// backdrop-blur region (see [BlurRegionTracker]). Only buttons that sit
  /// directly over the WebView (the bottom row) need one; buttons nested
  /// inside an already-tracked pill must leave it null.
  final String? blurRegionId;

  const _CircleBtn({
    required this.icon,
    this.onTap,
    this.color,
    this.batterySaver = false,
    this.blurRegionId,
  });

  @override
  ConsumerState<_CircleBtn> createState() => _CircleBtnState();
}

class _CircleBtnState extends ConsumerState<_CircleBtn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _press;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 80),
      reverseDuration: const Duration(milliseconds: 150),
    );
    _scale = Tween<double>(
      begin: 1.0,
      end: 0.82,
    ).animate(CurvedAnimation(parent: _press, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preset = ref.watch(themeProvider.select((s) => s.activePreset));
    final btn = GestureDetector(
      onTap: widget.onTap,
      onTapDown: (widget.onTap != null && !widget.batterySaver)
          ? (_) => _press.forward()
          : null,
      onTapUp: (widget.onTap != null && !widget.batterySaver)
          ? (_) => _press.reverse()
          : null,
      onTapCancel: (widget.onTap != null && !widget.batterySaver)
          ? () => _press.reverse()
          : null,
      child: ScaleTransition(
        scale: _scale,
        child: SizedBox(
          width: 40,
          height: 40,
          child: GlassSurface(
            // Only the top-level circle buttons carry a blurRegionId (they
            // float over the WebView and are mirrored to a CSS strip); the
            // ones nested inside the input pill keep their Flutter blur.
            blurViaWebView: widget.blurRegionId != null,
            borderRadius: BorderRadius.circular(20),
            tint: context.cs.surface,
            border: _uiBorder(context, preset),
            child: Center(
              child: Icon(
                widget.icon,
                color: widget.color ?? context.cs.primary,
                size: 20,
              ),
            ),
          ),
        ),
      ),
    );
    final regionId = widget.blurRegionId;
    if (regionId == null) return btn;
    return BlurRegionTracker(id: regionId, radius: 20, child: btn);
  }
}

class _SendBtn extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool batterySaver;

  const _SendBtn({required this.icon, this.onTap, this.batterySaver = false});

  @override
  State<_SendBtn> createState() => _SendBtnState();
}

class _SendBtnState extends State<_SendBtn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _press;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 80),
      reverseDuration: const Duration(milliseconds: 150),
    );
    _scale = Tween<double>(
      begin: 1.0,
      end: 0.82,
    ).animate(CurvedAnimation(parent: _press, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: widget.onTap,
      onTapDown: widget.batterySaver ? null : (_) => _press.forward(),
      onTapUp: widget.batterySaver ? null : (_) => _press.reverse(),
      onTapCancel: widget.batterySaver ? null : () => _press.reverse(),
      child: ScaleTransition(
        scale: _scale,
        child: Container(
          height: 40,
          width: 40,
          decoration: BoxDecoration(
            color: context.cs.primary,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.8, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: child,
                ),
              ),
              child: Icon(
                widget.icon,
                key: ValueKey(widget.icon),
                color: Colors.black,
                size: 20,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
