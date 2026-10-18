import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/summary_providers.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/generic_editor.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_error_block.dart';
import '../chat_provider.dart';
import '../services/summary_generation_service.dart';

/// Summary tab of the Memory sheet.
///
/// The summary itself, and the one button that rewrites it. `content` is
/// session-scoped and kept in the summary repo — the same store the prompt
/// builder reads, so a manual edit is injected exactly like a generated one.
///
/// Everything else the summary has — the master switch, the prompt template,
/// the auto interval, the injection point — is behind the header's settings
/// button, in [SummarySettingsSheet]. The tab used to carry all of it in one
/// scroll, with the switch as a bare `Switch` in the sheet header; only the
/// text is looked at day to day.
class SummaryTab extends ConsumerStatefulWidget {
  final String charId;

  const SummaryTab({super.key, required this.charId});

  @override
  ConsumerState<SummaryTab> createState() => _SummaryTabState();
}

class _SummaryTabState extends ConsumerState<SummaryTab> {
  late Map<String, dynamic> _localItem;
  bool _isGenerating = false;
  Object? _error;

  /// Last values written (or loaded). Guards against the no-op save that the
  /// editor schedules when [_load] pushes values into its controllers: that
  /// write would stamp the summary row with the current message count and
  /// silently restart the auto-summary countdown just because the sheet was
  /// opened.
  Map<String, dynamic> _savedItem = const {};

  // Captured while the element is active so _performSave can still read
  // providers when invoked from GenericEditor.dispose() (e.g. the sheet is
  // swipe-dismissed with a pending debounced edit) — by then ref.read throws
  // "Looking up a deactivated widget's ancestor is unsafe". Mirrors
  // AuthorsNoteSheet.
  //
  // Not `late final`: didChangeDependencies runs again whenever an inherited
  // widget above this one changes — opening a route over the sheet is enough —
  // and a second assignment to a late final field throws.
  late ProviderContainer _container;

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
    final content = await ref
        .read(summaryServiceProvider)
        .getSummaryContent(session.id);
    if (!mounted) return;
    setState(() {
      _localItem = {'content': content ?? ''};
      _savedItem = Map.of(_localItem);
    });
  }

  /// True when [item] differs from what is already persisted. Values arrive
  /// from text controllers, so compare their string forms.
  bool _isDirty(Map<String, dynamic> item) {
    for (final entry in item.entries) {
      final saved = _savedItem[entry.key];
      if ('${entry.value}' != '$saved') return true;
    }
    return false;
  }

  Future<void> _performSave(Map<String, dynamic> item) async {
    // Use the captured container, not ref — this can be invoked from
    // GenericEditor.dispose() when the element is already deactivated.
    final session = _container.read(chatProvider(widget.charId)).value?.session;
    if (session == null) return;
    if (!_isDirty(item)) return;
    _savedItem = Map.of(item);

    final content = (item['content'] as String?)?.trim() ?? '';
    await _container
        .read(summaryServiceProvider)
        .setSummary(
          sessionId: session.id,
          content: content,
          messageCount: session.messages.length,
          // Left untouched: the template belongs to the settings sheet, and
          // writing it from here would overwrite an edit made there.
        );
    _container.read(summaryRevisionProvider.notifier).state++;
  }

  /// One field. Everything the form used to carry alongside it is in
  /// [SummarySettingsSheet] now.
  List<GenericEditorSection> get _config => [
    GenericEditorSection(
      fields: [
        GenericEditorField(
          key: 'content',
          label: 'summary_title'.tr(),
          type: 'textarea',
          placeholder: 'summary_placeholder'.tr(),
          rows: 16,
          expandable: true,
        ),
      ],
    ),
  ];

  Future<void> _generateSummary() async {
    final session = ref.read(chatProvider(widget.charId)).value?.session;
    if (session == null) return;

    setState(() {
      _isGenerating = true;
      _error = null;
    });
    try {
      // Flush a pending edit first: the editor's save is debounced, and the
      // run reads both the template and the summary it is replacing back out
      // of the repo.
      await _performSave(_localItem);
      if (!mounted) return;
      final summary = await ref
          .read(summaryGenerationServiceProvider)
          .generate(charId: widget.charId, session: session);
      if (!mounted) return;
      setState(() {
        _localItem = Map.from(_localItem)..['content'] = summary;
      });
      // generateSummary already persisted to the repo; just notify watchers.
      ref.read(summaryRevisionProvider.notifier).state++;
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
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
              top: MediaQuery.paddingOf(context).top + 4,
              bottom: 16,
            ),
          ),
        ),
        _buildActionBar(context),
      ],
    );
  }

  /// The one action of the tab, as the kit's button rather than a Material
  /// `FilledButton` in a hand-picked blue.
  Widget _buildActionBar(BuildContext context) {
    final error = _error;
    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        MediaQuery.paddingOf(context).bottom + 24,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.cs.outlineVariant)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlazeActionButton(
            icon: Icons.auto_awesome_rounded,
            label: _isGenerating
                ? 'summary_generating'.tr()
                : 'btn_auto_summary'.tr(),
            tone: GlazeActionTone.primary,
            expand: true,
            busy: _isGenerating,
            onTap: _generateSummary,
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            GlazeErrorBlock.fromError(error),
          ],
        ],
      ),
    );
  }
}
