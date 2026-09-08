import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/settings/api_list_provider.dart';

import '../../../shared/widgets/generic_editor.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../../core/state/summary_providers.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_error_dialog.dart';
import '../chat_provider.dart';

class SummarySheet extends ConsumerStatefulWidget {
  final String charId;
  const SummarySheet({super.key, required this.charId});

  @override
  ConsumerState<SummarySheet> createState() => _SummarySheetState();
}

class _SummarySheetState extends ConsumerState<SummarySheet> {
  late Map<String, dynamic> _localItem;
  bool _enabled = true;
  bool _isGenerating = false;
  // Captured while the element is active so _performSave can still read
  // providers when invoked from GenericEditor.dispose() (e.g. the sheet is
  // swipe-dismissed with a pending debounced edit) — by then ref.read throws
  // "Looking up a deactivated widget's ancestor is unsafe". Mirrors
  // AuthorsNoteSheet.
  late final ProviderContainer _container;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container = ProviderScope.containerOf(context);
  }

  @override
  void initState() {
    super.initState();
    _localItem = {'content': ''};
    _load();
  }

  Future<void> _load() async {
    final session = ref.read(chatProvider(widget.charId)).value?.session;
    if (session == null) return;
    final service = ref.read(summaryServiceProvider);
    final content = await service.getSummaryContent(session.id);
    final enabled = await service.isSummaryEnabled(session.id);
    if (!mounted) return;
    setState(() {
      _localItem = {'content': content ?? ''};
      _enabled = enabled;
    });
  }

  Future<void> _performSave(Map<String, dynamic> item) async {
    // Use the captured container, not ref — this can be invoked from
    // GenericEditor.dispose() when the element is already deactivated.
    final session =
        _container.read(chatProvider(widget.charId)).value?.session;
    if (session == null) return;
    final content = (item['content'] as String?)?.trim() ?? '';
    // Write to the same store the prompt reads, so manual summaries inject.
    await _container.read(summaryServiceProvider).setSummary(
          sessionId: session.id,
          content: content,
          messageCount: session.messages.length,
        );
    _container.read(summaryRevisionProvider.notifier).state++;
  }

  void _setEnabled(bool value) {
    setState(() => _enabled = value);
    syncSummaryEnabled(ref, charId: widget.charId, enabled: value);
  }

  List<GenericEditorSection> get _config => [
        GenericEditorSection(
          fields: [
            GenericEditorField(
              key: 'content',
              label: 'Summary Content',
              type: 'textarea',
              placeholder: 'Enter conversation summary...',
              rows: 8,
            ),
            const GenericEditorField(
              key: '__settingsHint',
              label: '',
              type: 'info',
              text: 'Role, depth, insertion mode and prefix are set per preset, '
                  'in the preset editor.',
            ),
          ],
        ),
      ];

  Future<void> _generateSummary() async {
    final chatState = ref.read(chatProvider(widget.charId)).value;
    final session = chatState?.session;
    if (session == null) return;
    final chatApi = ref.read(activeApiConfigProvider);
    if (chatApi == null || chatApi.mode == 'embedding') {
      if (mounted) {
        await GlazeBottomSheet.show<void>(
          context,
          title: 'Summary',
          bigInfo: const BottomSheetBigInfo(
            icon: Icons.api_outlined,
            description:
                'No chat API config found. Add one in API Settings first.',
          ),
        );
      }
      return;
    }

    if (!mounted) return;
    setState(() => _isGenerating = true);
    try {
      final summary = await ref
          .read(summaryServiceProvider)
          .generateSummary(
            sessionId: session.id,
            history: session.messages,
            apiConfig: chatApi,
          );
      if (!mounted) return;
      setState(() {
        _localItem = Map.from(_localItem)..['content'] = summary;
      });
      // generateSummary already persisted to the repo; just notify watchers.
      ref.read(summaryRevisionProvider.notifier).state++;
    } catch (e) {
      if (!mounted) return;
      GlazeErrorDialog.show(context, e, prefix: 'Summary Failed');
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SheetView(
      title: "Summary",
      showBack: true,
      actions: [
        SheetViewAction(
          icon: Switch(
            value: _enabled,
            onChanged: _setEnabled,
            activeThumbColor: Theme.of(context).colorScheme.primary,
          ),
          onPressed: () => _setEnabled(!_enabled),
        ),
      ],
      body: Builder(
        builder: (innerContext) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: GenericEditor(
                item: _localItem,
                config: _config,
                onChanged: (val) => setState(() => _localItem = val),
                onSave: _performSave,
                useWindows: false,
                padding: EdgeInsets.only(
                  top: MediaQuery.paddingOf(innerContext).top + 4,
                  bottom: 16,
                ),
              ),
            ),
            Container(
              padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.paddingOf(innerContext).bottom + 24),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.05))),
              ),
              child: FilledButton.icon(
                onPressed: _isGenerating ? null : _generateSummary,
                icon: _isGenerating 
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) 
                    : const Icon(Icons.auto_awesome, size: 18),
                label: Text(_isGenerating ? 'Generating...' : 'Generate Summary'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF528BCC),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showSummarySheet(BuildContext context, String charId) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => SummarySheet(charId: charId),
  );
}
