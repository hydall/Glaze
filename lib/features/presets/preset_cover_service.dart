import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/image_storage_service.dart';
import '../../core/state/db_provider.dart';
import '../../core/utils/time_helpers.dart';
import 'preset_image.dart';

/// Picking and clearing a preset's cover image, shared by the preset editor
/// (which holds the path in unsaved state) and the preset list's "⋯" menu
/// (which writes straight through to the repository).

/// Prompts for an image, stores it under [presetId] and returns the new
/// relative path — or null when the user cancelled or the file was unreadable.
///
/// The caller owns persistence: it decides when the returned path reaches the
/// [Preset]. Dropping the replaced file is left to [deleteStoredPresetCover],
/// so a caller whose save can still fail keeps the old file until it commits.
Future<String?> pickPresetCover(WidgetRef ref, String presetId) async {
  FilePickerResult? result;
  try {
    result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
  } catch (_) {}
  if (result == null || result.files.isEmpty) return null;

  final picked = result.files.first;
  Uint8List? bytes = picked.bytes;
  if ((bytes == null || bytes.isEmpty) &&
      picked.path != null &&
      picked.path!.isNotEmpty) {
    bytes = await File(picked.path!).readAsBytes();
  }
  if (bytes == null || bytes.isEmpty) return null;

  final storage = await ref.read(imageStorageProvider.future);
  final storageId = presetImageStorageId(presetId, currentTimestampSeconds());
  // saveAvatar always writes `<id>.png` (plus a thumbnail).
  await storage.saveAvatar(storageId, bytes);
  return presetImageRelativePath(storageId, 'png');
}

/// Drops the file a replaced/removed cover left behind. Bundled asset covers
/// (a cloned featured preset) have no file to delete.
Future<void> deleteStoredPresetCover(
  ImageStorageService storage,
  String? path,
) async {
  final storageId = presetImageStorageIdOf(path);
  if (storageId == null) return;
  try {
    await storage.deleteAvatar(storageId);
  } catch (_) {}
}
