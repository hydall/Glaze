import 'dart:ui';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class ImageViewer extends StatefulWidget {
  final ImageProvider imageProvider;
  final String? description;

  const ImageViewer({super.key, required this.imageProvider, this.description});

  static void show(BuildContext context, {required ImageProvider imageProvider, String? description}) {
    showGeneralDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.9),
      barrierDismissible: true,
      barrierLabel: 'Close',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return ImageViewer(imageProvider: imageProvider, description: description);
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: animation,
          child: child,
        );
      },
    );
  }

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> with SingleTickerProviderStateMixin {
  bool _promptVisible = true;
  final TransformationController _transformationController = TransformationController();
  TapDownDetails? _doubleTapDetails;
  late AnimationController _animationController;
  Animation<Matrix4>? _animation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addListener(() {
        if (_animation != null) {
          _transformationController.value = _animation!.value;
        }
      });
  }

  @override
  void dispose() {
    _transformationController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    _doubleTapDetails = details;
  }

  void _handleDoubleTap() {
    if (_animationController.isAnimating) return;

    final position = _doubleTapDetails!.localPosition;
    final Matrix4 endMatrix;
    
    if (_transformationController.value != Matrix4.identity()) {
      endMatrix = Matrix4.identity();
    } else {
      const double scale = 2.5;
      final dx = -position.dx * (scale - 1);
      final dy = -position.dy * (scale - 1);
      endMatrix = Matrix4.identity()
        ..translateByDouble(dx, dy, 0.0, 1.0)
        ..scaleByDouble(scale, scale, scale, 1.0);
    }

    _animation = Matrix4Tween(
      begin: _transformationController.value,
      end: endMatrix,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    ));

    _animationController.forward(from: 0);
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final double scaleChange = event.scrollDelta.dy < 0 ? 1.15 : (1 / 1.15);
      final Matrix4 matrix = _transformationController.value;
      final double currentScale = matrix.getMaxScaleOnAxis();
      final double newScale = (currentScale * scaleChange).clamp(1.0, 5.0);
      
      if (currentScale == newScale) return;
      
      final double scaleRatio = newScale / currentScale;
      final Offset localPosition = event.localPosition;
      
      final double dx = matrix.getTranslation().x;
      final double dy = matrix.getTranslation().y;
      
      final double newDx = localPosition.dx - (localPosition.dx - dx) * scaleRatio;
      final double newDy = localPosition.dy - (localPosition.dy - dy) * scaleRatio;
      
      _transformationController.value = Matrix4.identity()
        ..translateByDouble(newDx, newDy, 0.0, 1.0)
        ..scaleByDouble(newScale, newScale, newScale, 1.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Image with zoom/pan
          Listener(
            onPointerSignal: _handlePointerSignal,
            child: GestureDetector(
              onTap: () {
                if (widget.description != null && widget.description!.isNotEmpty) {
                  setState(() => _promptVisible = !_promptVisible);
                }
              },
              onDoubleTapDown: _handleDoubleTapDown,
              onDoubleTap: _handleDoubleTap,
              child: InteractiveViewer(
                transformationController: _transformationController,
                minScale: 1.0,
                maxScale: 5.0,
                trackpadScrollCausesScale: true,
                child: Image(
                  image: widget.imageProvider,
                  fit: BoxFit.contain,
                  // Without these the viewer just sits on the dimmed barrier
                  // with nothing in it, which is indistinguishable from a
                  // broken build. Show progress while it decodes and a real
                  // message when the image can't be loaded at all.
                  loadingBuilder: (context, child, progress) {
                    if (progress == null) return child;
                    return const Center(
                      child: SizedBox(
                        width: 32,
                        height: 32,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white70,
                        ),
                      ),
                    );
                  },
                  errorBuilder: (context, error, stackTrace) =>
                      const _ImageViewerError(),
                ),
              ),
            ),
          ),
          
          // Close button
          Positioned(
            top: MediaQuery.of(context).padding.top + 20,
            right: 20,
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close,
                  color: Colors.white,
                  size: 24,
                ),
              ),
            ),
          ),
          
          // Description
          if (widget.description != null && widget.description!.isNotEmpty)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              bottom: _promptVisible ? MediaQuery.of(context).padding.bottom + 20 : -200,
              left: 16,
              right: 16,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: _promptVisible ? 1.0 : 0.0,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                      ),
                      child: SingleChildScrollView(
                        child: Text(
                          widget.description!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ImageViewerError extends StatelessWidget {
  const _ImageViewerError();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.broken_image_outlined,
              color: Colors.white54, size: 48),
          const SizedBox(height: 12),
          Text(
            'image_viewer_load_failed'.tr(),
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }
}
