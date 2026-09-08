import 'dart:ui';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../../shared/theme/app_colors.dart';

class InputBar extends StatefulWidget {
  final ValueChanged<String> onSend;
  final bool isGenerating;
  final VoidCallback? onStop;
  final VoidCallback? onMagicDrawer;
  final bool batterySaver;

  const InputBar({
    super.key,
    required this.onSend,
    required this.isGenerating,
    this.onStop,
    this.onMagicDrawer,
    this.batterySaver = false,
  });

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleSend() {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    widget.onSend(text);
    _controller.clear();
  }

@override
  Widget build(BuildContext context) {
    final inputContainer = Container(
      constraints: const BoxConstraints(minHeight: 56),
      decoration: BoxDecoration(
        color: context.cs.surface.withValues(alpha: widget.batterySaver ? 1.0 : 0.8),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.05),
        ),
        borderRadius: BorderRadius.circular(28),
      ),
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        maxLines: 5,
        minLines: 1,
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.send,
        onSubmitted: (_) => _handleSend(),
        style: const TextStyle(fontSize: 16),
        decoration: InputDecoration(
          hintText: 'chat_placeholder'.tr(),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 16,
          ),
          filled: false,
        ),
      ),
    );

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: widget.batterySaver
                  ? inputContainer
                  : BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                      child: inputContainer,
                    ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _CircleBtn(icon: Icons.auto_awesome, onTap: widget.onMagicDrawer, batterySaver: widget.batterySaver),
                    const SizedBox(width: 8),
                    _CircleBtn(icon: Icons.image_outlined, batterySaver: widget.batterySaver),
                    const SizedBox(width: 8),
                    _CircleBtn(icon: Icons.fullscreen_rounded, batterySaver: widget.batterySaver),
                  ],
                ),
                GestureDetector(
                  onTap: widget.isGenerating ? widget.onStop : _handleSend,
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: context.cs.primary,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.isGenerating ? 'btn_stop'.tr() : 'btn_send'.tr(),
                          style: const TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          widget.isGenerating
                              ? Icons.stop_rounded
                              : Icons.send_rounded,
                          color: Colors.black,
                          size: 18,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CircleBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool batterySaver;
  const _CircleBtn({required this.icon, this.onTap, this.batterySaver = false});
  @override
  Widget build(BuildContext context) {
    final container = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: context.cs.surface.withValues(alpha: batterySaver ? 1.0 : 0.8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
        shape: BoxShape.circle,
      ),
      child: Center(child: Icon(icon, color: context.cs.primary, size: 20)),
    );
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: batterySaver
            ? container
            : BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: container,
              ),
      ),
    );
  }
}
