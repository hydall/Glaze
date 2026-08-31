import 'package:flutter_riverpod/legacy.dart';

/// Absolute paths of character-card files dropped onto the window, waiting for
/// the character list to pick them up and run the bulk importer.
///
/// The drop target lives in the desktop shell, above the router, while the
/// import machinery (progress dialog, cancel, per-card persistence) lives in
/// [CharacterListScreen]. Handing the paths over through a provider keeps that
/// machinery in one place instead of duplicating it in the shell.
final droppedCharacterFilesProvider = StateProvider<List<String>>((ref) => []);

/// Extensions the importer understands; anything else in a multi-file drop is
/// ignored rather than failing the whole batch.
const kImportableCardExtensions = {'png', 'json', 'charx', 'zip'};

List<String> filterImportableCardPaths(Iterable<String> paths) =>
    paths.where((path) {
      final dot = path.lastIndexOf('.');
      if (dot < 0) return false;
      return kImportableCardExtensions.contains(
        path.substring(dot + 1).toLowerCase(),
      );
    }).toList();
