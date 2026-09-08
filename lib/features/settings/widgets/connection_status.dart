import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/theme/app_colors.dart';

enum ApiConnectionStatus { idle, connecting, connected, failed }

class ConnectionStatus extends StatefulWidget {
  final ApiConnectionStatus status;
  final String errorMessage;
  final VoidCallback onRetry;
  final Widget child;

  const ConnectionStatus({
    super.key,
    required this.status,
    this.errorMessage = '',
    required this.onRetry,
    required this.child,
  });

  @override
  State<ConnectionStatus> createState() => _ConnectionStatusState();
}

class _ConnectionStatusState extends State<ConnectionStatus> {
  String get _statusText {
    switch (widget.status) {
      case ApiConnectionStatus.idle:
        return 'Idle';
      case ApiConnectionStatus.connecting:
        return 'Connecting...';
      case ApiConnectionStatus.connected:
        return 'Connected';
      case ApiConnectionStatus.failed:
        return 'Failed';
    }
  }

  Color get _statusColor {
    switch (widget.status) {
      case ApiConnectionStatus.idle:
        return context.cs.onSurfaceVariant.withValues(alpha: 0.4);
      case ApiConnectionStatus.connecting:
        return Colors.orange;
      case ApiConnectionStatus.connected:
        return const Color(0xFF4CAF50);
      case ApiConnectionStatus.failed:
        return const Color(0xFFFF4444);
    }
  }

  void _copyError() {
    if (widget.errorMessage.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: widget.errorMessage));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            widget.child,
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              decoration: BoxDecoration(
                color: _statusColor.withValues(alpha: 0.12),
                border: Border.all(color: _statusColor.withValues(alpha: 0.5)),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(999),
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: widget.onRetry,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _statusColor,
                          ),
                        ),
                        const SizedBox(width: 6),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: Text(
                            _statusText,
                            key: ValueKey(widget.status),
                            style: TextStyle(
                              fontSize: 12,
                              color: context.cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 400),
          curve: Curves.fastOutSlowIn,
          child:
              widget.status == ApiConnectionStatus.failed &&
                  widget.errorMessage.isNotEmpty
              ? Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: BackdropFilter(
                      filter: _backFilter(),
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF3B30).withValues(alpha: 0.1),
                          border: Border.all(color: const Color(0xFFFF3B30)),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              color: const Color(
                                0xFFFF3B30,
                              ).withValues(alpha: 0.2),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    'ERROR',
                                    style: TextStyle(
                                      color: Color(0xFFFF3B30),
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1,
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: _copyError,
                                    child: const Icon(
                                      Icons.copy,
                                      size: 14,
                                      color: Color(0xFFFF3B30),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                widget.errorMessage,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  color: Color(0xFFFFB3B3),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  // To prevent import dart:ui
  ImageFilter _backFilter() {
    return const ColorFilter.mode(Colors.black12, BlendMode.srcOver);
  }
}
