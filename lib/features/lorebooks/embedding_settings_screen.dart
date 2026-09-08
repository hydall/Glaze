import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/db/repositories/embedding_repo.dart';
import '../../../core/services/api_connection_tester.dart';
import '../../../core/llm/vector_rebuild_service.dart';
import '../../../core/state/lorebook_embedding_provider.dart';
import '../../../core/state/lorebook_provider.dart';
import '../../../core/state/shared_prefs_provider.dart';
import '../../../core/state/vector_rebuild_provider.dart';
import '../../../shared/shell/shell_header_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_error_dialog.dart';
import '../../../shared/widgets/glaze_toast.dart';

class EmbeddingSettingsScreen extends ConsumerStatefulWidget {
  const EmbeddingSettingsScreen({super.key});

  @override
  ConsumerState<EmbeddingSettingsScreen> createState() =>
      _EmbeddingSettingsScreenState();
}

class _EmbeddingSettingsScreenState
    extends ConsumerState<EmbeddingSettingsScreen>
    with ShellHeaderMixin {
  @override
  int get headerBranchIndex => 2;

  @override
  ShellHeaderConfig buildShellHeader() => ShellHeaderConfig(
    title: 'title_embedding_settings'.tr(),
    showBack: true,
    onBack: () => context.go('/tools'),
  );

  late TextEditingController _endpointCtrl;
  late TextEditingController _apiKeyCtrl;
  late TextEditingController _modelCtrl;
  late TextEditingController _maxChunkTokensCtrl;
  late TextEditingController _thresholdCtrl;
  late TextEditingController _topKCtrl;
  late TextEditingController _scanDepthCtrl;
  late TextEditingController _vectorsPerMinuteCtrl;
  late TextEditingController _batchSizeCtrl;
  String _searchType = 'keyword';
  bool _isTesting = false;
  bool _rebuildMemoryBooks = true;
  bool _rebuildLorebooks = true;
  bool _rebuildRawChat = true;
  bool _forceReindex = false;

  @override
  void initState() {
    super.initState();
    final config = ref.read(embeddingConfigProvider);
    final settings = ref.read(lorebookSettingsProvider);
    _endpointCtrl = TextEditingController(text: config.endpoint);
    _apiKeyCtrl = TextEditingController(text: config.apiKey);
    _modelCtrl = TextEditingController(text: config.model);
    _maxChunkTokensCtrl = TextEditingController(
      text: config.maxChunkTokens.toString(),
    );
    _thresholdCtrl = TextEditingController(
      text: settings.vectorThreshold.toString(),
    );
    _topKCtrl = TextEditingController(text: settings.vectorTopK.toString());
    _scanDepthCtrl = TextEditingController(text: settings.scanDepth.toString());
    _vectorsPerMinuteCtrl = TextEditingController(text: '30');
    _batchSizeCtrl = TextEditingController(text: '10');
    _searchType = settings.searchType;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Sync fields when embeddingConfigProvider updates (e.g. after API list loads)
    final config = ref.read(embeddingConfigProvider);
    if (config.endpoint.isNotEmpty && _endpointCtrl.text.isEmpty) {
      _endpointCtrl.text = config.endpoint;
      _apiKeyCtrl.text = config.apiKey;
      _modelCtrl.text = config.model;
      _maxChunkTokensCtrl.text = config.maxChunkTokens.toString();
    }
  }

  @override
  void dispose() {
    _endpointCtrl.dispose();
    _apiKeyCtrl.dispose();
    _modelCtrl.dispose();
    _maxChunkTokensCtrl.dispose();
    _thresholdCtrl.dispose();
    _topKCtrl.dispose();
    _scanDepthCtrl.dispose();
    _vectorsPerMinuteCtrl.dispose();
    _batchSizeCtrl.dispose();
    super.dispose();
  }

  Future<void> _startVectorRebuild() async {
    final sources = <VectorRebuildSource>{
      if (_rebuildMemoryBooks) VectorRebuildSource.memoryBooks,
      if (_rebuildLorebooks) VectorRebuildSource.lorebooks,
      if (_rebuildRawChat) VectorRebuildSource.rawChat,
    };
    if (sources.isEmpty) {
      GlazeToast.show(context, 'Select at least one vector source.');
      return;
    }
    final controller = ref.read(vectorRebuildControllerProvider.notifier);
    await controller.start(
      VectorRebuildRequest(
        sources: sources,
        vectorsPerMinute: int.tryParse(_vectorsPerMinuteCtrl.text) ?? 30,
        batchSize: int.tryParse(_batchSizeCtrl.text) ?? 10,
        forceReindex: _forceReindex,
      ),
    );
  }

  void _save() async {
    final maxChunkTokens = int.tryParse(_maxChunkTokensCtrl.text) ?? 8192;
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setInt('gz_embedding_max_chunk_tokens', maxChunkTokens);

    final current = ref.read(lorebookSettingsProvider);
    ref.read(lorebookSettingsProvider.notifier).state = current.copyWith(
      searchType: _searchType,
      vectorThreshold: double.tryParse(_thresholdCtrl.text) ?? 0.45,
      vectorTopK: int.tryParse(_topKCtrl.text) ?? 10,
      scanDepth: int.tryParse(_scanDepthCtrl.text) ?? 10,
    );

    if (mounted) GlazeToast.show(context, 'settings_saved'.tr());
  }

  Future<void> _testConnection() async {
    setState(() => _isTesting = true);
    final result = await ApiConnectionTester().testEmbedding(
      endpoint: _endpointCtrl.text.trim(),
      apiKey: _apiKeyCtrl.text.trim(),
      model: _modelCtrl.text.trim(),
    );
    if (!mounted) return;
    switch (result) {
      case ApiTestSuccess(:final message):
        GlazeToast.show(context, message);
      case ApiTestFailure(:final error):
        GlazeErrorDialog.show(context, error, prefix: 'Failed: ');
    }
    if (mounted) setState(() => _isTesting = false);
  }

  @override
  Widget build(BuildContext context) {
    final rebuildState = ref.watch(vectorRebuildControllerProvider);
    final staleStats = ref.watch(embeddingStaleStatsProvider);
    return Scaffold(
      backgroundColor: context.cs.surface,
      body: Column(
        children: [
          const SafeArea(
            bottom: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: SizedBox(height: 56),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
              children: [
                Text(
                  'label_search_type'.tr(),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _SearchModeChip(
                      label: 'search_type_keys'.tr(),
                      selected: _searchType == 'keyword',
                      onTap: () => setState(() => _searchType = 'keyword'),
                    ),
                    _SearchModeChip(
                      label: 'search_type_vector'.tr(),
                      selected: _searchType == 'vector',
                      onTap: () => setState(() => _searchType = 'vector'),
                    ),
                    _SearchModeChip(
                      label: 'search_type_both'.tr(),
                      selected: _searchType == 'both',
                      onTap: () => setState(() => _searchType = 'both'),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  'section_embeddings'.tr(),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                _field(
                  'label_embedding_endpoint'.tr(),
                  _endpointCtrl,
                  hint: 'http://127.0.0.1:11434/v1',
                ),
                const SizedBox(height: 8),
                _field(
                  'label_embedding_key'.tr(),
                  _apiKeyCtrl,
                  hint: 'Optional',
                  obscure: true,
                ),
                const SizedBox(height: 8),
                _field(
                  'label_embedding_model'.tr(),
                  _modelCtrl,
                  hint: 'text-embedding-3-small',
                ),
                const SizedBox(height: 8),
                _field(
                  'label_max_chunk_tokens'.tr(),
                  _maxChunkTokensCtrl,
                  hint: '8192',
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _isTesting ? null : _testConnection,
                    icon: _isTesting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_tethering, size: 18),
                    label: Text(
                      _isTesting
                          ? 'btn_testing'.tr()
                          : 'btn_test_connection'.tr(),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'vector_search_params'.tr(),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                _field(
                  'label_similarity_threshold'.tr(),
                  _thresholdCtrl,
                  hint: '0.45',
                ),
                const SizedBox(height: 8),
                _field('label_top_k'.tr(), _topKCtrl, hint: '10'),
                const SizedBox(height: 8),
                _field(
                  'label_vector_scan_depth'.tr(),
                  _scanDepthCtrl,
                  hint: '10',
                ),
                const SizedBox(height: 24),
                _buildVectorRebuildSection(rebuildState, staleStats),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: context.cs.primary,
                      foregroundColor: Colors.black,
                    ),
                    onPressed: _save,
                    child: Text('btn_save'.tr()),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    String? hint,
    bool obscure = false,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      maxLines: maxLines,
      style: TextStyle(color: context.cs.onSurface, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 12),
        hintStyle: TextStyle(
          color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
          fontSize: 12,
        ),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Widget _buildVectorRebuildSection(
    VectorRebuildState rebuildState,
    AsyncValue<EmbeddingStaleStats> staleStats,
  ) {
    final running = rebuildState.isRunning || rebuildState.isPaused;
    final stats = switch (staleStats) {
      AsyncData(:final value) => value,
      _ => null,
    };
    final staleCount = stats?.stale ?? 0;
    final totalCount = stats?.total ?? 0;
    final staleSources =
        stats?.bySource.entries
            .map((MapEntry<String, int> e) => '${e.key}: ${e.value}')
            .join(' • ') ??
        '';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Vector rebuilds',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: context.cs.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Rebuild MemoryBook, Lorebook, and raw chat vectors after embedding model or dimensionality changes.',
            style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: staleCount > 0
                  ? context.cs.errorContainer.withValues(alpha: 0.35)
                  : Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: staleCount > 0
                    ? context.cs.error.withValues(alpha: 0.35)
                    : Colors.white.withValues(alpha: 0.08),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  staleStats.isLoading
                      ? 'Checking vector metadata...'
                      : staleCount > 0
                      ? '$staleCount of $totalCount vectors may be stale'
                      : '$totalCount vectors match the current embedding config',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: staleCount > 0
                        ? context.cs.error
                        : context.cs.onSurface,
                  ),
                ),
                if (staleSources.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    staleSources,
                    style: TextStyle(
                      fontSize: 11,
                      color: context.cs.onSurfaceVariant,
                    ),
                  ),
                ],
                if ((stats?.missingMetadata ?? 0) > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${stats!.missingMetadata} older rows have no model metadata; force rebuild is recommended.',
                    style: TextStyle(
                      fontSize: 11,
                      color: context.cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              FilterChip(
                label: const Text('MemoryBook'),
                selected: _rebuildMemoryBooks,
                onSelected: running
                    ? null
                    : (v) => setState(() => _rebuildMemoryBooks = v),
              ),
              FilterChip(
                label: const Text('Lorebooks'),
                selected: _rebuildLorebooks,
                onSelected: running
                    ? null
                    : (v) => setState(() => _rebuildLorebooks = v),
              ),
              FilterChip(
                label: const Text('Raw chat'),
                selected: _rebuildRawChat,
                onSelected: running
                    ? null
                    : (v) => setState(() => _rebuildRawChat = v),
              ),
              FilterChip(
                label: const Text('Force'),
                selected: _forceReindex,
                onSelected: running
                    ? null
                    : (v) => setState(() => _forceReindex = v),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _field(
                  'Vectors per minute',
                  _vectorsPerMinuteCtrl,
                  hint: '30',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: _field('Batch size', _batchSizeCtrl, hint: '10')),
            ],
          ),
          if (running ||
              rebuildState.status == VectorRebuildStatus.completed ||
              rebuildState.status == VectorRebuildStatus.error) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: rebuildState.progress.clamp(0, 1)),
            const SizedBox(height: 8),
            Text(
              '${rebuildState.current}/${rebuildState.total} • indexed ${rebuildState.indexed} • skipped ${rebuildState.skipped} • failed ${rebuildState.failed}',
              style: TextStyle(
                fontSize: 12,
                color: context.cs.onSurfaceVariant,
              ),
            ),
            if (rebuildState.currentLabel.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                rebuildState.currentLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
            ],
            if (rebuildState.message.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                rebuildState.message,
                style: TextStyle(
                  fontSize: 12,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
            ],
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: running ? null : _startVectorRebuild,
                  icon: const Icon(Icons.sync, size: 18),
                  label: const Text('Rebuild selected'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.outlined(
                tooltip: rebuildState.isPaused ? 'Resume' : 'Pause',
                onPressed: running
                    ? () {
                        final ctrl = ref.read(
                          vectorRebuildControllerProvider.notifier,
                        );
                        rebuildState.isPaused ? ctrl.resume() : ctrl.pause();
                      }
                    : null,
                icon: Icon(
                  rebuildState.isPaused ? Icons.play_arrow : Icons.pause,
                ),
              ),
              const SizedBox(width: 8),
              IconButton.outlined(
                tooltip: 'Cancel',
                onPressed: running
                    ? ref.read(vectorRebuildControllerProvider.notifier).cancel
                    : null,
                icon: const Icon(Icons.stop),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SearchModeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SearchModeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? context.cs.primary
        : Colors.white.withValues(alpha: 0.1);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? context.cs.primary.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? context.cs.primary : context.cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
