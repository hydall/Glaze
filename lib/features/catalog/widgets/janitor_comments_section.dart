import 'package:cached_network_image/cached_network_image.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/utils/time_formatter.dart';
import '../services/janitor_provider.dart';

const _kSurface = Color(0x0DFFFFFF);
const _kBorderLine = Color(0x14FFFFFF);
const _kText75 = Color(0xBFFFFFFF);
const _kText50 = Color(0x80FFFFFF);
const _kText35 = Color(0x59FFFFFF);

/// Renders a JanitorAI character's comments as a plain [Column] of cards plus a
/// footer that reflects the current paging state. It owns no fetching: the host
/// (`CharacterDetailScreen`) loads pages incrementally as its scroll view nears
/// the bottom and passes the accumulated [comments] down. The footer shows a
/// spinner while [loading], a retry affordance on [error], an end marker once
/// [hasMore] is false, or an empty-state when nothing was found.
class JanitorCommentsView extends StatelessWidget {
  final List<JanitorReview> comments;
  final bool loading;
  final bool hasMore;
  final Object? error;
  final VoidCallback onRetry;

  const JanitorCommentsView({
    super.key,
    required this.comments,
    required this.loading,
    required this.hasMore,
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final c in comments)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: _CommentCard(review: c),
          ),
        _buildFooter(context),
      ],
    );
  }

  Widget _buildFooter(BuildContext context) {
    // First load (no items yet) shows a centred spinner; subsequent pages show
    // a slim inline spinner under the existing cards.
    if (error != null && comments.isEmpty) {
      return _FooterError(onRetry: onRetry);
    }
    if (loading) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: comments.isEmpty ? 40 : 16),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: context.cs.primary,
            ),
          ),
        ),
      );
    }
    if (error != null) {
      return _FooterError(onRetry: onRetry);
    }
    if (comments.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(40),
        child: Center(
          child: Text(
            'catalog_comments_empty'.tr(),
            style: const TextStyle(color: _kText35),
          ),
        ),
      );
    }
    if (!hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: Text(
            'catalog_end'.tr(),
            style: const TextStyle(color: _kText35, fontSize: 12),
          ),
        ),
      );
    }
    // hasMore but not yet loading: the host triggers the next page on scroll.
    // A short placeholder keeps the scroll extent past the trigger threshold.
    return const SizedBox(height: 24);
  }
}

class _FooterError extends StatelessWidget {
  final VoidCallback onRetry;
  const _FooterError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      child: Column(
        children: [
          Text(
            'catalog_comments_error'.tr(),
            textAlign: TextAlign.center,
            style: const TextStyle(color: _kText50, fontSize: 13),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: onRetry,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
              decoration: BoxDecoration(
                color: context.cs.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'action_retry'.tr(),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CommentCard extends StatelessWidget {
  final JanitorReview review;
  const _CommentCard({required this.review});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: review.isPinned
              ? context.cs.primary.withValues(alpha: 0.28)
              : _kBorderLine,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _Avatar(url: review.avatarUrl, name: review.authorName),
              const SizedBox(width: 10),
              Expanded(child: _buildAuthorLine(context)),
              if (review.isPinned)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(
                    Icons.push_pin_rounded,
                    size: 14,
                    color: context.cs.primary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          SelectableText(
            review.content,
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.5,
              color: _kText75,
            ),
          ),
          const SizedBox(height: 10),
          _buildMetaLine(context),
        ],
      ),
    );
  }

  Widget _buildAuthorLine(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                review.authorName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
            if (review.isVerified)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(
                  Icons.verified_rounded,
                  size: 13,
                  color: context.cs.primary,
                ),
              ),
            if (review.hasPlus)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0x33FFC107),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'PLUS',
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                      color: Color(0xFFFFC107),
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (review.authorUserName.isNotEmpty)
          Text(
            '@${review.authorUserName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: _kText35),
          ),
      ],
    );
  }

  Widget _buildMetaLine(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.favorite_rounded, size: 13, color: _kText50),
        const SizedBox(width: 4),
        Text(
          '${review.likeCount}',
          style: const TextStyle(fontSize: 11.5, color: _kText50),
        ),
        const SizedBox(width: 14),
        const Icon(Icons.mode_comment_outlined, size: 13, color: _kText50),
        const SizedBox(width: 4),
        Text(
          '${review.replyCount}',
          style: const TextStyle(fontSize: 11.5, color: _kText50),
        ),
        const Spacer(),
        if (review.createdAt != null)
          Text(
            formatTimeAgo(review.createdAt!.millisecondsSinceEpoch),
            style: const TextStyle(fontSize: 11, color: _kText35),
          ),
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  final String? url;
  final String name;
  const _Avatar({required this.url, required this.name});

  @override
  Widget build(BuildContext context) {
    const size = 34.0;
    final fallback = _AvatarFallback(name: name, size: size);
    if (url == null || url!.isEmpty) return fallback;
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: url!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}

class _AvatarFallback extends StatelessWidget {
  final String name;
  final double size;
  const _AvatarFallback({required this.name, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: Color(0x147996CE),
        shape: BoxShape.circle,
      ),
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : '?',
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: _kText50,
        ),
      ),
    );
  }
}
