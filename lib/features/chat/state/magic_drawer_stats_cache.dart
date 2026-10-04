import 'package:flutter_riverpod/legacy.dart';

import '../widgets/magic_drawer_models.dart';

typedef MagicDrawerStatsCacheKey = ({String charId, String? sessionId});

/// Last computed Quick Access stats, per character session.
///
/// The drawer panel is unmounted the moment the drawer closes (see
/// `renderDrawer` in `chat_screen.dart`), so its widget state cannot survive
/// between opens and every open would otherwise recompute the card subtitles
/// from scratch behind a blocking spinner. These providers keep the previous
/// snapshot alive at app scope: an open paints it immediately and the real
/// recomputation lands on top a moment later (stale-while-revalidate).
final magicDrawerStatsCacheProvider =
    StateProvider.family<MagicDrawerStats?, MagicDrawerStatsCacheKey>(
      (ref, _) => null,
    );

/// Last resolved card layout (order + deleted ids). Not per-character — the
/// layout is a single app-wide preference.
final magicDrawerLayoutCacheProvider =
    StateProvider<({List<String> itemIds, Set<String> deletedIds})?>(
      (ref) => null,
    );
