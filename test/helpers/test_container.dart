import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/navigation/router.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';

/// Builds a fresh [ProviderContainer] wired with an in-memory database and
/// a brand-new [GoRouter] instance that owns its own [GlobalKey].
///
/// The production [routerProvider] uses a module-level [rootNavigatorKey] —
/// a GlobalKey can only be attached to one widget at a time, so reusing it
/// across tests causes GoRouter to silently fail its initial navigation in
/// every test after the first. We sidestep that by overriding [routerProvider]
/// with a fresh router (and a fresh key) per test.
ProviderContainer makeContainer(AppDatabase db) {
  final navKey = GlobalKey<NavigatorState>();
  final router = buildRouter(navKey, isForceMobile: () => true);
  return ProviderContainer(
    overrides: [
      appDbProvider.overrideWithValue(db),
      routerProvider.overrideWithValue(router),
    ],
  );
}
