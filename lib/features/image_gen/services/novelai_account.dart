import '../image_gen_models.dart';
import 'image_gen_http.dart';

/// What NovelAI's `GET /user/subscription` says about the plan, the Anlas
/// balance and the Opus V5 allowance.
///
/// Shapes and free-generation rules follow
/// https://github.com/Guppy779/NovelAI-Krita-plugin (`api.py`), which reads
/// the endpoint from the image host: `api.novelai.net` rejects third-party
/// clients there.
class NovelAIAccount {
  const NovelAIAccount({
    this.tier,
    this.active = false,
    this.planAnlas,
    this.purchasedAnlas,
    this.v5Percent,
    this.v5PurchasedPercent,
    this.v5RefillSeconds,
    this.v5Unavailable = false,
  });

  static const int opusTier = 3;
  static const _tierNames = {0: 'Paper', 1: 'Tablet', 2: 'Scroll', 3: 'Opus'};

  final int? tier;
  final bool active;

  /// Refilled monthly with the subscription.
  final int? planAnlas;
  final int? purchasedAnlas;

  /// Opus's V5 allowance: percent left, percent bought on top, seconds until
  /// the next +1%, and whether it is used up.
  final int? v5Percent;
  final int? v5PurchasedPercent;
  final int? v5RefillSeconds;
  final bool v5Unavailable;

  factory NovelAIAccount.fromJson(Map<String, dynamic> json) {
    int? asInt(Object? value) => value is int ? value : null;
    final steps = json['trainingStepsLeft'];
    final usage = json['usage'];
    final stepsMap = steps is Map ? steps : const <Object?, Object?>{};
    final usageMap = usage is Map ? usage : const <Object?, Object?>{};
    return NovelAIAccount(
      tier: asInt(json['tier']),
      active: json['active'] == true,
      planAnlas: asInt(stepsMap['fixedTrainingStepsLeft']),
      purchasedAnlas: asInt(stepsMap['purchasedTrainingSteps']),
      v5Percent: asInt(usageMap['percent']),
      v5PurchasedPercent: asInt(usageMap['purchasedPercent']),
      v5RefillSeconds: asInt(usageMap['timeUntilNextPercent']),
      v5Unavailable: usageMap['isNegative'] == true,
    );
  }

  /// Plan plus purchased Anlas; null when the response had neither.
  int? get anlas => planAnlas == null && purchasedAnlas == null
      ? null
      : (planAnlas ?? 0) + (purchasedAnlas ?? 0);

  bool get isOpus => active && tier == opusTier;

  /// The plan's name, or null without an active subscription.
  String? get planName => active ? (_tierNames[tier] ?? 'Tier $tier') : null;
}

class NovelAIAccountService {
  NovelAIAccountService({ImageGenHttp? http}) : _http = http ?? ImageGenHttp();

  final ImageGenHttp _http;

  /// Reads the account behind [settings]' token. Free: nothing is generated.
  Future<NovelAIAccount> fetch(NovelAIImageSettings settings) async {
    final json = await _http.getJson(
      url:
          '${NovelAIConstants.normalizeEndpoint(settings.endpoint)}'
          '/user/subscription',
      apiKey: settings.apiKey.trim(),
    );
    return NovelAIAccount.fromJson(json);
  }
}

/// Why the next generation would spend Anlas.
enum NovelAIAnlasReason {
  /// Free generations need an active Opus plan.
  notOpus,

  /// Opus's V5 allowance is used up.
  v5AllowanceUsedUp,

  /// The image is larger than 1024x1024 in area.
  largeImage,

  /// More than 28 steps.
  manySteps,
}

/// The Anlas outlook of the next NovelAI generation.
///
/// [reasons] make the whole image paid; references cost
/// [NovelAIConstants.referenceAnlas] each on top, on every plan. Their exact
/// count depends on the prompt, so it is given as a range:
/// [referencesAlways] are sent for any prompt (avatars, `always` library
/// entries), [referencesAtMost] also counts every library entry a prompt can
/// trigger and the previous images sent as context.
class NovelAIAnlasCost {
  const NovelAIAnlasCost({
    required this.reasons,
    required this.referencesAlways,
    required this.referencesAtMost,
  });

  final List<NovelAIAnlasReason> reasons;
  final int referencesAlways;
  final int referencesAtMost;

  int get referenceAnlasAlways =>
      referencesAlways * NovelAIConstants.referenceAnlas;
  int get referenceAnlasAtMost =>
      referencesAtMost * NovelAIConstants.referenceAnlas;

  /// No Anlas at all for any prompt.
  bool get isFree => reasons.isEmpty && referencesAtMost == 0;

  /// Builds the outlook from the settings. Without an [account] (not loaded
  /// yet, or it failed) an Opus plan is assumed, as NovelAI's site does.
  factory NovelAIAnlasCost.estimate(
    ImageGenSettings settings, {
    NovelAIAccount? account,
  }) {
    final config = settings.novelai;
    final model = config.model;
    final reasons = <NovelAIAnlasReason>[];
    if (account != null && !account.isOpus) {
      reasons.add(NovelAIAnlasReason.notOpus);
    } else {
      if (account != null &&
          NovelAIConstants.isV5(model) &&
          (account.v5Unavailable || account.v5Percent == 0)) {
        reasons.add(NovelAIAnlasReason.v5AllowanceUsedUp);
      }
      if (config.width * config.height > NovelAIConstants.freeMaxPixels) {
        reasons.add(NovelAIAnlasReason.largeImage);
      }
      if (config.steps > NovelAIConstants.freeMaxSteps) {
        reasons.add(NovelAIAnlasReason.manySteps);
      }
    }

    var always = 0;
    var atMost = 0;
    if (NovelAIConstants.supportsReferences(model)) {
      if (settings.sendsCharAvatarImage) always++;
      if (settings.sendUserAvatar) always++;
      atMost = always;
      for (final ref in settings.references) {
        if (!ref.enabled || ref.imageData.isEmpty) continue;
        if (ref.matchMode == 'always') always++;
        atMost++;
      }
      if (settings.imageContextEnabled) {
        atMost += settings.imageContextCount.clamp(1, 3);
      }
    }
    const max = NovelAIConstants.maxReferences;
    return NovelAIAnlasCost(
      reasons: reasons,
      referencesAlways: always.clamp(0, max),
      referencesAtMost: atMost.clamp(0, max),
    );
  }
}
