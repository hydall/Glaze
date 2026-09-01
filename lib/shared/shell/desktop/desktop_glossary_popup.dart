import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../features/glossary/glossary_sheet.dart';

final glossaryPopupVisibleProvider = StateProvider<bool>((ref) => false);

/// Term the popup should open on, set by a [HelpTip] tap. Null opens the
/// glossary at its category list.
final glossaryPopupTermProvider = StateProvider<String?>((ref) => null);

/// Opens the floating glossary window, optionally jumped straight to [term].
///
/// The window is mounted above the router (see `app.dart`), so it stays on top
/// of whatever opened it — including the modal sheets that most help tips live
/// in, which used to cover it when the popup rendered inside the shell.
void openGlossaryPopup(WidgetRef ref, {String? term}) {
  ref.read(glossaryPopupTermProvider.notifier).state = term;
  ref.read(glossaryPopupVisibleProvider.notifier).state = true;
}

class DesktopGlossaryPopup extends ConsumerStatefulWidget {
  const DesktopGlossaryPopup({super.key});

  @override
  ConsumerState<DesktopGlossaryPopup> createState() =>
      _DesktopGlossaryPopupState();
}

class _DesktopGlossaryPopupState extends ConsumerState<DesktopGlossaryPopup> {
  Offset _position = const Offset(20, 20);
  final Size _size = const Size(380, 500);

  void _startDrag(DragUpdateDetails details) {
    setState(() {
      _position += details.delta;
      _position = Offset(
        _position.dx.clamp(0, MediaQuery.of(context).size.width - _size.width),
        _position.dy.clamp(
          0,
          MediaQuery.of(context).size.height - _size.height,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final visible = ref.watch(glossaryPopupVisibleProvider);
    if (!visible) return const SizedBox.shrink();
    final term = ref.watch(glossaryPopupTermProvider);

    return Positioned(
      left: _position.dx,
      top: _position.dy,
      child: Container(
        width: _size.width,
        height: _size.height,
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 20,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Column(
          children: [
            // Draggable header
            GestureDetector(
              onPanUpdate: _startDrag,
              child: Container(
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(12),
                  ),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Glossary',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        ref.read(glossaryPopupVisibleProvider.notifier).state =
                            false;
                      },
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
            // Content
            Expanded(
              child: GlossarySheet(
                // Keyed by term so re-opening on a different term rebuilds the
                // sheet at that article instead of keeping the old one.
                key: ValueKey(term),
                initialTerm: term,
                startExpanded: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
