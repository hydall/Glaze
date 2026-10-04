import 'package:flutter/services.dart';

/// Channel to [MediaScannerConnection] on the Android side.
const _channel = MethodChannel('app.glaze.flutter/media_store');

/// Tells Android's media database about a file Glaze just wrote into public
/// Downloads.
///
/// The system file picker reaches the same folder two ways and only one of them
/// walks the filesystem. Opening it from the device root goes through
/// `ExternalStorageProvider`, which lists real directories and sees everything.
/// The "Downloads" shortcut goes through `DownloadsProvider`, which lists rows
/// out of `MediaStore` — so a file written with plain file IO, as every export
/// here is, exists on disk and is invisible under that shortcut. That is the
/// reported bug: a backup had to be picked by navigating from the device root.
///
/// Scanning inserts the row. Where the platform already indexed the file on its
/// own (Android 11+ routes shared-storage writes through MediaProvider's FUSE
/// layer) the scan is a no-op, so this is safe to call unconditionally.
///
/// Never throws: the export has already succeeded by the time this runs, and an
/// unregistered file is worth less than a failed export. Android-only — every
/// other platform answers `notImplemented`, which is swallowed the same way.
Future<void> registerWithMediaStore(String path) async {
  if (path.isEmpty) return;
  try {
    await _channel.invokeMethod<void>('scanFile', {'path': path});
  } catch (_) {
    // Missing handler, refused path, no MediaProvider: nothing to do about it.
  }
}
