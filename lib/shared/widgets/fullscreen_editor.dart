import 'package:flutter/material.dart';

import '../../core/utils/text_insert.dart';
import '../theme/app_colors.dart';
import 'glass_surface.dart';
import 'glaze_scaffold.dart';
import 'menu_group.dart';

class FullscreenEditorScreen extends StatefulWidget {
  final String title;
  final String initialValue;
  final String? hintText;
  final bool autofocus;
  final ValueChanged<String>? onChanged;

  /// Draws the pair-insert bar (`**`, `""`) above the keyboard. Off by default:
  /// the editor is shared with callers that edit non-prose values, where a
  /// markdown shortcut is noise.
  final bool showFormatBar;

  const FullscreenEditorScreen({
    super.key,
    required this.title,
    required this.initialValue,
    this.hintText,
    this.autofocus = true,
    this.onChanged,
    this.showFormatBar = false,
  });

  static Future<void> show(
    BuildContext context, {
    required String title,
    required String initialValue,
    String? hintText,
    bool autofocus = true,
    ValueChanged<String>? onChanged,
    bool showFormatBar = false,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => FullscreenEditorScreen(
          title: title,
          initialValue: initialValue,
          hintText: hintText,
          autofocus: autofocus,
          onChanged: onChanged,
          showFormatBar: showFormatBar,
        ),
      ),
    );
  }

  @override
  State<FullscreenEditorScreen> createState() => _FullscreenEditorScreenState();
}

class _FullscreenEditorScreenState extends State<FullscreenEditorScreen> {
  late final TextEditingController _controller;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _insert(String token) {
    insertSurroundingText(_controller, token);
    // A programmatic edit does not fire the field's own onChanged, so report it
    // here or the caller's mirror of the text goes stale.
    widget.onChanged?.call(_controller.text);
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return GlazeScaffold(
      title: widget.title,
      showBack: true,
      onBack: () => Navigator.of(context).pop(),
      showBackground: true,
      resizeToAvoidBottomInset: true,
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return MenuGroup(
                    items: [
                      _FullscreenEditorField(
                        controller: _controller,
                        focusNode: _focusNode,
                        hintText: widget.hintText,
                        autofocus: widget.autofocus,
                        height: constraints.maxHeight - 30,
                        onChanged: widget.onChanged,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          if (widget.showFormatBar) _EditorFormatBar(onInsert: _insert),
        ],
      ),
    );
  }
}

/// The two pair-insert buttons, pinned to the bottom of the editor. The body
/// resizes above the keyboard, so this lands right on top of it.
class _EditorFormatBar extends StatelessWidget {
  final ValueChanged<String> onInsert;

  const _EditorFormatBar({required this.onInsert});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Row(
          children: [
            _FormatButton(glyph: '**', onTap: () => onInsert('*')),
            const SizedBox(width: 8),
            _FormatButton(glyph: '""', onTap: () => onInsert('"')),
          ],
        ),
      ),
    );
  }
}

class _FormatButton extends StatelessWidget {
  final String glyph;
  final VoidCallback onTap;

  const _FormatButton({required this.glyph, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: GlassSurface(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        tint: context.cs.surface,
        border: Border.all(color: context.cs.outlineVariant),
        child: Center(
          child: Text(
            glyph,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              letterSpacing: -1,
              color: context.cs.primary,
            ),
          ),
        ),
      ),
    );
  }
}

class _FullscreenEditorField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String? hintText;
  final bool autofocus;
  final double height;
  final ValueChanged<String>? onChanged;

  const _FullscreenEditorField({
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.autofocus,
    required this.height,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height > 120 ? height : 120,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          onChanged: onChanged,
          autofocus: autofocus,
          maxLines: null,
          expands: true,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          style: TextStyle(
            color: context.cs.onSurface,
            fontSize: 16,
            height: 1.5,
          ),
          decoration: InputDecoration(
            hintText: hintText,
            hintStyle: TextStyle(
              color: context.cs.onSurfaceVariant.withValues(alpha: 0.45),
            ),
            filled: false,
            fillColor: Colors.transparent,
            hoverColor: Colors.transparent,
            focusColor: Colors.transparent,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ),
    );
  }
}
