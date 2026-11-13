import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../../core/models/chat_message.dart' show maxMessageAttachments;
import '../../../core/platform/clipboard_images.dart';
import '../../../core/platform/haptics.dart';
import '../../../core/plugins/plugin_hooks.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/utils/error_format.dart';
import '../../../shared/shell/desktop/desktop_layout_provider.dart';
import '../../../shared/widgets/fullscreen_editor.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../guides/guide_anchor.dart';
import '../../translation/composer_translator.dart';
import '../../translation/translation_service.dart';
import '../chat_drawer_controller.dart' show ComposerFocus;
import '../chat_provider.dart'
    show ImpersonationState, chatProvider, impersonationStateProvider;
import '../composer_empty_action_provider.dart';
import '../composer_pins_provider.dart';
import '../composer_text_bridge.dart';
import '../hidden_composer_actions_provider.dart';
import '../quick_replies_provider.dart';
import '../services/drawer_item_launcher.dart';
import '../state/chat_drawer_editing_provider.dart';
import '../widgets/magic_drawer_catalog.dart';
import 'chat_chrome_channel.dart';
import 'chrome_json.dart';

/// The composer of a chat: what [ChatInputBar] was, with the drawing moved
/// into the chat WebView (see `assets/chat_webview/chrome/composer.js`).
///
/// Everything the composer *does* still lives here — sending and its guards,
/// the draft, attachments, guidance, impersonation streaming in, the pinned
/// row and its edit mode, the empty composer's action — and so do the
/// controllers holding the text. The page owns only the field the keyboard
/// types into: it reports every change, and this writes the text back when it
/// changes it itself.
///
/// What it builds is not the composer but what Flutter keeps on top of it: the
/// guide-tour anchors at the page's rects, and on desktop the drop targets that
/// take a card dragged out of the sidebar's drawer onto the row.
class ChatComposerHost extends ConsumerStatefulWidget {
  final ChatChromeChannel channel;

  /// The composer field's focus, as the page reports it; the drawer controller
  /// mediates keyboard ↔ drawer with it.
  final ComposerFocus composerFocus;

  final Future<bool> Function(String text) onSend;
  final bool Function()? canSend;
  final Future<bool> Function(String text, String? guidance)?
  onSendWithGuidance;
  final bool isGenerating;
  final bool isGeneratingImage;
  final bool isPostGenRunning;
  final VoidCallback? onStop;
  final VoidCallback? onMagicDrawer;
  final Future<bool> Function(
    String text,
    String? guidanceText,
    List<String> imageDataUrls,
  )?
  onSendWithImages;
  final void Function(String? guidance)? onImpersonate;
  final bool virtualKeyboardSend;
  final bool enterToSend;
  final bool isDrawerOpen;
  final String initialDraft;
  final ValueChanged<String>? onDraftChanged;

  final bool showSearchControls;
  final int searchMatchCount;
  final int searchCurrentIndex;
  final VoidCallback? onSearchNext;
  final VoidCallback? onSearchPrev;

  final bool isSelectionMode;
  final int selectedCount;
  final VoidCallback? onCancelSelection;
  final VoidCallback? onHideSelected;
  final VoidCallback? onDeleteSelected;
  final bool canDeleteSelected;
  final VoidCallback? onSelectAbove;
  final VoidCallback? onSelectBelow;
  final bool allSelectedHidden;
  final bool isEditingMessage;
  final String charId;
  final Future<bool> Function()? beforeGeneration;

  const ChatComposerHost({
    super.key,
    required this.channel,
    required this.composerFocus,
    required this.onSend,
    required this.charId,
    this.canSend,
    this.onSendWithGuidance,
    required this.isGenerating,
    this.isGeneratingImage = false,
    this.isPostGenRunning = false,
    this.onStop,
    this.onMagicDrawer,
    this.onSendWithImages,
    this.onImpersonate,
    this.virtualKeyboardSend = false,
    this.enterToSend = false,
    this.isDrawerOpen = false,
    this.initialDraft = '',
    this.onDraftChanged,
    this.showSearchControls = false,
    this.searchMatchCount = 0,
    this.searchCurrentIndex = 0,
    this.onSearchNext,
    this.onSearchPrev,
    this.isSelectionMode = false,
    this.selectedCount = 0,
    this.onCancelSelection,
    this.onHideSelected,
    this.onDeleteSelected,
    this.canDeleteSelected = false,
    this.onSelectAbove,
    this.onSelectBelow,
    this.allSelectedHidden = false,
    this.isEditingMessage = false,
    this.beforeGeneration,
  });

  @override
  ConsumerState<ChatComposerHost> createState() => _ChatComposerHostState();
}

/// An attachment queued for the next message, with an id the page can name.
class _Attachment {
  _Attachment(this.id, this.image);
  final int id;
  final ClipboardImage image;
}

class _ChatComposerHostState extends ConsumerState<ChatComposerHost> {
  late final TextEditingController _controller;
  final _guidanceController = TextEditingController();
  bool _guidanceMode = false;
  Timer? _debounce;
  final List<_Attachment> _attachments = [];
  int _nextAttachmentId = 0;
  bool _isImpersonating = false;
  bool _isDispatchingSend = false;

  /// Set while the controllers take what the page reported, so it is not sent
  /// straight back.
  bool _fromPage = false;
  int _textRevision = 0;
  int _guidanceRevision = 0;

  late final ComposerActionBridge _actionBridge;
  late final ComposerTextBridge _textBridge;
  late final VoidCallback _removeIntents;
  late final ComposerTextAccess _textAccess = ComposerTextAccess(
    read: () => _controller.text,
    write: (text) {
      if (!mounted) return;
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    },
    send: () async => mounted && await _handleSend(),
  );

  late final ComposerTranslator _draftTranslator = ComposerTranslator(
    _controller,
  )..addListener(_onDraftTranslatorChanged);

  ChatChromeChannel get _channel => widget.channel;

  /// True while [build] runs. Pins and the send button are resolved both in
  /// build (to describe them to the page) and in intent handlers (to run
  /// them); only the first may subscribe.
  bool _building = false;

  T _get<T>(ProviderListenable<T> provider) =>
      _building ? ref.watch(provider) : ref.read(provider);

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialDraft);
    _controller.addListener(_onTextChanged);
    _guidanceController.addListener(_onGuidanceChanged);
    _actionBridge = ref.read(composerActionBridgeProvider)
      ..register(_runComposerAction);
    _textBridge = ref.read(composerTextBridgeProvider)..register(_textAccess);
    _bindFocus();
    _removeIntents = _channel.onAll({
      'text': (d) => _takePageText(_controller, d['v'], rev: d['rev']),
      'guidanceText': (d) =>
          _takePageText(_guidanceController, d['v'], rev: d['rev']),
      'focus': (d) => widget.composerFocus.setFocused(d['f'] == true),
      'sendTap': _onSendTap,
      'pinTap': _onPinTap,
      'unpin': (d) {
        final pin = _pinOf(d['key']);
        if (pin != null) _unpin(pin);
      },
      'pinDrop': _onPinDrop,
      'assignEmpty': (d) {
        final pin = _pinOf(d['key']);
        if (pin == null || !ComposerEmptyActionNotifier.isAssignable(pin)) {
          return;
        }
        if (pin == ref.read(composerEmptyActionProvider).value) return;
        _assignEmptyAction(pin);
      },
      'resetEmpty': (_) => _resetEmptyAction(),
      'attach': _onAttach,
      'removeAttachment': (d) {
        final id = d['id'];
        final index = _attachments.indexWhere((a) => a.id == id);
        if (index >= 0) setState(() => _attachments.removeAt(index));
      },
      'pasteRequest': (_) => unawaited(_pasteImagesFromClipboard()),
      'guidanceClose': (_) {
        if (!widget.isEditingMessage) _toggleGuidance();
      },
      'searchPrev': (_) => widget.onSearchPrev?.call(),
      'searchNext': (_) => widget.onSearchNext?.call(),
      'selCancel': (_) => widget.onCancelSelection?.call(),
      'selAbove': (_) => widget.onSelectAbove?.call(),
      'selBelow': (_) => widget.onSelectBelow?.call(),
      'selHide': (_) {
        if (widget.selectedCount > 0) widget.onHideSelected?.call();
      },
      'selDelete': (_) {
        if (widget.selectedCount > 0 && widget.canDeleteSelected) {
          widget.onDeleteSelected?.call();
        }
      },
    });
    // The draft the chat opened with.
    _sendText();
  }

  void _bindFocus() {
    widget.composerFocus
      ..onUnfocusRequested = (() => _channel.push('cmd', {'blur': true}))
      ..onFocusRequested = (() => _channel.push('cmd', {'focus': true}));
  }

  @override
  void didUpdateWidget(ChatComposerHost old) {
    super.didUpdateWidget(old);
    if (old.composerFocus != widget.composerFocus) {
      old.composerFocus
        ..onUnfocusRequested = null
        ..onFocusRequested = null;
      _bindFocus();
    }
    if (widget.isEditingMessage && widget.composerFocus.hasFocus) {
      widget.composerFocus.unfocus();
    }
  }

  @override
  void dispose() {
    _removeIntents();
    widget.composerFocus
      ..onUnfocusRequested = null
      ..onFocusRequested = null;
    _actionBridge.unregister(_runComposerAction);
    _textBridge.unregister(_textAccess);
    _debounce?.cancel();
    _draftTranslator.dispose();
    _controller.dispose();
    _guidanceController.dispose();
    super.dispose();
  }

  /* ---------- Text ---------- */

  void _takePageText(
    TextEditingController controller,
    Object? raw, {
    Object? rev,
  }) {
    if (!mounted || raw is! String || controller.text == raw) return;
    final isText = identical(controller, _controller);
    // Typed over a text this has since replaced: the replacement is on its
    // way to the page and wins.
    if (rev is num && rev < (isText ? _textRevision : _guidanceRevision)) {
      return;
    }
    _fromPage = true;
    try {
      controller.value = TextEditingValue(
        text: raw,
        selection: TextSelection.collapsed(offset: raw.length),
      );
    } finally {
      _fromPage = false;
    }
    // What the page now holds, so a page that is reloaded gets it back. Not
    // sent to this page: written back, it would land after the next
    // keystroke and undo it.
    if (isText) {
      _channel.remember('text', {'v': raw, 'rev': _textRevision});
    } else {
      _channel.remember('guidanceText', {'v': raw, 'rev': _guidanceRevision});
    }
  }

  void _sendText() {
    _channel.set('text', {'v': _controller.text, 'rev': ++_textRevision});
  }

  void _onTextChanged() {
    if (!_fromPage) _sendText();
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted && !_isImpersonating) {
        widget.onDraftChanged?.call(_controller.text);
      }
    });
    setState(() {});
  }

  void _onGuidanceChanged() {
    if (!_fromPage) {
      _channel.set('guidanceText', {
        'v': _guidanceController.text,
        'rev': ++_guidanceRevision,
      });
    }
    if (mounted) setState(() {});
  }

  /* ---------- Composer actions ---------- */

  void _runComposerAction(ComposerAction action) {
    if (!mounted) return;
    switch (action) {
      case ComposerAction.drawer:
        widget.onMagicDrawer?.call();
      case ComposerAction.attach:
        unawaited(_pickImages());
      case ComposerAction.fullscreen:
        unawaited(_openFullscreenEditor());
      case ComposerAction.guidance:
        _toggleGuidance();
      case ComposerAction.asterisk:
      case ComposerAction.quote:
        final token = action.insertToken;
        if (token != null) _insertSurround(token);
      case ComposerAction.translate:
        unawaited(_translateDraft());
    }
  }

  bool get _translationEnabled =>
      ref.read(pipelineSettingsProvider).translation.enabled;

  void _onDraftTranslatorChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _translateDraft() async {
    if (!_translationEnabled) return;
    await _draftTranslator.toggle(
      translate: (text, token) => ref
          .read(translationServiceProvider)
          .translate(
            text: text,
            targetLanguageCode: ref
                .read(pipelineSettingsProvider)
                .translation
                .inputLanguage,
            cancelToken: token,
          ),
      onEmpty: () {
        if (mounted) GlazeToast.show(context, 'translation_input_empty'.tr());
      },
      onError: (error) {
        if (!mounted) return;
        GlazeToast.show(
          context,
          error is TranslationNotConfiguredException
              ? 'translation_not_configured'.tr()
              : 'translation_failed'.tr(args: [formatError(error)]),
          isError: true,
        );
      },
    );
  }

  /// Wraps the caret / selection in a pair of [token]. Done in the page, which
  /// knows where the caret is; it reports the new text back.
  void _insertSurround(String token) {
    _channel.push('cmd', {'insert': token});
  }

  /* ---------- Attachments ---------- */

  int get _remainingAttachmentSlots =>
      maxMessageAttachments - _attachments.length;

  static const _imageExtensions = {
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'heic',
    'heif',
  };

  static bool _isImageName(String name) {
    final dot = name.lastIndexOf('.');
    return dot >= 0 &&
        _imageExtensions.contains(name.substring(dot + 1).toLowerCase());
  }

  static Future<Uint8List?> _readPicked(PlatformFile file) async {
    if (file.bytes != null || file.path == null) return file.bytes;
    try {
      return await File(file.path!).readAsBytes();
    } catch (error) {
      debugPrint('[ChatComposer] attachment read failed: $error');
      return null;
    }
  }

  Future<void> _pickImages() async {
    final plugins = ref.read(pluginHookRegistryProvider).forChat(widget.charId);
    final acceptsFiles = plugins?.fileExtensions.isNotEmpty ?? false;
    if (!acceptsFiles && _atAttachmentLimit()) return;
    final result = await FilePicker.pickFiles(
      type: acceptsFiles ? FileType.any : FileType.image,
      allowMultiple: true,
      withData: true,
    );
    if (result == null || result.files.isEmpty || !mounted) return;
    final images = acceptsFiles
        ? result.files.where((f) => _isImageName(f.name)).toList()
        : result.files;
    if (images.isNotEmpty) {
      final slots = _remainingAttachmentSlots;
      final picked = <ClipboardImage>[];
      for (final file in images.take(slots)) {
        final bytes = await _readPicked(file);
        if (bytes == null || bytes.isEmpty) continue;
        picked.add(ClipboardImage.fromBytes(bytes, sourcePath: file.path));
      }
      if (!mounted) return;
      _addAttachments(picked, droppedByLimit: images.length > slots);
    }
    if (plugins == null || !acceptsFiles) return;
    for (final file in result.files) {
      if (_isImageName(file.name)) continue;
      final bytes = await _readPicked(file);
      if (!mounted) return;
      if (bytes == null) continue;
      await _insertPluginFile(plugins, file.name, bytes);
    }
  }

  Future<void> _insertPluginFile(
    PluginHookRunner plugins,
    String name,
    Uint8List bytes,
  ) async {
    final PluginFileExtraction extraction;
    try {
      extraction = await plugins.extractFile(name, bytes);
    } catch (error) {
      if (mounted) {
        GlazeToast.show(
          context,
          'plugins_file_failed'.tr(
            namedArgs: {'name': name, 'error': '$error'},
          ),
          isError: true,
        );
      }
      return;
    }
    if (!mounted) return;
    final content = extraction.content;
    if (content == null) {
      GlazeToast.show(
        context,
        extraction.handled
            ? 'plugins_file_failed'.tr(
                namedArgs: {'name': name, 'error': extraction.error ?? '?'},
              )
            : 'plugins_file_unsupported'.tr(namedArgs: {'name': name}),
        isError: extraction.handled,
      );
      return;
    }
    final current = _controller.text;
    final text = current.trim().isEmpty ? content : '$current\n\n$content';
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<bool> _pasteImagesFromClipboard() async {
    if (widget.isEditingMessage) return false;
    final images = await ClipboardImages.read(limit: maxMessageAttachments);
    if (!mounted || images.isEmpty) return false;
    _addAttachments(images, droppedByLimit: false);
    return true;
  }

  /// Images pasted into the page's field, as `data:` URLs.
  void _onAttach(Map<String, dynamic> data) {
    if (widget.isEditingMessage) return;
    final urls = data['urls'];
    if (urls is! List) return;
    final images = <ClipboardImage>[];
    for (final url in urls.take(maxMessageAttachments)) {
      if (url is! String || !url.startsWith('data:image/')) continue;
      final comma = url.indexOf(',');
      if (comma < 0) continue;
      try {
        final bytes = base64Decode(url.substring(comma + 1));
        if (bytes.isEmpty) continue;
        images.add(ClipboardImage(bytes: bytes, dataUrl: url));
      } catch (_) {}
    }
    _addAttachments(images, droppedByLimit: urls.length > images.length);
  }

  void _addAttachments(
    List<ClipboardImage> images, {
    required bool droppedByLimit,
  }) {
    if (images.isEmpty) {
      if (droppedByLimit) _warnAttachmentLimit();
      return;
    }
    final accepted = images.take(_remainingAttachmentSlots).toList();
    if (accepted.isNotEmpty) {
      setState(() {
        for (final image in accepted) {
          _attachments.add(_Attachment(_nextAttachmentId++, image));
        }
      });
    }
    if (droppedByLimit || accepted.length < images.length) {
      _warnAttachmentLimit();
    }
  }

  bool _atAttachmentLimit() {
    if (_remainingAttachmentSlots > 0) return false;
    _warnAttachmentLimit();
    return true;
  }

  void _warnAttachmentLimit() {
    if (!mounted) return;
    GlazeToast.show(
      context,
      'chat_attachment_limit'.tr(
        namedArgs: {'count': '$maxMessageAttachments'},
      ),
    );
  }

  /* ---------- Impersonation ---------- */

  void _listenImpersonation() {
    ref.listen<ImpersonationState>(impersonationStateProvider(widget.charId), (
      prev,
      next,
    ) {
      if (!mounted) return;
      if (next.active) {
        if (!_isImpersonating) setState(() => _isImpersonating = true);
        if (_controller.text != next.text) {
          _controller.value = TextEditingValue(
            text: next.text,
            selection: TextSelection.collapsed(offset: next.text.length),
          );
        }
      } else if (_isImpersonating) {
        if (_controller.text != next.text && next.text.isNotEmpty) {
          _controller.value = TextEditingValue(
            text: next.text,
            selection: TextSelection.collapsed(offset: next.text.length),
          );
        }
        setState(() => _isImpersonating = false);
      }
    });
  }

  /* ---------- Sending ---------- */

  void _onSendTap(Map<String, dynamic> data) {
    // The page's text is the truth at the moment of the tap.
    _takePageText(_controller, data['v']);
    if (_guidanceMode) _takePageText(_guidanceController, data['g']);
    if (data['enter'] == true) {
      unawaited(_handleSend());
      return;
    }
    final onTap = _sendButtonTap(_editing);
    onTap?.call();
  }

  Future<bool> _handleSend() async {
    if (widget.isEditingMessage || _isDispatchingSend) return false;
    final text = _controller.text;
    if (text.trim().isEmpty && _attachments.isEmpty) return false;
    if (widget.canSend != null && !widget.canSend!()) return false;
    final attachments = List<_Attachment>.unmodifiable(_attachments);
    final guidance = _guidanceMode && _guidanceController.text.trim().isNotEmpty
        ? _guidanceController.text.trim()
        : null;
    _isDispatchingSend = true;
    _clearComposedPayload();
    _debounce?.cancel();
    widget.onDraftChanged?.call('');
    bool accepted;
    try {
      if (attachments.isNotEmpty) {
        accepted =
            await widget.onSendWithImages?.call(text, guidance, [
              for (final attachment in attachments) attachment.image.dataUrl,
            ]) ??
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
    if (!mounted || accepted) return accepted;
    _restoreComposedPayload(
      text: text,
      guidance: guidance,
      attachments: attachments,
    );
    return false;
  }

  void _clearComposedPayload() {
    _controller.clear();
    _guidanceController.clear();
    setState(_attachments.clear);
  }

  void _restoreComposedPayload({
    required String text,
    required String? guidance,
    required List<_Attachment> attachments,
  }) {
    if (_controller.text.isNotEmpty || _attachments.isNotEmpty) return;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    if (guidance != null && _guidanceController.text.isEmpty) {
      _guidanceController.text = guidance;
    }
    setState(() => _attachments.addAll(attachments));
  }

  Future<void> _openFullscreenEditor() async {
    await FullscreenEditorScreen.show(
      context,
      title: _guidanceMode
          ? 'chat_compose_message'.tr()
          : 'chat_message_title'.tr(),
      initialValue: _controller.text,
      hintText: _guidanceMode
          ? 'chat_long_message_hint'.tr()
          : 'chat_placeholder'.tr(),
      showFormatBar: true,
      onChanged: (value) {
        if (!mounted) return;
        _controller.text = value;
        setState(() {});
      },
    );
  }

  void _toggleGuidance() {
    setState(() {
      _guidanceMode = !_guidanceMode;
      if (!_guidanceMode) _guidanceController.clear();
    });
  }

  void _closeGuidanceSilently() {
    if (!_guidanceMode) return;
    setState(() {
      _guidanceMode = false;
      _guidanceController.clear();
    });
  }

  bool get _guidanceImpersonates => _controller.text.trim().isEmpty;

  Future<void> _sendQuickReply(QuickReply reply) async {
    if (await widget.beforeGeneration?.call() == false) return;
    if (!mounted) return;
    final notifier = ref.read(chatProvider(widget.charId).notifier);
    if (reply.isContinueAction) {
      await notifier.continueMessage();
    } else if (reply.text.trim().isNotEmpty) {
      await notifier.sendMessage(reply.text);
    }
  }

  /* ---------- Pins ---------- */

  ComposerPin? _pinOf(Object? key) =>
      key is String ? ComposerPin.decode(key) : null;

  bool get _editing =>
      (widget.isDrawerOpen || isDesktopLayout(context)) &&
      ref.read(chatDrawerEditingProvider);

  void _onPinTap(Map<String, dynamic> data) {
    if (_editing) return;
    final pin = _pinOf(data['key']);
    if (pin == null) return;
    // The page has already typed an insert action's pair, inside the tap
    // that keeps the keyboard up.
    if (pin.asAction?.isInsert ?? false) return;
    _resolvePin(pin)?.onTap?.call();
  }

  void _onPinDrop(Map<String, dynamic> data) {
    if (!_editing) return;
    final pin = _pinOf(data['key']);
    if (pin == null) return;
    final pins = ref.read(composerPinsProvider).value ?? const <ComposerPin>[];
    final target = _pinOf(data['target']);
    if (target == null) {
      if (!pins.contains(pin)) _pin(pin, pins.length);
      return;
    }
    if (target == pin) return;
    final to = pins.indexOf(target);
    if (to < 0) return;
    final from = pins.indexOf(pin);
    if (from < 0) {
      _pin(pin, to);
    } else {
      ref.read(composerPinsProvider.notifier).reorder(from, to);
    }
  }

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

  void _pin(ComposerPin pin, int index) {
    Haptics.mediumImpact();
    unawaited(ref.read(composerPinsProvider.notifier).pinAt(pin, index));
  }

  _ResolvedPin? _resolvePin(ComposerPin pin) {
    switch (pin.kind) {
      case ComposerPinKind.action:
        return _resolveAction(pin.asAction);
      case ComposerPinKind.reply:
        final reply = (_get(quickRepliesProvider).value ?? const [])
            .where((r) => r.id == pin.refId)
            .firstOrNull;
        if (reply == null) return null;
        return _ResolvedPin(
          icon: reply.icon,
          onTap: () => _sendQuickReply(reply),
        );
      case ComposerPinKind.tool:
        final def = magicDrawerItemById(pin.refId);
        if (def == null) return null;
        return _ResolvedPin(
          icon: def.icon,
          onTap: () => DrawerItemLauncher(
            ref: ref,
            charId: widget.charId,
          ).open(context, def.id),
        );
    }
  }

  _ResolvedPin? _resolveAction(ComposerAction? action) {
    switch (action) {
      case null:
        return null;
      case ComposerAction.drawer:
        if (widget.onMagicDrawer == null) return null;
        return _ResolvedPin(
          icon: action.icon,
          onTap: widget.onMagicDrawer,
          color: widget.isDrawerOpen ? Colors.amber : null,
        );
      case ComposerAction.attach:
        return _ResolvedPin(icon: action.icon, onTap: _pickImages);
      case ComposerAction.fullscreen:
        return _ResolvedPin(icon: action.icon, onTap: _openFullscreenEditor);
      case ComposerAction.guidance:
        return _ResolvedPin(
          icon: action.icon,
          onTap: _toggleGuidance,
          color: _guidanceMode ? Colors.orange : null,
        );
      case ComposerAction.asterisk:
      case ComposerAction.quote:
        final token = action.insertToken;
        if (token == null ||
            (_get(hiddenComposerActionsProvider).value ?? const <String>{})
                .contains(action.id)) {
          return null;
        }
        return _ResolvedPin(
          icon: action.icon,
          glyph: action.glyph,
          insert: token,
          onTap: () => _insertSurround(token),
        );
      case ComposerAction.translate:
        if (!_get(
          pipelineSettingsProvider.select((p) => p.translation.enabled),
        )) {
          return null;
        }
        return _ResolvedPin(
          icon: _draftTranslator.canRestore ? Icons.undo : action.icon,
          onTap: () => unawaited(_translateDraft()),
          color: _draftTranslator.busy ? Colors.amber : null,
        );
    }
  }

  /* ---------- State for the page ---------- */

  bool get _hasContent =>
      _controller.text.trim().isNotEmpty ||
      (_guidanceMode && _guidanceController.text.trim().isNotEmpty) ||
      _attachments.isNotEmpty;

  bool get _isGenerating =>
      widget.isGenerating ||
      widget.isGeneratingImage ||
      widget.isPostGenRunning;

  /// What a tap on the send button does right now — null while it is dead.
  VoidCallback? _sendButtonTap(bool editing) {
    final isGenerating = _isGenerating;
    final hasContent = _hasContent;
    if (editing && !isGenerating && !hasContent) return null;
    final emptyPin = _get(composerEmptyActionProvider).value;
    final emptyAction = emptyPin == null ? null : _resolvePin(emptyPin);
    final guidanceOnly =
        hasContent &&
        _guidanceMode &&
        _controller.text.trim().isEmpty &&
        _attachments.isEmpty;

    void impersonate() {
      final guidance =
          _guidanceMode && _guidanceController.text.trim().isNotEmpty
          ? _guidanceController.text.trim()
          : null;
      _closeGuidanceSilently();
      widget.onImpersonate?.call(guidance);
    }

    return () {
      if (isGenerating) {
        widget.onStop?.call();
      } else if (widget.isEditingMessage) {
        return;
      } else if (guidanceOnly) {
        impersonate();
      } else if (hasContent) {
        _handleSend();
      } else if (emptyAction?.insert != null) {
        // Typed by the page already, inside the tap: a pair typed from here
        // would arrive after the tap and not bring the keyboard up.
        return;
      } else if (emptyAction?.onTap != null) {
        emptyAction!.onTap!();
      } else {
        impersonate();
      }
    };
  }

  /// The send button's face for one state of the composer's content.
  Map<String, Object?> _sendFace({
    required bool hasContent,
    required bool guidanceOnly,
    required bool editing,
    required _ResolvedPin? emptyAction,
  }) {
    final isGenerating = _isGenerating;
    final idle = !isGenerating && !hasContent;
    final icon = isGenerating
        ? Icons.stop_rounded
        : guidanceOnly
        ? Icons.check_rounded
        : hasContent
        ? Icons.send_rounded
        : (emptyAction?.icon ?? Icons.account_circle_rounded);
    return {
      'icon': chromeIcon(icon, glyph: idle ? emptyAction?.glyph : null),
      // Mirrors the null branch of [_sendButtonTap].
      'tap': !(editing && !isGenerating && !hasContent),
      'insert': idle && !widget.isEditingMessage ? emptyAction?.insert : null,
    };
  }

  Map<String, Object?> _sendState(bool editing) {
    final hasContent = _hasContent;
    final emptyPin = _get(composerEmptyActionProvider).value;
    final emptyAction = emptyPin == null ? null : _resolvePin(emptyPin);
    final guidanceOnly =
        hasContent &&
        _guidanceMode &&
        _controller.text.trim().isEmpty &&
        _attachments.isEmpty;
    Map<String, Object?> face(bool hasContent, bool guidanceOnly) => _sendFace(
      hasContent: hasContent,
      guidanceOnly: guidanceOnly,
      editing: editing,
      emptyAction: emptyAction,
    );
    return {
      ...face(hasContent, guidanceOnly),
      // Every face the button can wear, so the page switches it on the
      // keystroke that empties or fills the field, as ChatInputBar did,
      // instead of a round trip through here later.
      'faces': {
        'empty': face(false, false),
        'guide': face(true, true),
        'content': face(true, false),
      },
      'slot': editing,
      'badge': editing && emptyPin != null,
      'emptyPin': emptyPin?.encode(),
      'hint': 'composer_empty_action_hint'.tr(),
      'badgeTip': 'composer_empty_action_reset'.tr(),
    };
  }

  List<Map<String, Object?>> _pinsState(bool editing) {
    final pins = _get(composerPinsProvider).value ?? kDefaultComposerPins;
    return [
      for (final pin in pins)
        if (_resolvePin(pin) case final resolved?)
          {
            'key': pin.encode(),
            'icon': chromeIcon(resolved.icon, glyph: resolved.glyph),
            'color': resolved.color == null
                ? null
                : chromeColor(resolved.color!),
            'tap': resolved.onTap != null,
            'permanent': pin.isPermanent,
            'insert': resolved.insert,
            'badgeTip': 'composer_pin_remove'.tr(),
          },
    ];
  }

  Map<String, Object?> _state(BuildContext context) {
    final editing =
        (widget.isDrawerOpen || isDesktopLayout(context)) &&
        _get(chatDrawerEditingProvider);
    final mode = widget.showSearchControls
        ? 'search'
        : widget.isSelectionMode
        ? 'selection'
        : 'compose';
    return {
      'show': true,
      'mode': mode,
      'placeholder': _guidanceMode
          ? 'chat_guidance_message_hint'.tr()
          : 'chat_placeholder'.tr(),
      'readOnly':
          widget.isEditingMessage || _isImpersonating || _draftTranslator.busy,
      'locked': widget.isEditingMessage,
      'virtualSend': widget.virtualKeyboardSend,
      'enterSend': widget.enterToSend,
      'guidance': _guidanceMode
          ? {
              'caption': _guidanceImpersonates
                  ? 'guided_impersonation'.tr()
                  : 'guided_generation'.tr(),
              'placeholder': _guidanceImpersonates
                  ? 'impersonate_guidance_placeholder'.tr()
                  : 'guidance_placeholder'.tr(),
              // Both versions, picked by the page from its own field.
              'empty': {
                'caption': 'guided_impersonation'.tr(),
                'placeholder': 'impersonate_guidance_placeholder'.tr(),
              },
              'filled': {
                'caption': 'guided_generation'.tr(),
                'placeholder': 'guidance_placeholder'.tr(),
              },
            }
          : null,
      'pins': _pinsState(editing),
      'editing': editing,
      'send': _sendState(editing),
      'search': {
        'label': widget.searchMatchCount > 0
            ? '${widget.searchCurrentIndex + 1} of ${widget.searchMatchCount} matches'
            : 'search_no_results'.tr(),
        'prev': widget.onSearchPrev != null,
        'next': widget.onSearchNext != null,
      },
      'selection': {
        'label': '${widget.selectedCount} ${'selected_count'.tr()}',
        'any': widget.selectedCount > 0,
        'allHidden': widget.allSelectedHidden,
        'canDelete': widget.canDeleteSelected,
      },
      // The SafeArea the search and selection bars sat in.
      'extraBottom': MediaQuery.paddingOf(context).bottom,
    };
  }

  /* ---------- Build ---------- */

  int _sentAttachmentsVersion = -1;
  int _attachmentsVersion = 0;
  List<int> _attachmentIds = const [];

  void _publish(BuildContext context) {
    _channel.set('composer', _state(context));
    final ids = [for (final a in _attachments) a.id];
    if (!listEquals(ids, _attachmentIds)) {
      _attachmentIds = ids;
      _attachmentsVersion++;
    }
    // Sent only when the list changed: the images are whole data URLs, and
    // comparing them on every keystroke would cost more than sending them.
    if (_attachmentsVersion != _sentAttachmentsVersion) {
      _sentAttachmentsVersion = _attachmentsVersion;
      _channel.set('attachments', [
        for (final a in _attachments) {'id': a.id, 'src': a.image.dataUrl},
      ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    _building = true;
    try {
      _listenImpersonation();
      _publish(context);
    } finally {
      _building = false;
    }
    final editing =
        isDesktopLayout(context) && ref.watch(chatDrawerEditingProvider);
    final pins = ref.watch(composerPinsProvider).value ?? const <ComposerPin>[];
    return ValueListenableBuilder<ChromeLayoutReport>(
      valueListenable: _channel.layout,
      builder: (context, layout, _) {
        return Stack(
          fit: StackFit.expand,
          children: [
            // Guide tours point at the page's controls through these.
            Positioned.fill(
              child: IgnorePointer(
                child: Stack(
                  children: [
                    chromeAnchor(GuideIds.chatComposer, layout.composer),
                    chromeAnchor(GuideIds.chatSend, layout.send),
                    for (final pin in layout.pins)
                      chromeAnchor(GuideIds.chatPin(pin.key), pin.rect),
                  ],
                ),
              ),
            ),
            // On desktop the drawer is the sidebar's, in Flutter: a card
            // dragged out of it lands on the row through these.
            if (editing) ..._desktopDropTargets(layout, pins),
          ],
        );
      },
    );
  }

  List<Widget> _desktopDropTargets(
    ChromeLayoutReport layout,
    List<ComposerPin> pins,
  ) {
    final row = layout.row;
    final send = layout.send;
    return [
      if (row != null)
        Positioned.fromRect(
          rect: row,
          child: DragTarget<ComposerPin>(
            onWillAcceptWithDetails: (d) => !pins.contains(d.data),
            onAcceptWithDetails: (d) => _pin(d.data, pins.length),
            builder: (_, _, _) => const SizedBox.expand(),
          ),
        ),
      for (final entry in layout.pins)
        if (ComposerPin.decode(entry.key) case final pin?)
          Positioned.fromRect(
            rect: entry.rect,
            child: DragTarget<ComposerPin>(
              onWillAcceptWithDetails: (d) => d.data != pin,
              onAcceptWithDetails: (d) =>
                  _onPinDrop({'key': d.data.encode(), 'target': pin.encode()}),
              builder: (_, _, _) => const SizedBox.expand(),
            ),
          ),
      if (send != null)
        Positioned.fromRect(
          rect: send,
          child: DragTarget<ComposerPin>(
            onWillAcceptWithDetails: (d) =>
                d.data != ref.read(composerEmptyActionProvider).value &&
                ComposerEmptyActionNotifier.isAssignable(d.data),
            onAcceptWithDetails: (d) => _assignEmptyAction(d.data),
            builder: (_, candidate, _) {
              // The send button grows under an acceptable card, in the page.
              _channel.set('sendHover', candidate.isNotEmpty);
              return const SizedBox.expand();
            },
          ),
        ),
    ];
  }
}

/// An invisible stand-in at [rect] for a guide tour to point at a control
/// drawn in the page.
Widget chromeAnchor(String id, Rect? rect) {
  if (rect == null) return const SizedBox.shrink();
  return Positioned.fromRect(
    rect: rect,
    child: GuideAnchor(id: id, child: const SizedBox.expand()),
  );
}

class _ResolvedPin {
  final IconData icon;
  final String? glyph;
  final VoidCallback? onTap;
  final Color? color;

  /// The pair an insert action wraps the selection in; the page types it.
  final String? insert;

  const _ResolvedPin({
    required this.icon,
    this.glyph,
    this.onTap,
    this.color,
    this.insert,
  });
}
