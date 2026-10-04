import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/generation_notification_service.dart';
import 'package:glaze_flutter/core/services/notifications/message_notification_presenter.dart';
import 'package:glaze_flutter/features/onboarding/onboarding_models.dart';

/// The notification permission used to be asked for from
/// `MessageNotificationPresenter.ensureInitialized`, which runs at startup —
/// so the OS dialog was the first thing a new reader saw, with nothing on
/// screen to say what it was for. It is an onboarding slide now, and these
/// cover the two halves of that move: the slide exists where there is a
/// permission to ask for, and nowhere else.
void main() {
  test('the notifications slide sits between the layout and the last slide', () {
    final slides = buildOnboardingSlides(includeNotifications: true)
        .map((s) => s.type)
        .toList();

    expect(slides, contains(OnboardingSlideType.notifications));
    expect(
      slides.indexOf(OnboardingSlideType.notifications),
      slides.indexOf(OnboardingSlideType.layout) + 1,
      reason: 'the ask belongs after the flow is otherwise configured',
    );
    expect(slides.last, OnboardingSlideType.allSet);
  });

  test('a platform with nothing to ask for gets no slide at all', () {
    final withIt = buildOnboardingSlides(includeNotifications: true)
        .map((s) => s.type)
        .toList();
    final withoutIt = buildOnboardingSlides(includeNotifications: false)
        .map((s) => s.type)
        .toList();

    expect(withoutIt, isNot(contains(OnboardingSlideType.notifications)));
    expect(
      withoutIt,
      withIt.where((t) => t != OnboardingSlideType.notifications).toList(),
      reason: 'dropping the slide must not reorder the rest of the flow',
    );
  });

  test('desktop platforms without a permission dialog are excluded', () {
    // Windows and Linux post notifications without asking, so there is nothing
    // for the slide to do there. The default the screen uses comes from here.
    expect(
      MessageNotificationPresenter.promptsForPermission,
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS,
    );
    expect(
      GenerationNotificationService.instance.notificationsNeedPermission,
      MessageNotificationPresenter.promptsForPermission,
      reason: 'every platform this runs on also supports notifications',
    );
  });
}
