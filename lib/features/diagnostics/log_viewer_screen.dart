import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../core/diagnostics/app_log.dart';
import '../../core/diagnostics/diagnostics_store.dart';
import '../../shared/shell/desktop/desktop_floating_provider.dart';
import '../../shared/shell/nav_height_provider.dart';
import '../../shared/shell/shell_header_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_scaffold.dart';
import '../../shared/widgets/glaze_spinner.dart';
import 'diagnostics_share.dart';

/// Read-only view of one log or crash report, newest lines last.
///
/// Shows the end of the file only: that is where a problem is, and a session
/// log can run to megabytes. The full file is what [DiagnosticsShare] sends.
class LogViewerScreen extends ConsumerStatefulWidget {
  final String path;

  const LogViewerScreen({super.key, required this.path});

  /// A route of its own under Logs (a window view on desktop), so it gets the
  /// shell header — the file name and the copy / share actions — rather than
  /// sitting under the Logs screen's.
  static void open(BuildContext context, DiagnosticsFile file) => goOrFloat(
    context,
    Uri(path: 'log-view', queryParameters: {'path': file.path}).toString(),
    route: Uri(
      path: '/menu/logs/view',
      queryParameters: {'path': file.path},
    ).toString(),
    push: true,
  );

  @override
  ConsumerState<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends ConsumerState<LogViewerScreen> {
  static const _maxLines = 5000;

  List<(String, String?)>? _lines;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    AppLog.flush();
    final text = await DiagnosticsStore.tail(
      widget.path,
      maxLines: _maxLines,
      maxBytes: 1024 * 1024,
    );
    if (!mounted) return;
    // Continuation lines (a stack trace under an error) carry no level of
    // their own; they take the colour of the line they belong to.
    String? level;
    final lines = [
      for (final line in text.split('\n'))
        (line, level = line.startsWith('    ') ? level : _levelOf(line)),
    ];
    setState(() => _lines = lines);
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    final topPad = DetachedShellHost.of(context)
        ? 0.0
        : MediaQuery.of(context).padding.top + 74.0;
    return GlazeScaffold(
      title: p.basename(widget.path),
      useShellHeader: true,
      headerBranchIndex: 3,
      extendBodyBehindHeader: true,
      showBackground: false,
      onBack: () => context.go('/menu/logs'),
      actions: [
        IconButton(
          tooltip: 'logs_copy'.tr(),
          icon: const Icon(Icons.copy_rounded, size: 20),
          color: context.cs.primary,
          onPressed: () => DiagnosticsShare.copyFile(context, widget.path),
        ),
        IconButton(
          tooltip: 'logs_share'.tr(),
          icon: const Icon(Icons.ios_share_rounded, size: 20),
          color: context.cs.primary,
          onPressed: () => DiagnosticsShare.shareFile(context, widget.path),
        ),
      ],
      body: lines == null
          ? const Center(child: GlazeSpinner(size: 32))
          : SelectionArea(
              // Reversed, so it opens on the newest lines without measuring
              // the whole list to jump there.
              child: ListView.builder(
                reverse: true,
                padding: EdgeInsets.fromLTRB(
                  16,
                  topPad + 8,
                  16,
                  // A desktop window has no nav bar to clear.
                  DetachedShellHost.of(context)
                      ? 16
                      : ref.watch(navHeightProvider) + 20,
                ),
                itemCount: lines.length,
                itemBuilder: (context, i) {
                  final (text, level) = lines[lines.length - 1 - i];
                  return _LogLine(text: text, level: level);
                },
              ),
            ),
    );
  }
}

/// `HH:mm:ss.mmm E message` — the level letter sits at index 13.
String? _levelOf(String line) {
  if (line.length < 15 || line[12] != ' ' || line[14] != ' ') return null;
  return line[13];
}

class _LogLine extends StatelessWidget {
  final String text;
  final String? level;

  const _LogLine({required this.text, required this.level});

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final color = switch (level) {
      'E' => cs.error,
      'W' => Colors.orange,
      _ => null,
    };
    return Text(
      text,
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: 11.5,
        height: 1.35,
        color: color ?? cs.onSurface.withValues(alpha: 0.85),
      ),
    );
  }
}
