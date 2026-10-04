/// Pure path helpers for preset cover images.
///
/// Kept free of Flutter imports so the cloud-sync layer can share them with the
/// UI (`features/presets/preset_image.dart` re-exports these).
///
/// A stored cover path is deliberately **relative** to the Glaze data dir
/// (`avatars/preset_<id>_<version>.png`) rather than absolute: presets travel
/// between devices as one JSON blob, and an absolute path from another device's
/// data dir would differ on every machine — making the entry hash flip back and
/// forth on each sync. The `<version>` segment changes whenever the user picks
/// a new image, so replacing a cover changes the preset JSON (and therefore its
/// manifest hash), which is what makes the replacement propagate at all.
library;

/// True when [path] points at a bundled asset instead of a file on disk.
/// Featured covers live in the asset bundle and stay there when a preset is
/// cloned, so both kinds of path can end up in `Preset.imagePath`.
bool isPresetAssetImage(String? path) =>
    path != null && path.startsWith('assets/');

/// Storage id of a preset cover — the file name (without extension) it gets
/// under `avatars/`, alongside the character/persona avatars.
String presetImageStorageId(String presetId, int version) =>
    'preset_${presetId}_$version';

/// Path stored on the preset, relative to the Glaze data dir.
String presetImageRelativePath(String storageId, String ext) =>
    'avatars/$storageId.$ext';

/// Storage id encoded in a stored cover [path], or null when there is none
/// (no cover, or a bundled asset). Used to delete the file a replaced cover
/// leaves behind.
String? presetImageStorageIdOf(String? path) {
  if (path == null || path.isEmpty || isPresetAssetImage(path)) return null;
  final name = path.split(RegExp(r'[/\\]')).last;
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  return base.isEmpty ? null : base;
}
