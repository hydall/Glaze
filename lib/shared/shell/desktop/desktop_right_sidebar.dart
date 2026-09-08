import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../features/chat/widgets/magic_drawer.dart';
import '../../../features/tools/tools_screen.dart';
import '../../../shared/theme/app_colors.dart';
import 'sidebar_drag_handle.dart';
import 'sidebar_resizer.dart';
import 'sidebar_sheet_provider.dart';

class DesktopRightSidebar extends ConsumerStatefulWidget {
  const DesktopRightSidebar({super.key});

  @override
  ConsumerState<DesktopRightSidebar> createState() =>
      _DesktopRightSidebarState();
}

class _DesktopRightSidebarState extends ConsumerState<DesktopRightSidebar> {
  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(rightSidebarControllerProvider);
    final sheet = ref.watch<Widget?>(rightSidebarSheetProvider);
    final location = GoRouterState.of(context).uri.toString();
    final isChat = location.startsWith('/chat/');
    final collapsed = controller.collapsed;

    // Auto-expand / restore for sheets
    if (sheet != null && collapsed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.autoExpand();
      });
    }
    if (sheet == null && controller.wasAutoExpanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.restoreCollapse();
      });
    }

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Container(
        width: controller.width,
        color: Colors.black.withValues(alpha: 0.2),
        child: Stack(
          children: [
            if (sheet != null)
              _buildSheetHost(sheet)
            else if (controller.collapsed)
              _buildCollapsed(isChat)
            else
              _buildExpanded(isChat, location),
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              child: SidebarDragHandle.right(
                rightController: controller,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSheetHost(Widget sheet) {
    return Material(color: Colors.transparent, child: sheet);
  }

  Widget _buildExpanded(bool isChat, String location) {
    return RepaintBoundary(
      child: Material(
        color: Colors.transparent,
        child: isChat ? _buildChatPanel(location) : const ToolsScreen(),
      ),
    );
  }

  Widget _buildChatPanel(String location) {
    final charId = _extractCharId(location);
    if (charId == null) return const SizedBox.shrink();
    return MagicDrawerPanel(charId: charId);
  }

  Widget _buildCollapsed(bool isChat) {
    if (isChat) {
      return Center(
        child: Icon(
          Icons.auto_awesome,
          size: 28,
          color: context.cs.onSurface.withValues(alpha: 0.5),
        ),
      );
    }
    return _buildToolStrip();
  }

  /// Port of Vue `.tools-strip` (DesktopRightSidebar.vue lines 418-517).
  /// 5 icons: Personas, Presets, API, Lorebook, Regex.
  Widget _buildToolStrip() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildStripIcon(
            _ToolStripSvg.personas,
            'Personas',
            active: _isActiveRoute('/tools/personas'),
            onTap: () => context.push('/tools/personas'),
          ),
          _buildStripIcon(
            _ToolStripSvg.presets,
            'Presets',
            active: _isActiveRoute('/tools/presets'),
            onTap: () => context.push('/tools/presets'),
          ),
          _buildStripIcon(
            _ToolStripSvg.api,
            'API',
            active: _isActiveRoute('/tools/api'),
            onTap: () => context.push('/tools/api'),
          ),
          _buildStripIcon(
            _ToolStripSvg.lorebook,
            'Lorebooks',
            active: _isActiveRoute('/tools/lorebooks'),
            onTap: () => context.push('/tools/lorebooks'),
          ),
          _buildStripIcon(
            _ToolStripSvg.regex,
            'Regex',
            active: _isActiveRoute('/tools/regex'),
            onTap: () => context.push('/tools/regex'),
          ),
        ],
      ),
    );
  }

  bool _isActiveRoute(String path) {
    final location = GoRouterState.of(context).uri.toString();
    return location.contains(path);
  }

  Widget _buildStripIcon(
    String svgPath,
    String tooltip, {
    bool active = false,
    VoidCallback? onTap,
  }) {
    return Tooltip(
      message: tooltip,
      preferBelow: false,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 64,
          height: 48,
          decoration: BoxDecoration(
            color: active
                ? const Color(0x14528BCC) // rgba(82,139,204,0.08)
                : Colors.transparent,
            border: Border(
              bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
            ),
          ),
          child: Center(
            child: Container(
              width: 28,
              height: 28,
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: active
                    ? const Color(0x26528BCC) // rgba(82,139,204,0.15)
                    : Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: _svgIcon(svgPath),
            ),
          ),
        ),
      ),
    );
  }

  Widget _svgIcon(String path) {
    return CustomPaint(
      size: const Size(18, 18),
      painter: _SvgPathPainter(path),
    );
  }

  String? _extractCharId(String location) {
    // Parse the URI so query parameters (e.g. ?session=1) are NOT included
    // in the charId. The previous regex `/chat/([^/]+)` captured the query
    // string too, producing a polluted charId like "mq9ua9qr?session=1" that
    // created phantom chatProvider instances and phantom DB sessions.
    final uri = Uri.parse(location);
    final segments = uri.pathSegments;
    if (segments.length >= 2 && segments[0] == 'chat') {
      return segments[1];
    }
    return null;
  }
}

/// Minimal SVG path painter for tool strip icons.
class _SvgPathPainter extends CustomPainter {
  final String path;
  _SvgPathPainter(this.path);

  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = Colors.white.withValues(alpha: 0.8)
          ..style = PaintingStyle.fill;
    // Scale to fit
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    _drawSvgPath(canvas, paint, path);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SvgPathPainter oldDelegate) =>
      oldDelegate.path != path;
}

/// Simple SVG path parser — handles M, C, L, Z commands.
void _drawSvgPath(Canvas canvas, Paint paint, String d) {
  final path = Path();
  final parts = d.split(RegExp(r'[,\s]+'));
  int i = 0;
  while (i < parts.length) {
    final cmd = parts[i];
    if (cmd == 'M') {
      path.moveTo(double.parse(parts[i + 1]), double.parse(parts[i + 2]));
      i += 3;
    } else if (cmd == 'C') {
      path.cubicTo(
        double.parse(parts[i + 1]),
        double.parse(parts[i + 2]),
        double.parse(parts[i + 3]),
        double.parse(parts[i + 4]),
        double.parse(parts[i + 5]),
        double.parse(parts[i + 6]),
      );
      i += 7;
    } else if (cmd == 'L') {
      path.lineTo(double.parse(parts[i + 1]), double.parse(parts[i + 2]));
      i += 3;
    } else if (cmd == 'Z' || cmd == 'z') {
      path.close();
      i += 1;
    } else {
      i += 1; // Skip unknown
    }
  }
  canvas.drawPath(path, paint);
}

/// SVG paths matching ToolsView.vue icons.
abstract final class _ToolStripSvg {
  static const personas =
      'M19 3H5c-1.11 0-2 .9-2 2v14c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-7 3c1.66 0 3 1.34 3 3s-1.34 3-3 3-3-1.34-3-3 1.34-3 3-3zm6 12H6v-1c0-2 4-3.1 6-3.1s6 1.1 6 3.1v1z';
  static const presets =
      'M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6h-6V2zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z';
  static const api =
      'M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96z';
  static const lorebook =
      'M4 6H2v14c0 1.1.9 2 2 2h14v-2H4V6zm16-4H8c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-1 9H9V9h10v2zm-4 4H9v-2h6v2zm4-8H9V5h10v2z';
  static const regex =
      'M9.4 16.6L4.8 12l4.6-4.6L8 6l-6 6 6 6 1.4-1.4zm5.2 0l4.6-4.6-4.6-4.6L16 6l6 6-6 6-1.4-1.4z';
}
