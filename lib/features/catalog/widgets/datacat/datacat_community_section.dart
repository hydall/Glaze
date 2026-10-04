import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glaze_action_button.dart';
import '../../../../shared/widgets/glaze_text_field.dart';
import '../../../../shared/widgets/glaze_toast.dart';
import '../../../../core/utils/error_format.dart';
import '../../catalog_models.dart';
import '../../datacat_account_provider.dart';
import '../../services/datacat/datacat_community.dart';
import '../../services/datacat/datacat_models.dart';
import '../catalog_comments_section.dart';
import 'datacat_account_sheet.dart';

/// What a community section needs to address one character.
///
/// Just the id: the community endpoints take no source kind, because a
/// character id is already unique within DataCat's own index.
class DatacatCommunityArgs {
  final String characterId;

  const DatacatCommunityArgs({required this.characterId});
}

/// Kudos and comments for a DataCat character, folded into the preview's Info
/// tab.
///
/// Owns its own loading, unlike the JanitorAI comments the host screen pages:
/// this one also writes, and the write path needs the account state, the
/// composer and the kudos picker to move together. Reading works signed out;
/// only the two buttons need a linked account, and they say so where they are
/// rather than sending the user to settings to find out.
class DatacatCommunitySection extends ConsumerStatefulWidget {
  final DatacatCommunityArgs args;

  const DatacatCommunitySection({super.key, required this.args});

  @override
  ConsumerState<DatacatCommunitySection> createState() =>
      _DatacatCommunitySectionState();
}

class _DatacatCommunitySectionState
    extends ConsumerState<DatacatCommunitySection> {
  final _comments = <CatalogComment>[];
  final _composer = TextEditingController();

  DatacatCommunity? _community;
  Object? _error;
  bool _loading = false;
  bool _hasMore = true;
  bool _posting = false;
  int _nextOffset = 0;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  /// Reads the next page.
  ///
  /// Paged by how many comments are already on screen, not by the server's
  /// `nextOffset`. The contract calls that cursor authoritative, and for
  /// listings it is — but the comment thread's is not: it was measured
  /// reporting 3 on a single-comment thread, never null even when `hasMore` is
  /// false, and the echoed `offset` does not match the one that was asked for.
  /// `hasMore` is the part that behaves, so it alone decides whether to ask
  /// again.
  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final community = await datacatFetchCommunity(
        widget.args.characterId,
        offset: _nextOffset,
      );
      if (!mounted) return;
      setState(() {
        _community = community;
        _comments.addAll(community.comments.map(datacatComment));
        _hasMore = community.paging.hasMore;
        _nextOffset = _comments.length;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// Replaces the thread with a freshly-read first page.
  void _applyFirstPage(DatacatCommunity community) {
    setState(() {
      _community = community;
      _comments
        ..clear()
        ..addAll(community.comments.map(datacatComment));
      _hasMore = community.paging.hasMore;
      _nextOffset = _comments.length;
    });
  }

  /// Whether this viewer may post. Two things have to be true: DataCat says the
  /// character accepts interaction, and an account with the write scope is
  /// linked to this installation.
  bool get _canWrite =>
      (_community?.canInteract ?? false) &&
      ref.watch(datacatAccountProvider).canWrite;

  Future<bool> _ensureLinked() async {
    if (ref.read(datacatAccountProvider).linked) return true;
    final linked = await showDatacatLinkSheet(context);
    return linked;
  }

  Future<void> _sendKudos(DatacatKudosOption option) async {
    if (!await _ensureLinked() || !mounted) return;
    try {
      final community = await datacatSendKudos(
        widget.args.characterId,
        giftKey: option.giftKey,
      );
      if (!mounted) return;
      GlazeToast.show(context, 'datacat_kudos_sent'.tr());
      // The write answers with the refreshed thread, so the new count is the
      // server's rather than one guessed locally — and no second read is made.
      setState(() => _community = community);
    } catch (e) {
      if (!mounted) return;
      GlazeToast.show(context, formatError(e));
    }
  }

  Future<void> _postComment() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _posting) return;
    if (text.length > datacatCommentMaxLength) {
      GlazeToast.show(context, 'datacat_comment_too_long'.tr());
      return;
    }
    if (!await _ensureLinked() || !mounted) return;

    setState(() => _posting = true);
    try {
      final community = await datacatPostComment(
        widget.args.characterId,
        body: text,
      );
      if (!mounted) return;
      _composer.clear();
      // A posted comment belongs at the top of a list read from the start, so
      // the thread is re-read rather than appended to.
      _applyFirstPage(community);
    } catch (e) {
      if (!mounted) return;
      GlazeToast.show(context, formatError(e));
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final community = _community;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (community != null && community.kudosOptions.isNotEmpty)
          _KudosRow(
            total: community.kudosTotal,
            options: community.kudosOptions,
            enabled: _canWrite || !ref.watch(datacatAccountProvider).linked,
            onSend: _sendKudos,
          ),
        if (community != null && community.canInteract) _composerRow(),
        CatalogCommentsView(
          comments: _comments,
          loading: _loading,
          hasMore: _hasMore,
          error: _error,
          onRetry: _loadMore,
        ),
        if (_hasMore && !_loading && _comments.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: GlazeActionButton(
              icon: Icons.expand_more_rounded,
              label: 'catalog_load_more'.tr(),
              expand: true,
              onTap: _loadMore,
            ),
          ),
      ],
    );
  }

  Widget _composerRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlazeTextField(
            controller: _composer,
            hint: 'datacat_comment_hint'.tr(),
            maxLines: 3,
          ),
          const SizedBox(height: 8),
          GlazeActionButton(
            icon: Icons.send_rounded,
            label: ref.watch(datacatAccountProvider).linked
                ? 'datacat_comment_send'.tr()
                : 'datacat_link_to_post'.tr(),
            tone: GlazeActionTone.primary,
            busy: _posting,
            onTap: _postComment,
          ),
        ],
      ),
    );
  }
}

/// The kudos total and the replies a viewer can pick from.
class _KudosRow extends StatelessWidget {
  final int total;
  final List<DatacatKudosOption> options;
  final bool enabled;
  final void Function(DatacatKudosOption option) onSend;

  const _KudosRow({
    required this.total,
    required this.options,
    required this.enabled,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'datacat_kudos_total'.tr(namedArgs: {'count': '$total'}),
            style: TextStyle(
              fontSize: 12,
              color: context.cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in options)
                GlazeActionButton(
                  icon: Icons.favorite_border_rounded,
                  label: option.emoji == null
                      ? '${option.label} ${option.count}'
                      : '${option.emoji} ${option.label} ${option.count}',
                  onTap: enabled ? () => onSend(option) : null,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
