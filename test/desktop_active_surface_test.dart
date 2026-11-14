import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_active_surface_provider.dart';

void main() {
  late ProviderContainer container;
  DesktopActiveSurfaceNotifier surfaces() =>
      container.read(desktopActiveSurfaceProvider.notifier);
  bool active(Object surface) =>
      container.read(desktopSurfaceActiveProvider(surface));

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  test('the main window is active until another window opens', () {
    expect(active(kDesktopMainSurface), isTrue);

    surfaces().activate(desktopWindowSurface(1));

    expect(active(desktopWindowSurface(1)), isTrue);
    expect(active(kDesktopMainSurface), isFalse);
  });

  test('releasing the active window hands back to the one used before', () {
    surfaces()
      ..activate(desktopWindowSurface(1))
      ..activate(kDesktopGlossarySurface);

    surfaces().release(kDesktopGlossarySurface);
    expect(active(desktopWindowSurface(1)), isTrue);

    surfaces().release(desktopWindowSurface(1));
    expect(active(kDesktopMainSurface), isTrue);
  });

  test('releasing a background window keeps the active one', () {
    surfaces()
      ..activate(desktopWindowSurface(1))
      ..activate(desktopWindowSurface(2));

    surfaces().release(desktopWindowSurface(1));

    expect(active(desktopWindowSurface(2)), isTrue);
    expect(container.read(desktopActiveSurfaceProvider), [
      desktopWindowSurface(2),
      kDesktopMainSurface,
    ]);
  });

  test('the main window is never released', () {
    surfaces().release(kDesktopMainSurface);

    expect(container.read(desktopActiveSurfaceProvider), [
      kDesktopMainSurface,
    ]);
  });
}
