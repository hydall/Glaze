import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/lorebook_embedding_provider.dart';
import '../../shared/shell/desktop/sidebar_sheet_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_action_button.dart';
import '../../shared/widgets/glaze_sheet.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/sheet_view.dart';
import '../settings/api_list_provider.dart';
import 'embedding_connection_editor.dart';
import 'embedding_preset_sheet.dart';
import 'widgets/vector_rebuild_group.dart';
import 'widgets/vector_search_group.dart';

/// Everything about embeddings in one place: the embedding connection (a
/// preset list of its own), how lorebooks use vectors, and rebuilding the
/// stored vectors after the model changed.
///
/// Reached from Tools (`/tools/embeddings`), the chat drawer and every
/// "set up vectors" prompt.
class EmbeddingsScreen extends ConsumerStatefulWidget {
  final bool startExpanded;

  const EmbeddingsScreen({super.key, this.startExpanded = false});

  @override
  ConsumerState<EmbeddingsScreen> createState() => _EmbeddingsScreenState();
}

class _EmbeddingsScreenState extends ConsumerState<EmbeddingsScreen> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Back depends on how the screen is presented: a modal sheet (chat drawer,
  /// vector setup prompts) simply pops; the Tools route returns to Tools, or
  /// closes its desktop sidebar panel.
  void _goBack() {
    if (ModalRoute.of(context) is ModalBottomSheetRoute) {
      Navigator.of(context).maybePop();
    } else {
      closeExpandedToolScreen(context, ref);
    }
  }

  @override
  Widget build(BuildContext context) {
    final presets = ref.watch(embeddingPresetListProvider);
    return SheetView(
      startExpanded: widget.startExpanded,
      showRouteBackground: false,
      title: 'tab_embeddings'.tr(),
      showBack: true,
      onBack: _goBack,
      scrollController: _scrollController,
      body: presets.when(
        loading: () => const Center(child: GlazeSpinner()),
        error: (e, _) => Center(child: Text('${'title_error'.tr()}: $e')),
        data: (list) => list.isEmpty ? _buildEmptyState() : _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    // Lorebook search and rebuilds only mean something once there is a
    // connection to embed with.
    final available = ref.watch(vectorSearchAvailableProvider);
    return ListView(
      controller: _scrollController,
      padding: EdgeInsets.only(
        top:
            MediaQuery.paddingOf(context).top +
            (inSidebarPanel(context) ? 0 : 12),
        bottom: MediaQuery.paddingOf(context).bottom + 16,
      ),
      children: [
        const EmbeddingConnectionEditor(),
        if (available) ...const [VectorSearchGroup(), VectorRebuildGroup()],
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.layers_outlined,
            size: 64,
            color: context.cs.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            'settings_no_embedding_configs'.tr(),
            style: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 15),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          GlazeActionButton(
            icon: Icons.add_rounded,
            label: 'settings_add_embedding_config'.tr(),
            tone: GlazeActionTone.primary,
            onTap: () => EmbeddingPresetActions(
              context: context,
              ref: ref,
              // No editor is open yet, so there is nothing pending to save.
              flushPendingSave: () {},
              cancelPendingSave: () {},
            ).createNew(),
          ),
        ],
      ),
    );
  }
}

/// Opens the Embeddings screen as a modal sheet — from a chat, or from a
/// prompt that found vectors not set up.
Future<void> showEmbeddingsSheet(BuildContext context) {
  return showGlazeSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (_) => const EmbeddingsScreen(),
  );
}
