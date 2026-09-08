import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/llm/embedding_error_labels.dart';
import '../../core/models/lorebook.dart';
import '../../core/state/db_provider.dart';
import '../../core/state/lorebook_embedding_provider.dart';
import '../../core/state/lorebook_provider.dart';
import '../../core/utils/id_generator.dart';
import '../../core/utils/time_helpers.dart';
import '../../features/settings/api_list_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/menu_group.dart';
import '../../shared/widgets/sheet_view.dart';
import 'lorebook_connections_sheet.dart';
import 'lorebook_per_book_settings_screen.dart';
import 'widgets/lorebook_entry_tile.dart';
import 'widgets/lorebook_option_sheet.dart';

enum _View { entries, editEntry }

class _IndexResult {
  final int indexed;
  final int skipped;
  final int failed;
  const _IndexResult(this.indexed, this.skipped, this.failed);
}

class LorebookEditorScreen extends ConsumerStatefulWidget {
  final String lorebookId;

  const LorebookEditorScreen({super.key, required this.lorebookId});

  @override
  ConsumerState<LorebookEditorScreen> createState() =>
      _LorebookEditorScreenState();
}

class _LorebookEditorScreenState extends ConsumerState<LorebookEditorScreen> {
  // Persisted lorebook state (local source of truth once loaded).
  String _name = '';
  List<LorebookEntry> _entries = [];
  LorebookSettings? _settings;
  bool _loaded = false;

  final TextEditingController _searchController = TextEditingController();

  // Embedding / indexing state.
  Map<String, String> _embeddingStatuses = {};
  Map<String, String> _embeddingErrorLabels = {};
  bool _isIndexing = false;
  String _indexStatus = '';
  int _rateLimitCooldown = 0;
  _IndexResult? _indexResult;

  // View navigation.
  _View _view = _View.entries;
  int _editIndex = -1;
  Timer? _saveDebounce;

  // ── Working edit-entry controllers + state ─────────────────────────────────
  TextEditingController? _eKeys,
      _eSecondary,
      _eContent,
      _eComment,
      _eOrder,
      _eScanDepth,
      _eProbability,
      _eSticky,
      _eCooldown,
      _eDelay,
      _eGroup,
      _eGroupWeight,
      _eCharFilter;
  bool _eEnabled = true;
  bool _eConstant = false;
  bool _ePreventRecursion = false;
  bool _eDelayUntilRecursion = false;
  bool _eVectorSearch = false;
  bool _eUseKeywordSearch = true;
  bool _eIgnoreBudget = false;
  bool _eUseGroupScoring = false;
  bool _eCharFilterExclude = false;
  bool? _eCaseSensitive;
  bool? _eMatchWholeWords;
  int _eSelectiveLogic = 4;
  String _ePosition = 'matchGlobal';
  bool _eIndexing = false;

  @override
  void dispose() {
    _searchController.dispose();
    _saveDebounce?.cancel();
    _disposeEditControllers();
    super.dispose();
  }

  // ── Load / save ────────────────────────────────────────────────────────────

  Lorebook? _findLorebook(List<Lorebook> list) {
    for (final lb in list) {
      if (lb.id == widget.lorebookId) return lb;
    }
    return null;
  }

  void _loadFrom(Lorebook lb) {
    _loaded = true;
    _name = lb.name;
    _entries = List.from(lb.entries);
    _settings = lb.settings;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadEmbeddingStatuses());
    });
  }

  Future<void> _loadEmbeddingStatuses() async {
    final repo = ref.read(embeddingRepoProvider);
    final records = await repo.getBySource('lorebook_entry', widget.lorebookId);
    final recordsByEntryId = {
      for (final record in records) record.entryId: record,
    };
    final statuses = <String, String>{};
    final errorLabels = <String, String>{};
    for (final entry in _entries) {
      if (!entry.vectorSearch || !entry.enabled || entry.constant) continue;
      final record = recordsByEntryId['${widget.lorebookId}_${entry.id}'];
      if (record == null) {
        statuses[entry.id] = 'none';
      } else if (record.errorJson != null) {
        statuses[entry.id] = 'error';
        final error = repo.decodeError(record);
        errorLabels[entry.id] = EmbeddingErrorLabel.classify(error).label;
      } else if (repo.hasUsableVectors(record)) {
        statuses[entry.id] = 'indexed';
      } else {
        statuses[entry.id] = 'none';
      }
    }
    if (mounted) {
      setState(() {
        _embeddingStatuses = statuses;
        _embeddingErrorLabels = errorLabels;
      });
    }
  }

  Future<void> _save() async {
    final existing = ref
        .read(lorebooksProvider)
        .value
        ?.where((l) => l.id == widget.lorebookId)
        .firstOrNull;
    final lb = Lorebook(
      id: widget.lorebookId,
      name: _name.trim().isEmpty ? 'new_lorebook'.tr() : _name.trim(),
      enabled: existing?.enabled ?? true,
      activationScope: existing?.activationScope ?? 'global',
      activationTargetId: existing?.activationTargetId,
      entries: _entries,
      settings: _settings,
      updatedAt: currentTimestampSeconds(),
    );
    await ref.read(lorebooksProvider.notifier).updateLorebook(lb);
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), _save);
  }

  void _flushSave() {
    if (_saveDebounce?.isActive ?? false) {
      _saveDebounce!.cancel();
      _save();
    }
  }

  // ── Entry list ops ───────────────────────────────────────────────────────

  List<LorebookEntry> get _filteredEntries {
    final q = _searchController.text.trim().toLowerCase();
    if (q.isEmpty) return _entries;
    return _entries.where((e) {
      return e.keys.any((k) => k.toLowerCase().contains(q)) ||
          e.content.toLowerCase().contains(q) ||
          e.comment.toLowerCase().contains(q);
    }).toList();
  }

  bool get _needsReindex => _entries.any(
    (e) =>
        e.vectorSearch &&
        e.enabled &&
        !e.constant &&
        _embeddingStatuses[e.id] != 'indexed',
  );

  int get _missingVectorCount => _entries
      .where(
        (e) =>
            e.vectorSearch &&
            e.enabled &&
            !e.constant &&
            _embeddingStatuses[e.id] != 'indexed',
      )
      .length;

  List<LorebookEntry> get _failedEntries =>
      _entries.where((e) => _embeddingStatuses[e.id] == 'error').toList();

  void _toggleEntry(int index) {
    setState(() {
      _entries[index] = _entries[index].copyWith(
        enabled: !_entries[index].enabled,
      );
    });
    _save();
  }

  void _deleteEntry(int index) {
    final entry = _entries[index];
    setState(() => _entries.removeAt(index));
    _save();
    ref
        .read(embeddingRepoProvider)
        .deleteByEntryId('${widget.lorebookId}_${entry.id}');
  }

  void _addEntryMenu() {
    GlazeBottomSheet.show<void>(
      context,
      title: 'btn_add'.tr(),
      items: [
        BottomSheetItem(
          label: 'lorebook_new_entry'.tr(),
          icon: Icons.add,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _addEntry();
          },
        ),
        BottomSheetItem(
          label: 'action_copy_from_lorebook'.tr(),
          icon: Icons.content_copy_outlined,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _openCopyEntryLorebookPicker();
          },
        ),
      ],
    );
  }

  void _addEntry() {
    final entry = LorebookEntry(id: generateId(), selectiveLogic: 4);
    setState(() => _entries.add(entry));
    _save();
    _openEntry(_entries.length - 1);
  }

  /// Live entries for [lb] — use the in-memory list for the lorebook currently
  /// being edited so unsaved edits are reflected.
  List<LorebookEntry> _entriesOf(Lorebook lb) =>
      lb.id == widget.lorebookId ? _entries : lb.entries;

  /// Step 1 of "Copy from Lorebook": pick which lorebook to copy an entry from.
  void _openCopyEntryLorebookPicker() {
    final lorebooks = ref.read(lorebooksProvider).value ?? const <Lorebook>[];
    if (lorebooks.isEmpty) return;
    GlazeBottomSheet.show<void>(
      context,
      title: 'lorebook_select'.tr(),
      cardItems: [
        for (final lb in lorebooks)
          BottomSheetCardItem(
            label: lb.name.isEmpty ? 'new_lorebook'.tr() : lb.name,
            icon: Icons.menu_book_outlined,
            badge: '${_entriesOf(lb).length}',
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              _openCopyEntryPicker(lb);
            },
          ),
      ],
    );
  }

  /// Step 2 of "Copy from Lorebook": pick which entry from the chosen lorebook.
  void _openCopyEntryPicker(Lorebook lb) {
    final entries = _entriesOf(lb);
    if (entries.isEmpty) {
      GlazeBottomSheet.show<void>(
        context,
        title: lb.name,
        items: [
          BottomSheetItem(
            label: 'no_entries_found'.tr(),
            centered: true,
            onTap: () => Navigator.of(context, rootNavigator: true).pop(),
          ),
        ],
      );
      return;
    }
    GlazeBottomSheet.show<void>(
      context,
      title: '${lb.name} — ${'label_entries'.tr()}',
      items: [
        for (final entry in entries)
          BottomSheetItem(
            icon: entry.vectorSearch
                ? Icons.hub_outlined
                : Icons.article_outlined,
            label: _entryLabel(entry),
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              _copyEntryFromLorebook(entry);
            },
          ),
      ],
    );
  }

  String _entryLabel(LorebookEntry e) {
    if (e.comment.isNotEmpty) return e.comment;
    if (e.keys.isNotEmpty) return e.keys.join(', ');
    return 'unnamed_entry'.tr();
  }

  void _copyEntryFromLorebook(LorebookEntry source) {
    // Deep-clone with a fresh id and a " (copy)" suffix on the comment, so the
    // copy is independent of its origin (incl. across lorebooks).
    final clone = source.copyWith(
      id: generateId(),
      comment: source.comment.isEmpty
          ? '${_entryLabel(source)} (copy)'
          : '${source.comment} (copy)',
    );
    setState(() => _entries.add(clone));
    _save();
    _openEntry(_entries.length - 1);
  }

  void _entryMenu(int index) {
    GlazeBottomSheet.show<void>(
      context,
      title: _entries[index].comment.isNotEmpty
          ? _entries[index].comment
          : 'unnamed_entry'.tr(),
      items: [
        BottomSheetItem(
          label: 'btn_edit'.tr(),
          icon: Icons.edit_outlined,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _openEntry(index);
          },
        ),
        BottomSheetItem(
          label: 'btn_delete'.tr(),
          icon: Icons.delete_outline,
          isDestructive: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _deleteEntry(index);
          },
        ),
      ],
    );
  }

  // ── Edit-entry working copy ────────────────────────────────────────────────

  void _disposeEditControllers() {
    for (final c in [
      _eKeys,
      _eSecondary,
      _eContent,
      _eComment,
      _eOrder,
      _eScanDepth,
      _eProbability,
      _eSticky,
      _eCooldown,
      _eDelay,
      _eGroup,
      _eGroupWeight,
      _eCharFilter,
    ]) {
      c?.dispose();
    }
    _eKeys = _eSecondary = _eContent = _eComment = _eOrder = _eScanDepth =
        _eProbability = _eSticky = _eCooldown = _eDelay = _eGroup =
            _eGroupWeight = _eCharFilter = null;
  }

  void _openEntry(int index) {
    final e = _entries[index];
    _disposeEditControllers();
    _eKeys = TextEditingController(text: e.keys.join(', '));
    _eSecondary = TextEditingController(text: e.secondaryKeys.join(', '));
    _eContent = TextEditingController(text: e.content);
    _eComment = TextEditingController(text: e.comment);
    _eOrder = TextEditingController(text: e.order.toString());
    _eScanDepth = TextEditingController(text: e.scanDepth?.toString() ?? '');
    _eProbability = TextEditingController(text: e.probability.toString());
    _eSticky = TextEditingController(text: e.sticky.toString());
    _eCooldown = TextEditingController(text: e.cooldown.toString());
    _eDelay = TextEditingController(text: e.delay.toString());
    _eGroup = TextEditingController(text: e.group);
    _eGroupWeight = TextEditingController(text: e.groupProminence.toString());
    _eCharFilter = TextEditingController(
      text: e.characterFilter?.names.join(', ') ?? '',
    );
    _eEnabled = e.enabled;
    _eConstant = e.constant;
    _ePreventRecursion = e.preventRecursion;
    _eDelayUntilRecursion = e.delayUntilRecursion;
    _eVectorSearch = e.vectorSearch;
    _eUseKeywordSearch = e.useKeywordSearch;
    _eIgnoreBudget = e.ignoreBudget;
    _eUseGroupScoring = e.useGroupScoring;
    _eCharFilterExclude = e.characterFilter?.isExclude ?? false;
    _eCaseSensitive = e.caseSensitive;
    _eMatchWholeWords = e.matchWholeWords;
    _eSelectiveLogic = e.selectiveLogic;
    _ePosition = e.position;
    _eIndexing = false;
    setState(() {
      _editIndex = index;
      _view = _View.editEntry;
    });
  }

  void _closeEdit() {
    _flushSave();
    setState(() {
      _view = _View.entries;
      _editIndex = -1;
    });
    unawaited(_loadEmbeddingStatuses());
  }

  LorebookEntry _buildEditEntry() {
    final base = _entries[_editIndex];
    final names = _parseList(_eCharFilter!.text);
    return base.copyWith(
      keys: _parseList(_eKeys!.text),
      secondaryKeys: _parseList(_eSecondary!.text),
      content: _eContent!.text,
      comment: _eComment!.text.trim(),
      order: int.tryParse(_eOrder!.text) ?? 100,
      scanDepth: _eScanDepth!.text.trim().isEmpty
          ? null
          : int.tryParse(_eScanDepth!.text),
      probability: int.tryParse(_eProbability!.text) ?? 100,
      sticky: int.tryParse(_eSticky!.text) ?? 0,
      cooldown: int.tryParse(_eCooldown!.text) ?? 0,
      delay: int.tryParse(_eDelay!.text) ?? 0,
      group: _eGroup!.text.trim(),
      groupProminence: int.tryParse(_eGroupWeight!.text) ?? 100,
      enabled: _eEnabled,
      constant: _eConstant,
      preventRecursion: _ePreventRecursion,
      delayUntilRecursion: _eDelayUntilRecursion,
      vectorSearch: _eVectorSearch,
      useKeywordSearch: _eUseKeywordSearch,
      ignoreBudget: _eIgnoreBudget,
      useGroupScoring: _eUseGroupScoring,
      caseSensitive: _eCaseSensitive,
      matchWholeWords: _eMatchWholeWords,
      selectiveLogic: _eSelectiveLogic,
      position: _ePosition,
      characterFilter: names.isEmpty
          ? null
          : LorebookCharacterFilter(
              names: names,
              isExclude: _eCharFilterExclude,
            ),
    );
  }

  /// Commit the working entry into [_entries]. [immediate] saves now (used for
  /// toggles/selectors); otherwise the save is debounced (used for typing).
  void _commitEdit({bool immediate = false}) {
    setState(() => _entries[_editIndex] = _buildEditEntry());
    if (immediate) {
      _saveDebounce?.cancel();
      _save();
    } else {
      _scheduleSave();
    }
  }

  List<String> _parseList(String text) =>
      text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

  void _onConstantChanged(bool v) {
    setState(() {
      _eConstant = v;
      if (v) {
        // Constant entries cannot use vector search (Vue handleConstantToggle).
        _eVectorSearch = false;
        ref
            .read(embeddingRepoProvider)
            .deleteByEntryId('${widget.lorebookId}_${_entries[_editIndex].id}');
      }
    });
    _commitEdit(immediate: true);
  }

  // ── Indexing actions (kept ~verbatim from the previous editor) ────────────

  Future<void> _indexEntries() async {
    await ref.read(apiListProvider.future);
    if (!mounted) return;
    final config = ref.read(embeddingConfigProvider);
    if (config.endpoint.isEmpty) {
      GlazeToast.show(context, 'vector_error_config_endpoint'.tr());
      return;
    }
    final vectorEntries = _entries
        .where((e) => e.vectorSearch && e.enabled && !e.constant)
        .toList();
    if (vectorEntries.isEmpty) {
      GlazeToast.show(context, 'no_entries_found'.tr());
      return;
    }

    setState(() {
      _isIndexing = true;
      _indexResult = null;
      _indexStatus = 'index_progress'.tr(
        namedArgs: {'done': '0', 'total': '${vectorEntries.length}'},
      );
    });

    try {
      final service = ref.read(lorebookEmbeddingServiceProvider);
      final result = await service.indexLorebookEntries(
        widget.lorebookId,
        _entries,
        config,
        embeddingTarget: _settings?.embeddingTarget ?? 'content',
        onProgress: (current, total, name) {
          if (!mounted) return;
          setState(
            () => _indexStatus = 'index_progress'.tr(
              namedArgs: {'done': '$current', 'total': '$total'},
            ),
          );
        },
      );
      if (mounted) {
        setState(() {
          _isIndexing = false;
          _indexStatus = '';
          _indexResult = _IndexResult(
            result.indexed,
            result.skipped,
            result.failed,
          );
          if (result.rateLimited && result.retryAfter > 0) {
            _rateLimitCooldown = result.retryAfter;
            _startCooldownTimer();
          }
        });
        await _loadEmbeddingStatuses();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isIndexing = false;
          _indexStatus = '';
        });
        await _loadEmbeddingStatuses();
        if (!mounted) return;
        GlazeErrorDialog.show(
          context,
          e,
          prefix: '${'settings_err_failed'.tr()} ',
        );
      }
    }
  }

  Future<void> _retryFailed() async {
    await ref.read(apiListProvider.future);
    if (!mounted) return;
    final config = ref.read(embeddingConfigProvider);
    if (config.endpoint.isEmpty) {
      GlazeToast.show(context, 'vector_error_config_endpoint'.tr());
      return;
    }

    setState(() {
      _isIndexing = true;
      _indexResult = null;
      _indexStatus = 'btn_retry_failed'.tr();
    });

    try {
      final service = ref.read(lorebookEmbeddingServiceProvider);
      final result = await service.indexLorebookEntries(
        widget.lorebookId,
        _entries,
        config,
        retryFailedOnly: true,
        embeddingTarget: _settings?.embeddingTarget ?? 'content',
        onProgress: (current, total, name) {
          if (!mounted) return;
          setState(
            () => _indexStatus = 'index_progress'.tr(
              namedArgs: {'done': '$current', 'total': '$total'},
            ),
          );
        },
      );
      if (mounted) {
        setState(() {
          _isIndexing = false;
          _indexStatus = '';
          _indexResult = _IndexResult(
            result.indexed,
            result.skipped,
            result.failed,
          );
          if (result.rateLimited && result.retryAfter > 0) {
            _rateLimitCooldown = result.retryAfter;
            _startCooldownTimer();
          }
        });
        await _loadEmbeddingStatuses();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isIndexing = false;
          _indexStatus = '';
        });
        await _loadEmbeddingStatuses();
        if (!mounted) return;
        GlazeErrorDialog.show(
          context,
          e,
          prefix: '${'settings_err_failed'.tr()} ',
        );
      }
    }
  }

  Future<void> _clearAndReindex() async {
    final confirmed = await GlazeBottomSheet.show<bool>(
      context,
      title: 'action_delete_indexes'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_sweep,
        description: 'action_delete_indexes'.tr(),
      ),
      items: [
        BottomSheetItem(
          label: 'memory_books_btn_reindex'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
        ),
      ],
    );
    if (confirmed != true) return;

    await ref.read(apiListProvider.future);
    if (!mounted) return;
    final config = ref.read(embeddingConfigProvider);
    if (config.endpoint.isEmpty) {
      GlazeToast.show(context, 'vector_error_config_endpoint'.tr());
      return;
    }
    final vectorEntries = _entries
        .where((e) => e.vectorSearch && e.enabled && !e.constant)
        .toList();
    if (vectorEntries.isEmpty) {
      GlazeToast.show(context, 'no_entries_found'.tr());
      return;
    }

    setState(() {
      _isIndexing = true;
      _indexResult = null;
      _indexStatus = '${'action_delete_indexes'.tr()}...';
    });

    try {
      final service = ref.read(lorebookEmbeddingServiceProvider);
      await service.clearLorebookEmbeddings(widget.lorebookId);
      final result = await service.indexLorebookEntries(
        widget.lorebookId,
        _entries,
        config,
        forceReindex: true,
        embeddingTarget: _settings?.embeddingTarget ?? 'content',
        onProgress: (current, total, name) {
          if (!mounted) return;
          setState(
            () => _indexStatus = 'index_progress'.tr(
              namedArgs: {'done': '$current', 'total': '$total'},
            ),
          );
        },
      );
      if (mounted) {
        setState(() {
          _isIndexing = false;
          _indexStatus = '';
          _indexResult = _IndexResult(result.indexed, 0, result.failed);
          if (result.rateLimited && result.retryAfter > 0) {
            _rateLimitCooldown = result.retryAfter;
            _startCooldownTimer();
          }
        });
        await _loadEmbeddingStatuses();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isIndexing = false;
          _indexStatus = '';
        });
        await _loadEmbeddingStatuses();
        if (!mounted) return;
        GlazeErrorDialog.show(
          context,
          e,
          prefix: '${'settings_err_failed'.tr()} ',
        );
      }
    }
  }

  void _startCooldownTimer() {
    Future.doWhile(() async {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted) return false;
      setState(() {
        _rateLimitCooldown--;
        if (_rateLimitCooldown <= 0) _rateLimitCooldown = 0;
      });
      return _rateLimitCooldown > 0;
    });
  }

  Future<void> _deleteAllIndexes() async {
    final confirmed = await GlazeBottomSheet.show<bool>(
      context,
      title: 'action_delete_indexes'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description: 'action_delete_indexes'.tr(),
      ),
      items: [
        BottomSheetItem(
          label: 'btn_delete'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
        ),
      ],
    );
    if (confirmed != true) return;

    await ref.read(embeddingRepoProvider).deleteBySourceId(widget.lorebookId);
    await _loadEmbeddingStatuses();
    if (mounted) GlazeToast.show(context, 'action_delete_indexes'.tr());
  }

  void _resetEntriesToGlobal() {
    setState(() {
      for (int i = 0; i < _entries.length; i++) {
        _entries[i] = _entries[i].copyWith(
          caseSensitive: null,
          matchWholeWords: null,
          position: 'matchGlobal',
        );
      }
    });
    _save();
    GlazeToast.show(context, 'action_reset'.tr());
  }

  void _enableVectorForAll() {
    final alreadyAll = _entries.every((e) => e.vectorSearch || e.constant);
    setState(() {
      for (int i = 0; i < _entries.length; i++) {
        if (!_entries[i].constant) {
          _entries[i] = _entries[i].copyWith(vectorSearch: !alreadyAll);
        }
      }
    });
    _save();
    _loadEmbeddingStatuses();
    GlazeToast.show(
      context,
      alreadyAll
          ? 'action_disable_vector_all'.tr()
          : 'action_enable_vector_all'.tr(),
    );
  }

  Future<void> _indexSingleEntry() async {
    final entry = _entries[_editIndex];
    await ref.read(apiListProvider.future);
    if (!mounted) return;
    final config = ref.read(embeddingConfigProvider);
    if (config.endpoint.isEmpty) {
      GlazeToast.show(context, 'vector_error_config_endpoint'.tr());
      return;
    }
    setState(() => _eIndexing = true);
    try {
      final service = ref.read(lorebookEmbeddingServiceProvider);
      final result = await service.indexLorebookEntries(
        widget.lorebookId,
        [entry],
        config,
        embeddingTarget: _settings?.embeddingTarget ?? 'content',
      );
      if (mounted) {
        setState(() {
          _eIndexing = false;
          _embeddingStatuses[entry.id] = result.indexed > 0
              ? 'indexed'
              : 'error';
        });
        GlazeToast.show(
          context,
          result.indexed > 0 ? 'entry_indexed'.tr() : 'entry_index_error'.tr(),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _eIndexing = false;
          _embeddingStatuses[entry.id] = 'error';
        });
      }
    }
  }

  void _renameLorebook() {
    GlazeBottomSheet.show<void>(
      context,
      title: 'lorebook_rename'.tr(),
      input: BottomSheetInput(
        placeholder: 'placeholder_name'.tr(),
        value: _name,
        confirmLabel: 'btn_save'.tr(),
        onConfirm: (name) {
          Navigator.of(context, rootNavigator: true).pop();
          setState(() => _name = name.trim());
          _save();
        },
      ),
    );
  }

  Future<void> _openPerBookSettings() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => LorebookPerBookSettingsScreen(
          settings: _settings,
          globalSettings: ref.read(lorebookSettingsProvider),
        ),
      ),
    );
    if (result != null) {
      setState(() {
        if (result['reset'] == true) {
          _settings = null;
        } else if (result['settings'] != null) {
          _settings = LorebookSettings.fromJson(
            result['settings'] as Map<String, dynamic>,
          );
        }
      });
      unawaited(_save());
    }
  }

  void _entriesMenu() {
    GlazeBottomSheet.show<void>(
      context,
      title: _name,
      items: [
        BottomSheetItem(
          label: 'lorebook_rename'.tr(),
          icon: Icons.drive_file_rename_outline,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _renameLorebook();
          },
        ),
        BottomSheetItem(
          label: 'title_lorebook_settings'.tr(),
          icon: Icons.settings_outlined,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _openPerBookSettings();
          },
        ),
        BottomSheetItem(
          label: 'header_connections'.tr(),
          icon: Icons.link,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            showLorebookConnections(context, widget.lorebookId);
          },
        ),
        BottomSheetItem(
          label: 'btn_test_connection'.tr(),
          icon: Icons.science_outlined,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _showTestDialog();
          },
        ),
        BottomSheetItem(
          label: 'action_delete_indexes'.tr(),
          icon: Icons.delete_outline,
          isDestructive: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _deleteAllIndexes();
          },
        ),
      ],
    );
  }

  void _showTestDialog() {
    final testCtrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: context.cs.surfaceContainerHighest,
              title: Text(
                'btn_test_connection'.tr(),
                style: TextStyle(color: context.cs.onSurface),
              ),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: testCtrl,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      style: TextStyle(color: context.cs.onSurface),
                      decoration: InputDecoration(
                        hintText: 'placeholder_search_lore'.tr(),
                        hintStyle: TextStyle(
                          color: context.cs.onSurfaceVariant.withValues(
                            alpha: 0.5,
                          ),
                        ),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.05),
                      ),
                      maxLines: 3,
                      minLines: 1,
                      onChanged: (_) => setDialogState(() {}),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'label_entries'.tr(),
                      style: TextStyle(
                        color: context.cs.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ..._matchEntries(testCtrl.text).map(
                      (e) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.check_circle,
                              size: 14,
                              color: Colors.green,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                e.comment.isNotEmpty
                                    ? e.comment
                                    : e.keys.join(', '),
                                style: TextStyle(
                                  color: context.cs.onSurface,
                                  fontSize: 13,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (testCtrl.text.isNotEmpty &&
                        _matchEntries(testCtrl.text).isEmpty)
                      Text(
                        'no_results'.tr(),
                        style: TextStyle(
                          color: context.cs.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(
                    'btn_close'.tr(),
                    style: TextStyle(color: context.cs.onSurfaceVariant),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  List<LorebookEntry> _matchEntries(String text) {
    if (text.trim().isEmpty) return [];
    final lower = text.toLowerCase();
    return _entries.where((e) {
      if (!e.enabled) return false;
      for (final key in [...e.keys, ...e.secondaryKeys]) {
        if (key.isEmpty) continue;
        final caseSensitive =
            e.caseSensitive ?? _settings?.caseSensitive ?? false;
        if (caseSensitive) {
          if (text.contains(key)) return true;
        } else {
          if (lower.contains(key.toLowerCase())) return true;
        }
      }
      return false;
    }).toList();
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      final list = ref.watch(lorebooksProvider).value;
      if (list == null) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      final lb = _findLorebook(list);
      if (lb == null) {
        return Scaffold(
          backgroundColor: context.cs.surface,
          appBar: AppBar(title: Text('no_results'.tr())),
          body: Center(child: Text('no_lorebooks'.tr())),
        );
      }
      _loadFrom(lb);
    }

    final isEntries = _view == _View.entries;

    return SheetView(
      showRouteBackground: false,
      shellBranchIndex: 2,
      showBack: true,
      onBack: () {
        if (_view == _View.editEntry) {
          _closeEdit();
        } else {
          Navigator.of(context).pop();
        }
      },
      title: isEntries
          ? null
          : (_entries[_editIndex].comment.isNotEmpty
                ? _entries[_editIndex].comment
                : 'unnamed_entry'.tr()),
      titleWidget: isEntries ? _entriesTitle() : null,
      headerBottom: isEntries ? _searchBar() : null,
      actions: isEntries
          ? [
              SheetViewAction(
                icon: const Icon(Icons.more_vert, size: 20),
                onPressed: _entriesMenu,
              ),
            ]
          : [
              SheetViewAction(
                icon: Icon(
                  _eEnabled ? Icons.toggle_on : Icons.toggle_off,
                  size: 28,
                ),
                color: _eEnabled
                    ? context.cs.primary
                    : context.cs.onSurfaceVariant,
                tooltip: 'label_enabled'.tr(),
                onPressed: () {
                  setState(() => _eEnabled = !_eEnabled);
                  _commitEdit(immediate: true);
                },
              ),
            ],
      floatingActionButton: isEntries
          ? FloatingActionButton(
              // Disable the Hero so this FAB doesn't collide with the list
              // screen's FAB (default tags clash during the push transition).
              heroTag: null,
              backgroundColor: context.cs.primary,
              onPressed: _addEntryMenu,
              child: const Icon(Icons.add, color: Colors.black),
            )
          : null,
      body: isEntries ? _entriesBody() : _editBody(),
    );
  }

  Widget _entriesTitle() {
    return Row(
      children: [
        Flexible(
          child: Text(
            _name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: context.cs.onSurface,
            ),
          ),
        ),
      ],
    );
  }

  Widget _searchBar() {
    return TextField(
      controller: _searchController,
      style: TextStyle(color: context.cs.onSurface, fontSize: 14),
      decoration: InputDecoration(
        hintText: 'placeholder_search_lore'.tr(),
        hintStyle: TextStyle(
          color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
        ),
        prefixIcon: Icon(
          Icons.search,
          size: 18,
          color: context.cs.onSurfaceVariant,
        ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onChanged: (_) => setState(() {}),
    );
  }

  // ── Entries body ───────────────────────────────────────────────────────────

  Widget _entriesBody() {
    final filtered = _filteredEntries;
    return Builder(
      builder: (context) => ListView(
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 100).add(
          EdgeInsets.only(
            top: MediaQuery.paddingOf(context).top + 16,
            bottom: MediaQuery.paddingOf(context).bottom,
          ),
        ),
        children: [
          if (_needsReindex) _reindexBanner(),
          if (_entries.isNotEmpty) _toolbar(),
          if (!_isIndexing && _indexResult != null) _indexResultBlock(),
          if (_failedEntries.isNotEmpty) _failedEntriesBlock(),
          if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 48, 16, 16),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.article_outlined,
                      size: 48,
                      color: context.cs.onSurfaceVariant,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'no_entries_found'.tr(),
                      style: TextStyle(color: context.cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                children: [
                  for (final entry in filtered)
                    _EntryRow(
                      entry: entry,
                      status: _embeddingStatuses[entry.id],
                      onTap: () => _openEntry(_entries.indexOf(entry)),
                      onToggle: () => _toggleEntry(_entries.indexOf(entry)),
                      onMore: () => _entryMenu(_entries.indexOf(entry)),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _reindexBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.08),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.28)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'vector_reindex_title'.tr(),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: context.cs.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'vector_reindex_desc'.tr(
                    namedArgs: {'count': '$_missingVectorCount'},
                  ),
                  style: TextStyle(
                    fontSize: 12,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: _isIndexing ? null : _indexEntries,
            child: Text('btn_index_all'.tr()),
          ),
        ],
      ),
    );
  }

  Widget _toolbar() {
    final allVector = _entries.every((e) => e.vectorSearch || e.constant);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Row(
        children: [
          _ToolbarButton(
            icon: Icons.check_circle_outline,
            label: allVector
                ? 'btn_disable_vector_all'.tr()
                : 'btn_enable_vector_all'.tr(),
            onTap: _entries.isEmpty ? null : _enableVectorForAll,
          ),
          const SizedBox(width: 8),
          _ToolbarButton(
            icon: Icons.restore,
            label: 'match_global'.tr(),
            secondary: true,
            onTap: _resetEntriesToGlobal,
          ),
          const SizedBox(width: 8),
          _ToolbarButton(
            icon: Icons.auto_fix_high,
            label: _rateLimitCooldown > 0
                ? 'btn_rate_limited'.tr(
                    namedArgs: {'seconds': '$_rateLimitCooldown'},
                  )
                : _isIndexing
                ? (_indexStatus.isNotEmpty ? _indexStatus : 'btn_indexing'.tr())
                : 'btn_index_all'.tr(),
            onTap: (_isIndexing || _rateLimitCooldown > 0)
                ? null
                : _indexEntries,
          ),
          if (_failedEntries.isNotEmpty) ...[
            const SizedBox(width: 8),
            _ToolbarButton(
              icon: Icons.refresh,
              label: 'btn_retry_failed'.tr(),
              secondary: true,
              onTap: (_isIndexing || _rateLimitCooldown > 0)
                  ? null
                  : _retryFailed,
            ),
          ],
          const SizedBox(width: 8),
          _ToolbarButton(
            icon: Icons.delete_sweep_outlined,
            label: 'action_delete_indexes'.tr(),
            secondary: true,
            onTap: _isIndexing ? null : _clearAndReindex,
          ),
        ],
      ),
    );
  }

  Widget _indexResultBlock() {
    final r = _indexResult!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'index_done'.tr(namedArgs: {'count': '${r.indexed}'}),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.green,
            ),
          ),
          if (r.skipped > 0)
            Text(
              'index_skipped'.tr(namedArgs: {'skipped': '${r.skipped}'}),
              style: const TextStyle(fontSize: 12, color: Colors.green),
            ),
          if (r.failed > 0)
            Text(
              'index_failed'.tr(namedArgs: {'failed': '${r.failed}'}),
              style: const TextStyle(fontSize: 12, color: Colors.redAccent),
            ),
        ],
      ),
    );
  }

  Widget _failedEntriesBlock() {
    final failed = _failedEntries;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.08),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.18)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'vector_failed_entries_title'.tr(
              namedArgs: {'count': '${failed.length}'},
            ),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Colors.orange,
            ),
          ),
          const SizedBox(height: 6),
          for (final e in failed)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.comment.isNotEmpty ? e.comment : e.keys.join(', '),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: context.cs.onSurface,
                    ),
                  ),
                  Text(
                    _embeddingErrorLabels[e.id] ?? 'entry_index_error'.tr(),
                    style: const TextStyle(fontSize: 12, color: Colors.orange),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ── Edit-entry body ────────────────────────────────────────────────────────

  Widget _editBody() {
    return Builder(
      builder: (context) => ListView(
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 16,
          bottom: MediaQuery.paddingOf(context).bottom + 40,
        ),
        children: [
          // Activation & Logic
          MenuGroup(
            header: 'section_activation_logic'.tr(),
            helpTerm: 'lorebook-keys',
            items: [
              if (_eVectorSearch)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text(
                    'desc_vector_search_supplements_keys'.tr(),
                    style: const TextStyle(fontSize: 12, color: Colors.green),
                  ),
                ),
              if (!_eConstant) ...[
                MenuFieldItem(
                  label: 'label_primary_keys'.tr(),
                  controller: _eKeys!,
                  placeholder: 'placeholder_keys'.tr(),
                  onChanged: (_) => _commitEdit(),
                ),
                MenuSelectorItem(
                  label: 'label_logic_mode'.tr(),
                  currentValue: _logicLabel(_eSelectiveLogic),
                  onTap: () => showLorebookOptionSheet<int>(
                    context,
                    title: 'label_logic_mode'.tr(),
                    current: _eSelectiveLogic,
                    options: [
                      LorebookOption(4, 'logic_primary_only'.tr()),
                      LorebookOption(0, 'logic_and_any'.tr()),
                      LorebookOption(1, 'logic_and_all'.tr()),
                      LorebookOption(2, 'logic_not_any'.tr()),
                      LorebookOption(3, 'logic_not_all'.tr()),
                    ],
                    onSelect: (v) {
                      setState(() => _eSelectiveLogic = v);
                      _commitEdit(immediate: true);
                    },
                  ),
                ),
                MenuSelectorItem(
                  label: 'label_case_sensitive'.tr(),
                  currentValue: _triLabel(_eCaseSensitive),
                  onTap: () => showLorebookOptionSheet<String>(
                    context,
                    title: 'label_case_sensitive'.tr(),
                    current: _triKey(_eCaseSensitive),
                    options: [
                      LorebookOption('null', 'match_global'.tr()),
                      LorebookOption('true', 'on'.tr()),
                      LorebookOption('false', 'off'.tr()),
                    ],
                    onSelect: (v) {
                      setState(() => _eCaseSensitive = _triValue(v));
                      _commitEdit(immediate: true);
                    },
                  ),
                ),
                MenuSelectorItem(
                  label: 'label_match_whole_words'.tr(),
                  currentValue: _triLabel(_eMatchWholeWords),
                  onTap: () => showLorebookOptionSheet<String>(
                    context,
                    title: 'label_match_whole_words'.tr(),
                    current: _triKey(_eMatchWholeWords),
                    options: [
                      LorebookOption('null', 'match_global'.tr()),
                      LorebookOption('true', 'match_whole_words_st'.tr()),
                      LorebookOption('false', 'off'.tr()),
                    ],
                    onSelect: (v) {
                      setState(() => _eMatchWholeWords = _triValue(v));
                      _commitEdit(immediate: true);
                    },
                  ),
                ),
                MenuSwitchItem(
                  label: 'label_group_scoring'.tr(),
                  value: _eUseGroupScoring,
                  onChanged: (v) {
                    setState(() => _eUseGroupScoring = v);
                    _commitEdit(immediate: true);
                  },
                ),
                if (_eSelectiveLogic != 4)
                  MenuFieldItem(
                    label: 'label_secondary_keys'.tr(),
                    controller: _eSecondary!,
                    placeholder: 'placeholder_filters'.tr(),
                    onChanged: (_) => _commitEdit(),
                  ),
              ],
            ],
          ),

          // Content & Properties
          MenuGroup(
            header: 'section_content_properties'.tr(),
            items: [
              MenuFieldItem(
                label: 'label_content'.tr(),
                controller: _eContent!,
                placeholder: 'placeholder_lore_content'.tr(),
                maxLines: 10,
                onChanged: (_) => _commitEdit(),
              ),
              MenuFieldItem(
                label: 'label_comment'.tr(),
                controller: _eComment!,
                placeholder: 'placeholder_comment'.tr(),
                onChanged: (_) => _commitEdit(),
              ),
            ],
          ),

          // Injection Rules
          MenuGroup(
            header: 'section_injection_rules'.tr(),
            helpTerm: 'lorebook-budget',
            items: [
              MenuSelectorItem(
                label: 'label_injection_position'.tr(),
                currentValue: _positionLabel(_ePosition),
                onTap: () => showLorebookOptionSheet<String>(
                  context,
                  title: 'label_injection_position'.tr(),
                  current: _ePosition,
                  options: [
                    LorebookOption('matchGlobal', 'match_global'.tr()),
                    LorebookOption('worldInfoBefore', 'pos_before_char'.tr()),
                    LorebookOption('worldInfoAfter', 'pos_after_char'.tr()),
                    LorebookOption(
                      'lorebooksMacro',
                      'pos_lorebooks_macro'.tr(),
                    ),
                  ],
                  onSelect: (v) {
                    setState(() => _ePosition = v);
                    _commitEdit(immediate: true);
                  },
                ),
              ),
              _numberField('label_order_priority'.tr(), _eOrder!),
            ],
          ),

          // Scan & Recursion
          MenuGroup(
            header: 'section_scan_recursion'.tr(),
            helpTerm: 'lorebook-recursion',
            items: [
              _numberField('label_scan_depth_lore'.tr(), _eScanDepth!),
              MenuSwitchItem(
                label: 'label_prevent_recursion'.tr(),
                value: _ePreventRecursion,
                onChanged: (v) {
                  setState(() => _ePreventRecursion = v);
                  _commitEdit(immediate: true);
                },
              ),
              MenuSwitchItem(
                label: 'label_delay_until_recursion'.tr(),
                value: _eDelayUntilRecursion,
                onChanged: (v) {
                  setState(() => _eDelayUntilRecursion = v);
                  _commitEdit(immediate: true);
                },
              ),
              _numberField('label_probability'.tr(), _eProbability!),
            ],
          ),

          // Vector Search
          MenuGroup(
            header: 'section_vector_search'.tr(),
            items: [
              MenuSwitchItem(
                label: 'label_constant'.tr(),
                description: 'desc_constant_disables_vector'.tr(),
                value: _eConstant,
                onChanged: _onConstantChanged,
              ),
              MenuSwitchItem(
                label: 'label_vector_search'.tr(),
                description: _eConstant
                    ? 'desc_vector_disabled_for_constant'.tr()
                    : 'desc_vector_search_entry'.tr(),
                value: _eVectorSearch,
                onChanged: _eConstant
                    ? (_) {}
                    : (v) {
                        setState(() => _eVectorSearch = v);
                        _commitEdit(immediate: true);
                      },
              ),
              if (_eVectorSearch && !_eConstant)
                MenuSwitchItem(
                  label: 'label_use_keyword_search'.tr(),
                  description: 'desc_use_keyword_search'.tr(),
                  value: _eUseKeywordSearch,
                  onChanged: (v) {
                    setState(() => _eUseKeywordSearch = v);
                    _commitEdit(immediate: true);
                  },
                ),
              if (_eVectorSearch && !_eConstant)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: context.cs.primary,
                            foregroundColor: Colors.black,
                          ),
                          onPressed: _eIndexing ? null : _indexSingleEntry,
                          child: Text(
                            _eIndexing
                                ? 'btn_indexing'.tr()
                                : 'btn_index_entry'.tr(),
                          ),
                        ),
                      ),
                      if (_embeddingStatuses[_entries[_editIndex].id] != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            switch (_embeddingStatuses[_entries[_editIndex]
                                .id]) {
                              'indexed' => 'entry_indexed'.tr(),
                              'error' => 'entry_index_error'.tr(),
                              _ => 'entry_not_indexed'.tr(),
                            },
                            style: TextStyle(
                              fontSize: 12,
                              color:
                                  switch (_embeddingStatuses[_entries[_editIndex]
                                      .id]) {
                                    'indexed' => Colors.green,
                                    'error' => Colors.orange,
                                    _ => context.cs.onSurfaceVariant,
                                  },
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),

          // Temporal Logic
          MenuGroup(
            header: 'section_temporal_logic'.tr(),
            helpTerm: 'lorebook-temporal',
            items: [
              _numberField('label_sticky'.tr(), _eSticky!),
              _numberField('label_cooldown'.tr(), _eCooldown!),
              _numberField('label_delay_turns'.tr(), _eDelay!),
            ],
          ),

          // Grouping & Filter
          MenuGroup(
            header: 'section_grouping_filter'.tr(),
            helpTerm: 'lorebook-group',
            items: [
              MenuFieldItem(
                label: 'label_group_name'.tr(),
                controller: _eGroup!,
                placeholder: 'placeholder_faction'.tr(),
                onChanged: (_) => _commitEdit(),
              ),
              _numberField('label_group_weight'.tr(), _eGroupWeight!),
              MenuFieldItem(
                label: 'label_character_filter'.tr(),
                controller: _eCharFilter!,
                placeholder: 'placeholder_char_names'.tr(),
                onChanged: (_) => _commitEdit(),
              ),
              MenuSwitchItem(
                label: 'label_exclude_characters'.tr(),
                value: _eCharFilterExclude,
                onChanged: (v) {
                  setState(() => _eCharFilterExclude = v);
                  _commitEdit(immediate: true);
                },
              ),
              MenuSwitchItem(
                label: 'label_ignore_budget'.tr(),
                value: _eIgnoreBudget,
                onChanged: (v) {
                  setState(() => _eIgnoreBudget = v);
                  _commitEdit(immediate: true);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _numberField(String label, TextEditingController controller) {
    return MenuFieldItem(
      label: label,
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onChanged: (_) => _commitEdit(),
    );
  }

  // ── Label helpers ──────────────────────────────────────────────────────────

  String _logicLabel(int v) => switch (v) {
    0 => 'logic_and_any'.tr(),
    1 => 'logic_and_all'.tr(),
    2 => 'logic_not_any'.tr(),
    3 => 'logic_not_all'.tr(),
    _ => 'logic_primary_only'.tr(),
  };

  String _triLabel(bool? v) =>
      v == null ? 'match_global'.tr() : (v ? 'on'.tr() : 'off'.tr());

  String _triKey(bool? v) => v == null ? 'null' : (v ? 'true' : 'false');

  bool? _triValue(String v) => v == 'null' ? null : v == 'true';

  String _positionLabel(String pos) => switch (pos) {
    'worldInfoBefore' => 'pos_before_char'.tr(),
    'worldInfoAfter' => 'pos_after_char'.tr(),
    'lorebooksMacro' => 'pos_lorebooks_macro'.tr(),
    _ => 'match_global'.tr(),
  };
}

// ── Entry row ────────────────────────────────────────────────────────────────

class _EntryRow extends StatelessWidget {
  final LorebookEntry entry;
  final String? status;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onMore;

  const _EntryRow({
    required this.entry,
    required this.status,
    required this.onTap,
    required this.onToggle,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final keysPreview = entry.keys.isEmpty
        ? 'no_keys'.tr()
        : entry.keys.join(', ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            entry.comment.isNotEmpty
                                ? entry.comment
                                : 'unnamed_entry'.tr(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: entry.enabled
                                  ? context.cs.onSurface
                                  : context.cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (entry.vectorSearch) ...[
                          const SizedBox(width: 6),
                          const LorebookEntryBadge(
                            label: 'vec',
                            color: Colors.cyan,
                          ),
                          if (status == 'indexed') ...[
                            const SizedBox(width: 4),
                            const LorebookEntryBadge(
                              label: 'idx',
                              color: Colors.green,
                            ),
                          ],
                          if (status == 'error') ...[
                            const SizedBox(width: 4),
                            const LorebookEntryBadge(
                              label: 'err',
                              color: Colors.orange,
                            ),
                          ],
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      keysPreview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: context.cs.onSurfaceVariant.withValues(
                          alpha: 0.7,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch(
                value: entry.enabled,
                onChanged: (_) => onToggle(),
                activeThumbColor: context.cs.primary,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onMore,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 0, 8),
                  child: Icon(
                    Icons.more_vert,
                    size: 20,
                    color: context.cs.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Toolbar pill ─────────────────────────────────────────────────────────────

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool secondary;

  const _ToolbarButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.secondary = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = secondary ? Colors.orange : context.cs.onSurfaceVariant;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Material(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: fg),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
