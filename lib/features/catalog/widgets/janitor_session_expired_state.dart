import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../catalog_provider.dart';
import '../janitor_account_provider.dart';
import '../services/janitor_webview_proxy.dart';
import 'janitor_login_sheet.dart';

/// Stands in for the catalog's error line when JanitorAI kept answering 401 —
/// usually a stale account session the refresh could not save, seen mostly
/// behind VPNs.
///
/// The dead session is dropped before the login sheet opens: left in place, the
/// login page would find the old token, count it as a successful sign-in and
/// close at once. Dropping it alone often brings the feed back, so the catalog
/// reloads even when the user closes the sheet without logging in (a successful
/// login reloads it itself).
class JanitorSessionExpiredState extends ConsumerStatefulWidget {
  const JanitorSessionExpiredState({super.key});

  @override
  ConsumerState<JanitorSessionExpiredState> createState() =>
      _JanitorSessionExpiredStateState();
}

class _JanitorSessionExpiredStateState
    extends ConsumerState<JanitorSessionExpiredState> {
  bool _busy = false;

  Future<void> _relogin() async {
    setState(() => _busy = true);
    await ref.read(janitorAccountProvider.notifier).setUserName(null);
    await JanitorWebViewProxy.instance.logout();
    if (!mounted) return;
    await showJanitorLoginSheet(context);
    if (!ref.read(janitorAccountProvider).isLoggedIn) {
      await ref.read(catalogProvider.notifier).search(reset: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  // Laid out like the empty character and dialog lists.
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 32),
      child: Column(
        children: [
          const _ExpiredSessionIllustration(),
          const SizedBox(height: 20),
          Text(
            'catalog_janitor_session_expired_title'.tr(),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: context.cs.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'catalog_janitor_browse_session_expired'.tr(),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: context.cs.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          GlazeActionButton(
            icon: Icons.login_rounded,
            label: 'catalog_janitor_session_expired_login'.tr(),
            tone: GlazeActionTone.primary,
            busy: _busy,
            onTap: _relogin,
          ),
        ],
      ),
    );
  }
}

/// A muted account card with an accent key badge struck through over its
/// corner — the saved login that stopped working. The card settles in, the
/// badge lands a beat later, and then both stay still: an idle loop on an
/// empty screen distracts.
class _ExpiredSessionIllustration extends StatelessWidget {
  const _ExpiredSessionIllustration();

  static const _curve = Cubic(0.2, 0.8, 0.2, 1);

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 700),
      builder: (context, t, _) {
        final card = _curve.transform(const Interval(0, 0.7).transform(t));
        final badge = _curve.transform(const Interval(0.3, 1).transform(t));
        return SizedBox(
          width: 200,
          height: 160,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 50,
                top: 14 + 12 * (1 - card),
                child: Opacity(
                  opacity: card,
                  child: Transform.rotate(
                    angle: -0.1 * card,
                    child: _AccountCard(color: cs.onSurfaceVariant),
                  ),
                ),
              ),
              Positioned(
                right: 34,
                bottom: 12,
                child: Opacity(
                  opacity: badge,
                  child: Transform.scale(
                    scale: 0.7 + 0.3 * badge,
                    child: _KeyBadge(color: cs.primary, onColor: cs.onPrimary),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AccountCard extends StatelessWidget {
  final Color color;

  const _AccountCard({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 92,
      height: 124,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.person_rounded,
              size: 26,
              color: color.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(height: 12),
          _Line(width: 52, color: color.withValues(alpha: 0.35)),
          const SizedBox(height: 7),
          _Line(width: 34, color: color.withValues(alpha: 0.22)),
        ],
      ),
    );
  }
}

class _KeyBadge extends StatelessWidget {
  final Color color;
  final Color onColor;

  const _KeyBadge({required this.color, required this.onColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color, Color.lerp(color, Colors.black, 0.25)!],
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.35),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Icon(Icons.key_off_rounded, size: 28, color: onColor),
    );
  }
}

class _Line extends StatelessWidget {
  final double width;
  final Color color;

  const _Line({required this.width, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 7,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}
