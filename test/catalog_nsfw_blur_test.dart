import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/features/catalog/catalog_models.dart';
import 'package:glaze_flutter/features/catalog/third_party_providers_provider.dart';
import 'package:glaze_flutter/shared/widgets/nsfw_blur.dart';

/// The adult-image blur is a display choice: it must never be confused with a
/// filter that removes characters, so [shouldBlurNsfwItem] is driven purely by
/// the row's own NSFW/NSFL flags.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('adult rows blur; safe rows do not', () {
    const nsfw = CatalogItem(id: 'a', name: 'a', nsfw: true);
    const nsfl = CatalogItem(id: 'b', name: 'b', nsfl: true);
    const sfw = CatalogItem(id: 'c', name: 'c');

    expect(shouldBlurNsfwItem(nsfw), isTrue);
    expect(shouldBlurNsfwItem(nsfl), isTrue);
    expect(shouldBlurNsfwItem(sfw), isFalse);
  });

  test('defaults to off and persists the choice', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(blurNsfwImagesProvider), isFalse);

    await container.read(blurNsfwImagesProvider.notifier).setBlurring(true);
    expect(container.read(blurNsfwImagesProvider), isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('gz_blur_nsfw_images'), isTrue);
  });

  test('restores a stored choice', () async {
    SharedPreferences.setMockInitialValues({'gz_blur_nsfw_images': true});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(blurNsfwImagesProvider);
    await pumpEventQueue();
    expect(container.read(blurNsfwImagesProvider), isTrue);
  });

  testWidgets('NsfwBlur only filters while enabled', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: NsfwBlur(enabled: false, child: SizedBox()),
      ),
    );
    expect(find.byType(ImageFiltered), findsNothing);

    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: NsfwBlur(enabled: true, child: SizedBox()),
      ),
    );
    expect(find.byType(ImageFiltered), findsOneWidget);
  });
}
