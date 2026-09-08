import 'dart:io';

import 'package:flutter/widgets.dart';

import '../../core/utils/platform_paths.dart';

/// Memoized `avatarPath -> thumbnail path` results. [resolveGlazeThumbnailPath]
/// does a synchronous `File.existsSync()`; without this cache that stat runs
/// for every row on every rebuild during a scroll, which janks. Only positive
/// thumbnail hits are cached — a fallback to the source avatar is re-checked
/// next time, since a thumbnail may still be generated (backfilled) later.
final Map<String, String> _resolvedThumbCache = {};

String? _resolveAvatarThumb(String? avatarPath) {
  if (avatarPath == null || avatarPath.isEmpty) return null;
  final cached = _resolvedThumbCache[avatarPath];
  if (cached != null) {
    if (File(cached).existsSync()) return cached;
    _resolvedThumbCache.remove(avatarPath);
  }
  final resolved = resolveGlazeThumbnailPath(avatarPath);
  if (resolved == null || resolved.isEmpty) return null;
  final sep = Platform.pathSeparator;
  if (resolved.contains('${sep}thumbnails$sep')) {
    _resolvedThumbCache[avatarPath] = resolved;
  }
  return resolved;
}

/// [ImageProvider] for a stored avatar path, preferring the 512px thumbnail.
///
/// Returns a plain [FileImage] (no [ResizeImage] wrapper) on purpose: avatar
/// cache invalidation across the app evicts via `FileImage(File(path)).evict()`,
/// which only matches the bare-[FileImage] cache key. Wrapping in [ResizeImage]
/// would use a different key and leave edited avatars stale.
///
/// [glazeAvatarImage] and [precacheGlazeAvatar] build the same provider (hence
/// the same cache key) for a given avatar, so an avatar warmed via
/// [precacheGlazeAvatar] renders instantly instead of decoding — and popping
/// in — the first time its row scrolls into view.
ImageProvider? glazeAvatarImage(String? avatarPath) {
  final path = _resolveAvatarThumb(avatarPath);
  if (path == null) return null;
  return FileImage(File(path));
}

/// Warms the image cache for [avatarPath] so its row renders without a decode
/// delay once it scrolls into view. No-op when there is no avatar. Must be
/// called with a mounted [context] (typically from a post-frame callback).
void precacheGlazeAvatar(BuildContext context, String? avatarPath) {
  final provider = glazeAvatarImage(avatarPath);
  if (provider != null) precacheImage(provider, context);
}
