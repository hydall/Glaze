import 'package:flutter_riverpod/legacy.dart';

/// Bumped whenever a durable memory book changes underneath whoever is looking
/// at it — a manual draft generation finishing, the auto-create stage adding
/// or filling drafts during a chat turn.
///
/// The memory sheet reads its book once when it opens and keeps it in memory,
/// so without this it only ever sees what was in the database at that moment:
/// a generation that landed while the sheet was open stayed invisible, and a
/// later save from the sheet wrote its stale copy back over it.
final memoryBookRevisionProvider = StateProvider<int>((ref) => 0);
