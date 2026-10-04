import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/generation_notification_service.dart';

void main() {
  test('generation leases are independent and release idempotently', () async {
    final service = GenerationNotificationService.instance;
    final first = await service.acquireGenerationLease('First');
    final second = await service.acquireGenerationLease('Second');

    expect(service.isGenerating, isTrue);

    await first.release();
    await first.release();
    expect(service.isGenerating, isTrue);

    await second.release();
    expect(service.isGenerating, isFalse);
  });

  test('post-generation leases release idempotently', () async {
    final service = GenerationNotificationService.instance;
    final first = await service.acquirePostGenerationLease();
    final second = await service.acquirePostGenerationLease();

    await first.release();
    await first.release();
    await second.release();
  });
}
