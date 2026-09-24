import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog_models.dart';

/// The five third-party sources the user can enable/disable from the
/// "Third-Party providers" screen: the four catalog browse providers plus
/// Saucepan (a companion-extraction account, not a browse source). Disabling
/// one hides it from the catalog provider picker and hides its settings block
/// on the screen.
enum ThirdPartyProvider { janitor, janny, datacat, chub, saucepan }

extension ThirdPartyProviderX on ThirdPartyProvider {
  /// The matching catalog browse provider, or null for Saucepan (which has no
  /// catalog feed — it only backs local companion extraction).
  CatalogProvider? get catalogProvider => switch (this) {
    ThirdPartyProvider.janitor => CatalogProvider.janitor,
    ThirdPartyProvider.janny => CatalogProvider.janny,
    ThirdPartyProvider.datacat => CatalogProvider.datacat,
    ThirdPartyProvider.chub => CatalogProvider.chub,
    ThirdPartyProvider.saucepan => null,
  };
}

/// Reverse of [ThirdPartyProviderX.catalogProvider]: every browse provider has
/// exactly one third-party counterpart (there is no Saucepan catalog feed).
extension CatalogProviderX on CatalogProvider {
  ThirdPartyProvider get thirdPartyProvider => switch (this) {
    CatalogProvider.janitor => ThirdPartyProvider.janitor,
    CatalogProvider.janny => ThirdPartyProvider.janny,
    CatalogProvider.datacat => ThirdPartyProvider.datacat,
    CatalogProvider.chub => ThirdPartyProvider.chub,
  };
}

/// Holds the set of DISABLED third-party providers (a provider absent from the
/// set is enabled). Persisted so the choice survives launches; defaults to
/// janitor enabled (all others disabled).
class ThirdPartyProvidersNotifier extends Notifier<Set<ThirdPartyProvider>> {
  static const _key = 'gz_disabled_third_party_providers';

  @override
  Set<ThirdPartyProvider> build() {
    _load();
    return {ThirdPartyProvider.janny, ThirdPartyProvider.datacat, ThirdPartyProvider.chub, ThirdPartyProvider.saucepan};
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key);
    if (raw == null) return;
    final disabled = <ThirdPartyProvider>{};
    for (final name in raw) {
      final match = ThirdPartyProvider.values.firstWhereOrNull(
        (p) => p.name == name,
      );
      if (match != null) disabled.add(match);
    }
    state = disabled;
  }

  bool isEnabled(ThirdPartyProvider p) => !state.contains(p);

  Future<void> setEnabled(ThirdPartyProvider p, bool enabled) async {
    final next = {...state};
    if (enabled) {
      if (!next.remove(p)) return; // already enabled
    } else {
      if (!next.add(p)) return; // already disabled
    }
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, next.map((p) => p.name).toList());
  }
}

final thirdPartyProvidersProvider =
    NotifierProvider<ThirdPartyProvidersNotifier, Set<ThirdPartyProvider>>(
      ThirdPartyProvidersNotifier.new,
    );

/// Master on/off switch for the whole catalog (the Discover tab). Independent
/// of the per-provider toggles: turning this off hides the catalog even while
/// individual providers stay enabled. Persisted; defaults to on.
class CatalogEnabledNotifier extends Notifier<bool> {
  static const _key = 'gz_catalog_enabled';

  @override
  bool build() {
    _load();
    return true;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool(_key);
    if (v != null && v != state) state = v;
  }

  Future<void> setEnabled(bool enabled) async {
    if (enabled == state) return;
    state = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, enabled);
  }
}

final catalogMasterEnabledProvider =
    NotifierProvider<CatalogEnabledNotifier, bool>(CatalogEnabledNotifier.new);

/// The catalog browse providers currently enabled, in enum order. May be empty
/// when the user disabled all four — callers must handle that (the catalog is
/// hidden entirely in that case, see [catalogVisibleProvider]).
final enabledCatalogProvidersProvider = Provider<List<CatalogProvider>>((ref) {
  final disabled = ref.watch(thirdPartyProvidersProvider);
  final enabled = <CatalogProvider>[];
  for (final tp in ThirdPartyProvider.values) {
    final cp = tp.catalogProvider;
    if (cp != null && !disabled.contains(tp)) enabled.add(cp);
  }
  return enabled;
});

/// Whether the Discover/catalog tab should be shown at all: the master toggle
/// is on AND at least one catalog browse provider is enabled. When false the
/// character screen drops the My/Discover segmented control and shows only
/// "My Characters".
final catalogVisibleProvider = Provider<bool>((ref) {
  if (!ref.watch(catalogMasterEnabledProvider)) return false;
  return ref.watch(enabledCatalogProvidersProvider).isNotEmpty;
});

/// Whether adult catalog images are blurred. Purely a display choice: it never
/// removes a character from the results, it draws the card image and the images
/// inside the preview's bio through a blur instead, for every provider alike.
/// Persisted so the choice survives launches; off by default.
class BlurNsfwImagesNotifier extends Notifier<bool> {
  static const _key = 'gz_blur_nsfw_images';

  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getBool(_key);
    if (stored != null && stored != state) state = stored;
  }

  Future<void> setBlurring(bool blur) async {
    if (blur == state) return;
    state = blur;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, blur);
  }
}

final blurNsfwImagesProvider =
    NotifierProvider<BlurNsfwImagesNotifier, bool>(
      BlurNsfwImagesNotifier.new,
    );

/// Whether [item]'s images should render blurred: the global blur setting is on
/// and the row is adult (NSFW or NSFL). The provider does not matter — the
/// setting covers every catalog source.
bool shouldBlurNsfwItem(CatalogItem item) => item.nsfw || item.nsfl;
