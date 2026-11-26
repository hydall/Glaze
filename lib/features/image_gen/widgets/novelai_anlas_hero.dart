import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/utils/error_format.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../image_gen_models.dart';
import '../services/novelai_account.dart';

/// Hero card of the NovelAI settings: the Anlas balance, the plan and the
/// Opus V5 allowance, plus what the next image will cost with the current
/// settings — free on Opus within its limits, 5 Anlas per Precise Reference
/// on every plan.
///
/// The card reads the account itself (`GET /user/subscription`, free) when
/// shown and whenever the token or endpoint changes; the refresh button reads
/// it again, e.g. after a generation.
class NovelAiAnlasHero extends StatefulWidget {
  const NovelAiAnlasHero({super.key, required this.settings, this.service});

  final ImageGenSettings settings;

  /// Injected in tests.
  final NovelAIAccountService? service;

  @override
  State<NovelAiAnlasHero> createState() => _NovelAiAnlasHeroState();
}

class _NovelAiAnlasHeroState extends State<NovelAiAnlasHero> {
  late final NovelAIAccountService _service =
      widget.service ?? NovelAIAccountService();
  NovelAIAccount? _account;
  String _error = '';
  bool _loading = false;
  int _epoch = 0;
  Timer? _debounce;

  NovelAIImageSettings get _config => widget.settings.novelai;
  bool get _hasKey => _config.apiKey.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(NovelAiAnlasHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.settings.novelai;
    if (old.apiKey != _config.apiKey || old.endpoint != _config.endpoint) {
      // The token is typed a character at a time.
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 600), _refresh);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final epoch = ++_epoch;
    if (!_hasKey) {
      setState(() {
        _account = null;
        _error = '';
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final account = await _service.fetch(_config);
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _account = account;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _account = null;
        _error = formatError(error);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = _account;
    final cost = NovelAIAnlasCost.estimate(widget.settings, account: account);
    final anlas = account?.anlas;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          colors: [
            context.cs.primary,
            Color.lerp(context.cs.primary, Colors.black, 0.2)!,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  [
                    'NovelAI',
                    if (account != null)
                      account.planName ?? 'imggen_nai_anlas_no_plan'.tr(),
                  ].join(' · '),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white70,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              SizedBox(
                width: 40,
                height: 40,
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(11),
                        child: GlazeSpinner(color: Colors.white, glow: false),
                      )
                    : IconButton(
                        tooltip: 'imggen_nai_anlas_refresh'.tr(),
                        onPressed: _hasKey ? _refresh : null,
                        icon: const Icon(
                          Icons.refresh_rounded,
                          size: 20,
                          color: Colors.white,
                        ),
                      ),
              ),
            ],
          ),
          Text(
            anlas == null ? '—' : _formatInt(anlas),
            style: const TextStyle(
              fontSize: 36,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              height: 1.1,
              letterSpacing: -0.5,
            ),
          ),
          Text(
            _subtitle(account).toUpperCase(),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Colors.white70,
              letterSpacing: 0.5,
            ),
          ),
          if (account != null) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _kpiRow(account),
            ),
          ],
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _costBox(cost),
          ),
        ],
      ),
    );
  }

  String _subtitle(NovelAIAccount? account) {
    if (!_hasKey) return 'imggen_nai_anlas_no_key'.tr();
    if (_error.isNotEmpty) return 'imggen_nai_anlas_failed'.tr();
    return 'Anlas';
  }

  Widget _kpiRow(NovelAIAccount account) {
    final items = <(String, String)>[
      (_formatInt(account.planAnlas ?? 0), 'imggen_nai_anlas_plan'.tr()),
      (
        _formatInt(account.purchasedAnlas ?? 0),
        'imggen_nai_anlas_purchased'.tr(),
      ),
      if (account.isOpus &&
          (account.v5Unavailable || account.v5Percent != null))
        (_v5Allowance(account), 'imggen_nai_anlas_v5'.tr()),
    ];
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0)
              Container(
                width: 1,
                height: 28,
                color: Colors.white.withValues(alpha: 0.2),
              ),
            Expanded(child: _kpi(items[i].$1, items[i].$2)),
          ],
        ],
      ),
    );
  }

  Widget _kpi(String value, String label) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label.toUpperCase(),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w500,
            color: Colors.white.withValues(alpha: 0.65),
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }

  Widget _costBox(NovelAIAnlasCost cost) {
    final lines = <String>[
      for (final reason in cost.reasons) _reasonText(reason),
      if (cost.referencesAtMost > 0) _referenceText(cost),
    ];
    final free = cost.isFree;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                free ? Icons.check_circle_outline : Icons.toll_outlined,
                size: 16,
                color: Colors.white,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  free
                      ? 'imggen_nai_anlas_free'.tr()
                      : 'imggen_nai_anlas_costs'.tr(),
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(left: 22, top: 4),
              child: Text(
                line,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.3,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
            ),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 22, top: 6),
              child: Text(
                _error,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: Colors.white.withValues(alpha: 0.7),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _reasonText(NovelAIAnlasReason reason) => switch (reason) {
    NovelAIAnlasReason.notOpus => 'imggen_nai_anlas_reason_plan'.tr(),
    NovelAIAnlasReason.v5AllowanceUsedUp => 'imggen_nai_anlas_reason_v5'.tr(),
    NovelAIAnlasReason.largeImage => 'imggen_nai_anlas_reason_size'.tr(
      args: ['${_config.width}×${_config.height}'],
    ),
    NovelAIAnlasReason.manySteps => 'imggen_nai_anlas_reason_steps'.tr(
      args: ['${_config.steps}', '${NovelAIConstants.freeMaxSteps}'],
    ),
  };

  String _referenceText(NovelAIAnlasCost cost) {
    final always = cost.referenceAnlasAlways;
    final atMost = cost.referenceAnlasAtMost;
    final range = always == atMost ? '$atMost' : '$always–$atMost';
    return 'imggen_nai_anlas_reason_refs'.tr(
      args: ['${NovelAIConstants.referenceAnlas}', range],
    );
  }

  String _v5Allowance(NovelAIAccount account) {
    if (account.v5Unavailable) return 'imggen_nai_anlas_v5_used_up'.tr();
    final extra = account.v5PurchasedPercent ?? 0;
    return extra > 0
        ? '${account.v5Percent}% +$extra%'
        : '${account.v5Percent}%';
  }
}

/// 12500 → "12 500", with a thin space between the groups.
String _formatInt(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write('\u2009');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}
