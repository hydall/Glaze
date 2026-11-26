import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/services/novelai_account.dart';
import 'package:glaze_flutter/features/image_gen/widgets/novelai_anlas_hero.dart';

const _opus = NovelAIAccount(
  tier: 3,
  active: true,
  planAnlas: 10000,
  purchasedAnlas: 2500,
  v5Percent: 85,
);

class _FakeAccountService extends NovelAIAccountService {
  _FakeAccountService(this.result);

  final FutureOr<NovelAIAccount> Function() result;
  int calls = 0;

  @override
  Future<NovelAIAccount> fetch(NovelAIImageSettings settings) async {
    calls++;
    return result();
  }
}

ImageGenSettings _settings({
  String model = 'nai-diffusion-4-5-full',
  int width = 832,
  int height = 1216,
  int steps = 28,
  bool sendCharAvatar = false,
  bool sendUserAvatar = false,
  bool imageContext = false,
  List<ReferenceImage> references = const [],
}) => ImageGenSettings(
  apiType: ImageGenApiType.novelai,
  novelai: NovelAIImageSettings(
    apiKey: 'pst-key',
    model: model,
    width: width,
    height: height,
    steps: steps,
  ),
  sendCharAvatar: sendCharAvatar,
  sendUserAvatar: sendUserAvatar,
  imageContextEnabled: imageContext,
  imageContextCount: 2,
  references: references,
);

void main() {
  group('NovelAIAccount.fromJson', () {
    test('reads plan, Anlas and the V5 allowance', () {
      final account = NovelAIAccount.fromJson({
        'tier': 3,
        'active': true,
        'trainingStepsLeft': {
          'fixedTrainingStepsLeft': 10000,
          'purchasedTrainingSteps': 2500,
        },
        'usage': {
          'percent': 85,
          'purchasedPercent': 20,
          'timeUntilNextPercent': 600,
          'isNegative': false,
        },
      });

      expect(account.isOpus, isTrue);
      expect(account.planName, 'Opus');
      expect(account.anlas, 12500);
      expect(account.v5Percent, 85);
      expect(account.v5PurchasedPercent, 20);
      expect(account.v5Unavailable, isFalse);
    });

    test('an inactive or empty answer has no plan and no balance', () {
      final account = NovelAIAccount.fromJson({'tier': 3, 'active': false});
      expect(account.isOpus, isFalse);
      expect(account.planName, isNull);
      expect(account.anlas, isNull);
    });
  });

  group('NovelAIAnlasCost.estimate', () {
    test('is free on Opus within the limits and without references', () {
      final cost = NovelAIAnlasCost.estimate(_settings(), account: _opus);
      expect(cost.isFree, isTrue);
    });

    test('assumes Opus while the account is unknown', () {
      expect(NovelAIAnlasCost.estimate(_settings()).isFree, isTrue);
    });

    test('lists every reason the image is paid', () {
      final cost = NovelAIAnlasCost.estimate(
        _settings(model: 'nai-diffusion-5-full', width: 1216, steps: 40),
        account: const NovelAIAccount(
          tier: 3,
          active: true,
          v5Unavailable: true,
        ),
      );
      expect(cost.reasons, [
        NovelAIAnlasReason.v5AllowanceUsedUp,
        NovelAIAnlasReason.largeImage,
        NovelAIAnlasReason.manySteps,
      ]);
    });

    test('a plan other than Opus always pays', () {
      final cost = NovelAIAnlasCost.estimate(
        _settings(),
        account: const NovelAIAccount(tier: 2, active: true),
      );
      expect(cost.reasons, [NovelAIAnlasReason.notOpus]);
    });

    test('counts references as a range, 5 Anlas each', () {
      final cost = NovelAIAnlasCost.estimate(
        _settings(
          sendCharAvatar: true,
          sendUserAvatar: true,
          imageContext: true,
          references: const [
            ReferenceImage(name: 'a', imageData: 'x', matchMode: 'always'),
            ReferenceImage(name: 'b', imageData: 'y'),
            ReferenceImage(name: 'c', imageData: 'z', enabled: false),
            ReferenceImage(name: 'd', imageData: ''),
          ],
        ),
        account: _opus,
      );
      // Two avatars + one `always` entry; at most also the matchable entry
      // and two context images.
      expect(cost.referencesAlways, 3);
      expect(cost.referencesAtMost, 6);
      expect(cost.referenceAnlasAlways, 15);
      expect(cost.referenceAnlasAtMost, 30);
      expect(cost.isFree, isFalse);
    });

    test('caps references at what NovelAI takes', () {
      final cost = NovelAIAnlasCost.estimate(
        _settings(
          references: [
            for (var i = 0; i < 20; i++)
              ReferenceImage(name: '$i', imageData: 'x$i', matchMode: 'always'),
          ],
        ),
      );
      expect(cost.referencesAlways, NovelAIConstants.maxReferences);
    });

    test('counts no references on a model without Precise Reference', () {
      final cost = NovelAIAnlasCost.estimate(
        _settings(model: 'nai-diffusion-4-full', sendCharAvatar: true),
      );
      expect(cost.referencesAtMost, 0);
    });
  });

  group('NovelAiAnlasHero', () {
    Future<void> pump(
      WidgetTester tester,
      ImageGenSettings settings,
      NovelAIAccountService service,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NovelAiAnlasHero(settings: settings, service: service),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('shows the balance, the plan and the V5 allowance', (
      tester,
    ) async {
      await pump(tester, _settings(), _FakeAccountService(() => _opus));

      expect(find.text('12\u2009500'), findsOneWidget);
      expect(find.text('NovelAI · Opus'), findsOneWidget);
      expect(find.text('10\u2009000'), findsOneWidget);
      expect(find.text('2\u2009500'), findsOneWidget);
      expect(find.text('85%'), findsOneWidget);
      expect(find.text('imggen_nai_anlas_free'), findsOneWidget);
    });

    testWidgets('lists the reference cost', (tester) async {
      await pump(
        tester,
        _settings(sendCharAvatar: true),
        _FakeAccountService(() => _opus),
      );

      expect(find.text('imggen_nai_anlas_costs'), findsOneWidget);
      expect(find.text('imggen_nai_anlas_reason_refs'), findsOneWidget);
    });

    testWidgets('does not call the API without a key', (tester) async {
      final service = _FakeAccountService(() => _opus);
      await pump(
        tester,
        const ImageGenSettings(apiType: ImageGenApiType.novelai),
        service,
      );

      expect(service.calls, 0);
      expect(find.text('—'), findsOneWidget);
      expect(find.text('IMGGEN_NAI_ANLAS_NO_KEY'), findsOneWidget);
    });

    testWidgets('keeps the cost outlook when the account fails', (
      tester,
    ) async {
      await pump(
        tester,
        _settings(),
        _FakeAccountService(() => throw Exception('401')),
      );

      expect(find.text('IMGGEN_NAI_ANLAS_FAILED'), findsOneWidget);
      expect(find.text('imggen_nai_anlas_free'), findsOneWidget);
    });

    testWidgets('refreshes on tap', (tester) async {
      final service = _FakeAccountService(() => _opus);
      await pump(tester, _settings(), service);
      await tester.tap(find.byIcon(Icons.refresh_rounded));
      await tester.pump();

      expect(service.calls, 2);
    });
  });
}
