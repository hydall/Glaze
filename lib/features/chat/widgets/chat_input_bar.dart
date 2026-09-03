import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/haptics.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/theme/theme_preset.dart';
import '../../../shared/theme/theme_provider.dart';
import '../../../shared/widgets/fullscreen_editor.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../chat_provider.dart'
    show ImpersonationState, chatProvider, impersonationStateProvider;
import '../composer_empty_action_provider.dart';
import '../composer_pins_provider.dart';
import '../quick_replies_provider.dart';
import '../services/drawer_item_launcher.dart';
import '../state/chat_drawer_editing_provider.dart';
import 'chat_blur_region_tracker.dart';
import 'magic_drawer_catalog.dart';
import 'magic_drawer_widgets.dart';

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

  /// Runs before a pinned quick reply starts a generation; false aborts it.
  /// The drawer's Actions tab is handed the same guard, so a reply behaves the
  /// same whether it is tapped in the grid or up here.
  final Future<bool> Function()? beforeGeneration;

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
    this.beforeGeneration,
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

  /// Held rather than looked up on demand: `dispose` has to hand the bridge
  /// back, and `ref` is off limits once the element is being unmounted.
  late final ComposerActionBridge _actionBridge;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialDraft);
    _controller.addListener(_onTextChanged);
    _updateFocusNodeHandler();
    // Attach / fullscreen / guidance act on the controllers this State owns, so
    // the drawer cannot run them itself once one of their cards is sitting in
    // its Actions grid. Hand it a way in.
    _actionBridge = ref.read(composerActionBridgeProvider)
      ..register(_runComposerAction);
  }

  /// Runs a composer-owned action asked for from the drawer's Actions tab.
  void _runComposerAction(ComposerAction action) {
    if (!mounted) return;
    switch (action) {
      case ComposerAction.drawer:
        widget.onMagicDrawer?.call();
      case ComposerAction.attach:
        unawaited(_pickImage());
      case ComposerAction.fullscreen:
        unawaited(_openFullscreenEditor());
      case ComposerAction.guidance:
        _toggleGuidance();
    }
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
    // Identity-checked inside, so a session switch — which re-keys this widget
    // and can mount the replacement before this runs — cannot leave the drawer
    // holding a handler into a disposed State.
    _actionBridge.unregister(_runComposerAction);
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
    final imageBytes = _attachedImageBytes;
    final guidance = _guidanceMode && _guidanceController.text.trim().isNotEmpty
        ? _guidanceController.text.trim()
        : null;
    _isDispatchingSend = true;
    // Empty the composer on the tap, not on durable acceptance. Behind a send
    // is a whole re-encode of the message list, and on a long chat that is
    // seconds of the message sitting in the box next to its own bubble,
    // reading as a send that never registered. The payload is captured above,
    // so the rare rejection puts it straight back.
    _clearComposedPayload();
    bool accepted;
    try {
      if (imageDataUrl != null) {
        accepted =
            await widget.onSendWithImage?.call(text, guidance, imageDataUrl) ??
            false;
      } else if (guidance != null) {
        accepted =
            await widget.onSendWithGuidance?.call(text, guidance) ?? false;
      } else {
        accepted = await widget.onSend(text);
      }
    } finally {
      _isDispatchingSend = false;
    }
    if (!mounted || accepted) return;
    _restoreComposedPayload(
      text: text,
      guidance: guidance,
      imageBytes: imageBytes,
      imageDataUrl: imageDataUrl,
    );
  }

  void _clearComposedPayload() {
    _controller.clear();
    _guidanceController.clear();
    setState(() {
      _attachedImageBytes = null;
      _attachedImageDataUrl = null;
    });
  }

  /// Puts a rejected send's payload back in the composer — unless the user has
  /// already started composing something newer, which outranks it.
  void _restoreComposedPayload({
    required String text,
    required String? guidance,
    required Uint8List? imageBytes,
    required String? imageDataUrl,
  }) {
    if (_controller.text.isNotEmpty || _attachedImageDataUrl != null) return;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    if (guidance != null && _guidanceController.text.isEmpty) {
      _guidanceController.text = guidance;
    }
    setState(() {
      _attachedImageBytes = imageBytes;
      _attachedImageDataUrl = imageDataUrl;
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

  /// The configurable button row under the composer.
  ///
  /// What sits here comes from [composerPinsProvider], and it is no longer only
  /// composer actions: a quick reply or a Tools card can be pinned up here too,
  /// and whatever is pinned is filtered out of the drawer tab it came from. A
  /// pin whose target is gone (a deleted quick reply, a card this build
  /// dropped, the drawer button on desktop) resolves to nothing and is skipped
  /// — a dead button is worse than a missing one.
  ///
  /// The row is edited from the drawer's pencil rather than from a settings
  /// sheet of its own: while [chatDrawerEditingProvider] is on and the drawer is
  /// open, each button can be dragged along the row and carries a down-arrow
  /// that drops it back into its tab. The other direction has no badge — a card
  /// dragged out of a drawer grid and dropped here is what puts it up.
  Widget _buildActionRow(bool editing) {
    final pins = ref.watch(composerPinsProvider).value ?? kDefaultComposerPins;

    final buttons = <Widget>[];
    for (var index = 0; index < pins.length; index++) {
      final button = _buildPinnedButton(pins[index], editing);
      if (button == null) continue;
      if (buttons.isNotEmpty) buttons.add(const SizedBox(width: 8));
      buttons.add(button);
    }
    if (buttons.isEmpty) return const SizedBox.shrink();

    final strip = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      // Dragging a button along the row and scrolling the row are the same
      // gesture, so edit mode takes the scroll away. A row long enough to
      // overflow is a row worth thinning out with the down-arrows anyway.
      physics: editing
          ? const NeverScrollableScrollPhysics()
          : const ClampingScrollPhysics(),
      // Room for the badges edit mode hangs off each button's corner, reserved
      // in both states so turning edit mode on does not nudge the row.
      padding: const EdgeInsets.only(top: 6, right: 6),
      child: Row(mainAxisSize: MainAxisSize.min, children: buttons),
    );
    if (!editing) return strip;

    // Catches a card dropped on the row rather than on one of its buttons —
    // the gap past the last one, or anywhere at all when the row is down to the
    // drawer button. The per-button targets sit deeper in the tree and win when
    // the drop lands on one, so this only ever handles the leftovers.
    return DragTarget<ComposerPin>(
      onWillAcceptWithDetails: (details) => !pins.contains(details.data),
      onAcceptWithDetails: (details) => _pin(details.data, pins.length),
      builder: (context, _, _) => strip,
    );
  }

  /// Null when [pin] has nothing to do in the current layout.
  Widget? _buildPinnedButton(ComposerPin pin, bool editing) {
    final resolved = _resolvePin(pin);
    if (resolved == null) return null;

    final button = _CircleBtn(
      icon: resolved.icon,
      // Edit mode is for arranging the row, not for firing it: a tap that both
      // reorders and sends would be a trap.
      onTap: editing ? null : resolved.onTap,
      color: resolved.color,
      batterySaver: widget.batterySaver,
      blurRegionId: 'btn-pin-${pin.encode()}',
    );
    if (!editing) return button;

    final content = Stack(
      clipBehavior: Clip.none,
      children: [
        button,
        // Mirrors the up-arrow the drawer's cards carry, in the same accent:
        // one gesture, one colour, opposite directions.
        if (!pin.isPermanent)
          Positioned(
            top: -6,
            right: -6,
            child: MagicCardBadge(
              icon: Icons.arrow_downward,
              color: context.cs.primary,
              tooltip: 'composer_pin_remove'.tr(),
              size: 18,
              onTap: () => _unpin(pin),
            ),
          ),
      ],
    );

    // Carries the pin itself rather than its index, for two reasons: the drop
    // resolves against the list as it is *then*, and the payload type is one
    // the drawer's grids cannot produce. Both grids are on screen right now,
    // and a shared payload type would have let a card dragged out of one land
    // in this row as a reorder of whatever happened to share its index.
    return DragTarget<ComposerPin>(
      onWillAcceptWithDetails: (details) => details.data != pin,
      onAcceptWithDetails: (details) {
        final current =
            ref.read(composerPinsProvider).value ?? const <ComposerPin>[];
        final to = current.indexOf(pin);
        if (to < 0) return;
        final from = current.indexOf(details.data);
        // Below zero means the payload came from a drawer grid rather than
        // from this row, so it is an arrival, not a move.
        if (from < 0) {
          _pin(details.data, to);
        } else {
          ref.read(composerPinsProvider.notifier).reorder(from, to);
        }
      },
      builder: (context, _, _) => Draggable<ComposerPin>(
        // A plain [Draggable], not the grid's long-press one: edit mode has
        // already claimed the row, so a button has nothing else a press could
        // mean and moving one should cost a single finger movement.
        data: pin,
        axis: Axis.horizontal,
        feedback: Material(
          color: Colors.transparent,
          child: Opacity(
            opacity: 0.92,
            // No blur region on the copy under the finger: it lives in the root
            // overlay, outside the chat's tracker scope, and mirroring a moving
            // rect into the WebView would only chase it.
            child: _CircleBtn(
              icon: resolved.icon,
              color: resolved.color,
              batterySaver: widget.batterySaver,
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.25, child: content),
        child: content,
      ),
    );
  }

  /// The send button — and, while the composer is empty, the one slot in the
  /// composer the drawer's pencil can retarget.
  ///
  /// With text in the box the button sends, mid-generation it stops, and edit
  /// mode leaves both of those alone: neither is a preference. Empty, it has
  /// always guessed — it impersonated the user — so that state is the one the
  /// user gets to assign. Whatever [composerEmptyActionProvider] holds lends
  /// the button its glyph and its tap; an Actions card dropped on it in edit
  /// mode is what puts it there, and the undo badge hands the impersonation
  /// back. Tools are turned away at the drop — see
  /// [ComposerEmptyActionNotifier.isAssignable].
  ///
  /// Only the empty state goes dead in edit mode, for the reason the row's
  /// buttons all do: a tap that both retargets and fires would be a trap.
  /// Sending and stopping stay live, since neither is what the drop is aimed
  /// at.
  Widget _buildSendButton({
    required bool isGenerating,
    required bool hasContent,
    required bool editing,
  }) {
    final emptyPin = ref.watch(composerEmptyActionProvider).value;
    // Null once the thing it points at is gone — a quick reply since deleted,
    // the drawer button on desktop. The button falls back to impersonation
    // rather than wearing a glyph that does nothing.
    final emptyAction = emptyPin == null ? null : _resolvePin(emptyPin);

    final button = _SendBtn(
      icon: isGenerating
          ? Icons.stop_rounded
          : hasContent
          ? (_guidanceMode && _controller.text.trim().isEmpty
                ? Icons.check_rounded
                : Icons.send_rounded)
          : (emptyAction?.icon ?? Icons.account_circle_rounded),
      batterySaver: widget.batterySaver,
      onTap: editing && !isGenerating && !hasContent
          ? null
          : () {
              if (isGenerating) {
                widget.onStop?.call();
              } else if (widget.isEditingMessage) {
                return;
              } else if (hasContent) {
                _handleSend();
              } else if (emptyAction?.onTap != null) {
                emptyAction!.onTap!();
              } else {
                final guidance =
                    _guidanceMode &&
                        _guidanceController.text.trim().isNotEmpty
                    ? _guidanceController.text.trim()
                    : null;
                widget.onImpersonate?.call(guidance);
              }
            },
    );
    if (!editing) return button;

    final content = Stack(
      clipBehavior: Clip.none,
      children: [
        button,
        // Reset, not the row's demote arrow: an assignment here never took the
        // card out of its tab, so there is nothing to send back — only a
        // default to restore.
        if (emptyPin != null)
          Positioned(
            top: -6,
            right: -6,
            child: MagicCardBadge(
              icon: Icons.undo,
              color: context.cs.primary,
              tooltip: 'composer_empty_action_reset'.tr(),
              size: 18,
              onTap: _resetEmptyAction,
            ),
          ),
      ],
    );

    return Tooltip(
      // The slot is invisible the moment anything is typed, so the hint is the
      // only thing that says a drop lands here at all.
      message: 'composer_empty_action_hint'.tr(),
      preferBelow: false,
      child: DragTarget<ComposerPin>(
        // Actions only, so a Tools card dragged across the button is refused
        // rather than silently swallowed: the drag keeps looking for the row
        // below, which is where a tool belongs.
        onWillAcceptWithDetails: (details) =>
            details.data != emptyPin &&
            ComposerEmptyActionNotifier.isAssignable(details.data),
        onAcceptWithDetails: (details) => _assignEmptyAction(details.data),
        // Scale rather than a ring: a border would grow the 40px circle and
        // shove the row it shares a baseline with.
        builder: (context, candidate, _) => AnimatedScale(
          duration: const Duration(milliseconds: 120),
          scale: candidate.isEmpty ? 1.0 : 1.15,
          child: content,
        ),
      ),
    );
  }

  /// Points the empty composer's button at [pin]. The pin keeps its place in
  /// the drawer or the row — see [composerEmptyActionProvider].
  void _assignEmptyAction(ComposerPin pin) {
    Haptics.mediumImpact();
    unawaited(ref.read(composerEmptyActionProvider.notifier).assign(pin));
  }

  void _resetEmptyAction() {
    Haptics.mediumImpact();
    unawaited(ref.read(composerEmptyActionProvider.notifier).reset());
  }

  void _unpin(ComposerPin pin) {
    Haptics.mediumImpact();
    unawaited(ref.read(composerPinsProvider.notifier).unpin(pin));
  }

  /// Lands a card dragged out of a drawer grid at [index] in the row.
  void _pin(ComposerPin pin, int index) {
    Haptics.mediumImpact();
    unawaited(ref.read(composerPinsProvider.notifier).pinAt(pin, index));
  }

  /// Icon, tint and callback for one pinned button, or null when the thing it
  /// points at is unavailable here.
  _ResolvedPin? _resolvePin(ComposerPin pin) {
    switch (pin.kind) {
      case ComposerPinKind.action:
        return _resolveAction(pin.asAction);
      case ComposerPinKind.reply:
        final reply = (ref.watch(quickRepliesProvider).value ?? const [])
            .where((r) => r.id == pin.refId)
            .firstOrNull;
        if (reply == null) return null;
        return _ResolvedPin(
          icon: reply.icon,
          onTap: () => _sendQuickReply(reply),
        );
      case ComposerPinKind.tool:
        final charId = widget.charId;
        final def = magicDrawerItemById(pin.refId);
        // Tools open sheets against a chat; without a charId (theme preview,
        // tests) there is none to open them against.
        if (charId == null || def == null) return null;
        return _ResolvedPin(
          icon: def.icon,
          onTap: () => DrawerItemLauncher(
            ref: ref,
            charId: charId,
          ).open(context, def.id),
        );
    }
  }

  _ResolvedPin? _resolveAction(ComposerAction? action) {
    switch (action) {
      case null:
        return null;
      case ComposerAction.drawer:
        // Null on desktop, where the drawer lives in the right sidebar
        // instead — drop the button rather than leave a dead one behind.
        if (widget.onMagicDrawer == null) return null;
        return _ResolvedPin(
          icon: action.icon,
          onTap: widget.onMagicDrawer,
          color: widget.isDrawerOpen ? Colors.amber : null,
        );
      case ComposerAction.attach:
        return _ResolvedPin(icon: action.icon, onTap: _pickImage);
      case ComposerAction.fullscreen:
        return _ResolvedPin(icon: action.icon, onTap: _openFullscreenEditor);
      case ComposerAction.guidance:
        return _ResolvedPin(
          icon: action.icon,
          onTap: _toggleGuidance,
          color: _guidanceMode ? Colors.orange : null,
        );
    }
  }

  void _toggleGuidance() {
    setState(() {
      _guidanceMode = !_guidanceMode;
      if (!_guidanceMode) _guidanceController.clear();
    });
  }

  /// Sends a quick reply pinned to the row, on the same terms the drawer's
  /// Actions tab sends it: the host's pre-generation guard first, then either
  /// the built-in continue or the reply's text.
  Future<void> _sendQuickReply(QuickReply reply) async {
    final charId = widget.charId;
    if (charId == null) return;
    if (await widget.beforeGeneration?.call() == false) return;
    if (!mounted) return;
    final notifier = ref.read(chatProvider(charId).notifier);
    if (reply.isContinueAction) {
      await notifier.continueMessage();
    } else if (reply.text.trim().isNotEmpty) {
      await notifier.sendMessage(reply.text);
    }
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
    // Gated on the drawer being open as well as on edit mode: with the drawer
    // shut there is nowhere for a demoted button to land, nothing on screen to
    // drag into the send button, and no pencil to explain the badges.
    final editing = widget.isDrawerOpen && ref.watch(chatDrawerEditingProvider);

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
            // 4, not the 10 this gap used to be: the row reserves 6px of its
            // own for the badges edit mode hangs above the buttons.
            const SizedBox(height: 4),
            Row(
              children: [
                // Expanded, so a row long enough to overflow scrolls instead of
                // shoving the send button off the screen.
                Expanded(child: _buildActionRow(editing)),
                const SizedBox(width: 8),
                _buildSendButton(
                  isGenerating: isGenerating,
                  hasContent: hasContent,
                  editing: editing,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// What a [ComposerPin] turns into once the composer has looked it up: the
/// glyph to draw, the tint to draw it in, and what a tap does. Keeps the row
/// builder free of the three-way switch that produces it.
class _ResolvedPin {
  final IconData icon;
  final VoidCallback? onTap;

  /// Active-state tint (the drawer button while the drawer is open, guidance
  /// while the field is up); null leaves the button in the accent colour.
  final Color? color;

  const _ResolvedPin({required this.icon, this.onTap, this.color});
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
