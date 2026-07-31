import 'package:flutter/widgets.dart';

import '../../core/models/preset.dart';
import '../../core/services/featured_presets.dart';
import '../../shared/utils/avatar_image.dart';

/// True when [path] points at a bundled asset instead of a file on disk.
/// Featured covers live in the asset bundle and stay there when a preset is
/// cloned, so both kinds of path can end up in `Preset.imagePath`.
bool isPresetAssetImage(String? path) =>
    path != null && path.startsWith('assets/');

/// Cover image of [preset], or null when it has none.
///
/// Resolution order:
///   1. a user-picked image stored on disk (thumbnail preferred),
///   2. an `assets/...` cover carried in `imagePath` (a cloned featured preset),
///   3. the bundled cover of a featured preset, keyed by its fixed id.
ImageProvider? presetCoverImage(Preset preset) =>
    resolvePresetCoverImage(presetId: preset.id, imagePath: preset.imagePath);

/// [presetCoverImage] for editor state that has no persisted [Preset] yet.
ImageProvider? resolvePresetCoverImage({
  required String presetId,
  String? imagePath,
}) {
  if (imagePath != null && imagePath.isNotEmpty) {
    if (isPresetAssetImage(imagePath)) return AssetImage(imagePath);
    return glazeAvatarImage(imagePath);
  }
  final asset = featuredPresetImageAsset(presetId);
  return asset != null ? AssetImage(asset) : null;
}

/// Storage id used for a preset's user-picked cover, so the file lands next to
/// the character/persona avatars (and gets a thumbnail) instead of in a
/// preset-specific folder.
String presetImageStorageId(String presetId) => 'preset_$presetId';
