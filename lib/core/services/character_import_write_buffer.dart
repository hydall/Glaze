import '../models/character.dart';
import '../models/lorebook.dart';
import 'character_importer.dart';

typedef WriteImportedCharacters = Future<void> Function(List<Character> batch);
typedef WriteImportedLorebooks = Future<void> Function(List<Lorebook> batch);
typedef WriteImportedGalleryImage =
    Future<void> Function(String characterId, GalleryImageData image);

/// Collects imported rows and writes them to the database in chunks.
///
/// A mass import used to persist every card on its own: one `put` plus one
/// `invalidateSelf()` per file, which re-read and re-decoded the whole — and
/// growing — characters table for each of the hundreds of picked cards. That
/// quadratic work on the UI isolate is what made large imports freeze and then
/// die. Buffering turns it into one transaction and one list refresh per
/// [chunkSize] cards.
///
/// The buffer is deliberately dumb about *what* it writes: it only guarantees
/// ordering (characters before their lorebooks) and that a gallery image is
/// never written before its character row exists — the gallery lives on the
/// character row itself, so an unflushed card would silently lose its images.
class CharacterImportWriteBuffer {
  /// Cards per transaction. Small enough that a crash or a cancel loses little
  /// work and the grid keeps updating while the import runs, large enough that
  /// the per-chunk refresh cost stays negligible.
  static const int defaultChunkSize = 20;

  final WriteImportedCharacters writeCharacters;
  final WriteImportedLorebooks writeLorebooks;
  final WriteImportedGalleryImage writeGalleryImage;
  final int chunkSize;

  final List<Character> _characters = [];
  final List<Lorebook> _lorebooks = [];

  CharacterImportWriteBuffer({
    required this.writeCharacters,
    required this.writeLorebooks,
    required this.writeGalleryImage,
    this.chunkSize = defaultChunkSize,
  }) : assert(chunkSize > 0);

  /// Rows parsed but not yet committed — what a failing [flush] would lose.
  int get pendingCharacterCount => _characters.length;

  Future<void> addCharacter(Character character) async {
    _characters.add(character);
    if (_characters.length >= chunkSize) await flush();
  }

  Future<void> addLorebook(Lorebook lorebook) async {
    _lorebooks.add(lorebook);
    if (_lorebooks.length >= chunkSize) await flush();
  }

  /// Attaches [image] to [characterId]. Flushes first: gallery entries are
  /// stored on the character row, so the row has to exist before the gallery
  /// service can read-modify-write it.
  Future<void> addGalleryImage(
    String characterId,
    GalleryImageData image,
  ) async {
    await flush();
    await writeGalleryImage(characterId, image);
  }

  /// Commits everything buffered so far. Safe to call when empty.
  ///
  /// Buffered rows are dropped only once their write returned, so a failed
  /// flush leaves them pending — the caller can retry, and
  /// [pendingCharacterCount] still tells it how many cards did not land.
  Future<void> flush() async {
    if (_characters.isNotEmpty) {
      await writeCharacters(List<Character>.of(_characters));
      _characters.clear();
    }
    if (_lorebooks.isNotEmpty) {
      await writeLorebooks(List<Lorebook>.of(_lorebooks));
      _lorebooks.clear();
    }
  }
}
