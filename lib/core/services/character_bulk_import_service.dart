import 'dart:io';
import 'dart:typed_data';

import 'character_import_persistence_coordinator.dart';
import 'character_import_write_buffer.dart';
import 'character_importer.dart';

/// Produces the bytes of one queued card. Called exactly once, when that card's
/// turn comes; returning null marks the source as unavailable.
typedef CharacterImportBytesLoader = Future<Uint8List?> Function();

/// One item queued for a mass import.
///
/// Bytes are **not** held here. Either [path] points at a file the runner reads
/// when it gets to it, or [openBytes] materialises them on demand — so a
/// 500-card selection never keeps more than one card in memory. The old flow
/// asked the file picker for `withData: true`, which loaded every picked file
/// into RAM up front and killed the process before the first card was parsed.
class CharacterImportSource {
  /// File name, including extension — it selects the parser (png / charx /
  /// json), so it must keep the original suffix.
  final String name;

  /// Path to read the card from, when the platform gives one.
  final String? path;

  /// Fallback loader for sources without a file path (photo-library assets).
  final CharacterImportBytesLoader? openBytes;

  const CharacterImportSource({required this.name, this.path, this.openBytes})
    : assert(
        path != null || openBytes != null,
        'a source needs either a path or a byte loader',
      );
}

/// Snapshot of a running mass import, emitted before each card is processed and
/// once more when the run ends.
class CharacterBulkImportProgress {
  /// Cards fully processed (imported or failed).
  final int completed;
  final int total;
  final int imported;
  final int failed;

  /// Name of the card being processed, empty on the final emission.
  final String currentName;

  const CharacterBulkImportProgress({
    required this.completed,
    required this.total,
    required this.imported,
    required this.failed,
    this.currentName = '',
  });

  /// 0..1, or null when there is nothing to import.
  double? get fraction => total == 0 ? null : completed / total;
}

class CharacterBulkImportReport {
  final int imported;
  final int failed;

  /// Last failure, already prefixed with the file it came from.
  final String? lastError;

  /// True when the caller cancelled before every source was processed.
  final bool cancelled;

  const CharacterBulkImportReport({
    required this.imported,
    required this.failed,
    this.lastError,
    this.cancelled = false,
  });
}

/// Imports character cards **one at a time**.
///
/// Every card is read, parsed, persisted and released before the next one is
/// touched, and the runner hands the event loop back between cards so the UI
/// keeps painting (and the cancel button keeps responding) during a long run.
/// Writes go through a [CharacterImportWriteBuffer], so the database sees one
/// transaction per chunk instead of one per card.
class CharacterBulkImportService {
  final CharacterImporter importer;
  final CharacterImportWriteBuffer buffer;
  final CharacterImportPersistenceCoordinator _persistence;
  final Future<void> Function() _yieldToEventLoop;

  CharacterBulkImportService({
    required this.importer,
    required this.buffer,
    Future<void> Function()? yieldToEventLoop,
  }) : _persistence = CharacterImportPersistenceCoordinator(
         persistCharacter: buffer.addCharacter,
         persistLorebook: buffer.addLorebook,
         persistGalleryImage: buffer.addGalleryImage,
       ),
       _yieldToEventLoop = yieldToEventLoop ?? _tick;

  static Future<void> _tick() => Future<void>.delayed(Duration.zero);

  Future<CharacterBulkImportReport> run(
    List<CharacterImportSource> sources, {
    void Function(CharacterBulkImportProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    var imported = 0;
    var failed = 0;
    var cancelled = false;
    String? lastError;

    void emit(int completed, String currentName) {
      onProgress?.call(
        CharacterBulkImportProgress(
          completed: completed,
          total: sources.length,
          imported: imported,
          failed: failed,
          currentName: currentName,
        ),
      );
    }

    for (var i = 0; i < sources.length; i++) {
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }
      final source = sources[i];
      emit(i, source.name);

      try {
        final result = await _read(source);
        final persisted = await _persistence.persist(result);
        if (persisted case CharacterImportPersistenceFailure()) {
          persisted.rethrowError();
        }
        imported++;
      } catch (error) {
        failed++;
        lastError = 'Failed to import ${source.name}: $error';
      }

      // Give the frame back between cards: this loop runs on the UI isolate,
      // and without a yield a few hundred cards block it end to end (no repaint,
      // no cancel, and on Android an ANR).
      await _yieldToEventLoop();
    }

    try {
      await buffer.flush();
    } catch (error) {
      // The chunk never landed — count its cards as failures instead of
      // reporting an import that is not in the database.
      final lost = buffer.pendingCharacterCount;
      imported -= lost;
      failed += lost;
      lastError = 'Failed to save the last batch: $error';
    }

    emit(imported + failed, '');
    return CharacterBulkImportReport(
      imported: imported,
      failed: failed,
      lastError: lastError,
      cancelled: cancelled,
    );
  }

  /// Materialises exactly one card. The bytes stay local to this call, so they
  /// become garbage as soon as the parser is done with them.
  Future<CharacterImportResult> _read(CharacterImportSource source) async {
    final path = source.path;
    if (path != null && path.isNotEmpty) {
      final bytes = await File(path).readAsBytes();
      return importer.importFromBytes(bytes, source.name);
    }
    final bytes = await source.openBytes!();
    if (bytes == null) {
      throw StateError('the file could not be read');
    }
    return importer.importFromBytes(bytes, source.name);
  }
}
