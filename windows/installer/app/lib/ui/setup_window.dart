import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/args.dart';
import '../src/config.dart';
import '../src/controller.dart';
import '../src/engine.dart';
import 'glaze_spinner.dart';
import 'strings.dart';
import 'theme.dart';

/// Hooks into the real window, so tests and previews can leave them out.
class WindowHooks {
  final VoidCallback onClose;
  final void Function(DragStartDetails)? onDrag;

  const WindowHooks({required this.onClose, this.onDrag});
}

class SetupApp extends StatelessWidget {
  final SetupController controller;
  final WindowHooks hooks;

  const SetupApp({super.key, required this.controller, required this.hooks});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: S.of.windowTitle,
    debugShowCheckedModeBanner: false,
    theme: setupTheme(),
    home: SetupWindow(controller: controller, hooks: hooks),
  );
}

class SetupWindow extends StatelessWidget {
  final SetupController controller;
  final WindowHooks hooks;

  const SetupWindow({super.key, required this.controller, required this.hooks});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller;
      final failed = c.phase == SetupPhase.failed;
      final intensity = switch (c.phase) {
        SetupPhase.loading => 0.3,
        SetupPhase.welcome => 0.55,
        SetupPhase.working => 0.6 + 0.3 * c.progress,
        SetupPhase.done => 1.0,
        SetupPhase.failed => 0.6,
      };
      return Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: AmbientGlow(
                intensity: intensity,
                color: failed ? SetupColors.error : SetupColors.accent,
              ),
            ),
            Column(
              children: [
                _TitleBar(controller: c, hooks: hooks),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 520),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween(
                          begin: const Offset(0, 0.04),
                          end: Offset.zero,
                        ).animate(animation),
                        child: ScaleTransition(
                          scale: Tween(
                            begin: 0.985,
                            end: 1.0,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                    ),
                    child: KeyedSubtree(
                      key: ValueKey(c.phase),
                      child: switch (c.phase) {
                        SetupPhase.loading => const Center(
                          child: GlazeSpinner(size: 34),
                        ),
                        SetupPhase.welcome =>
                          c.mode == SetupMode.uninstall
                              ? _UninstallPage(controller: c, hooks: hooks)
                              : _WelcomePage(controller: c, hooks: hooks),
                        SetupPhase.working => _WorkingPage(controller: c),
                        SetupPhase.done => _DonePage(
                          controller: c,
                          hooks: hooks,
                        ),
                        SetupPhase.failed => _FailedPage(
                          controller: c,
                          hooks: hooks,
                        ),
                      },
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

// ── chrome ───────────────────────────────────────────────────────────────────

class _TitleBar extends StatelessWidget {
  final SetupController controller;
  final WindowHooks hooks;

  const _TitleBar({required this.controller, required this.hooks});

  @override
  Widget build(BuildContext context) {
    // Closing mid-run would leave half a folder; the button waits.
    final canClose = controller.phase != SetupPhase.working;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: hooks.onDrag,
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            const SizedBox(width: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(4.5),
              child: Image.asset('assets/glaze.png', width: 18, height: 18),
            ),
            const SizedBox(width: 10),
            Text(
              S.of.windowTitle,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: SetupColors.muted,
              ),
            ),
            const SizedBox(width: 10),
            _Chip(
              label: S.of.channelLabel(Channel.current.id),
              highlight: !Channel.current.isStable,
            ),
            const Spacer(),
            _WindowButton(
              icon: Icons.close_rounded,
              onTap: canClose ? hooks.onClose : null,
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool highlight;

  const _Chip({required this.label, this.highlight = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: (highlight ? SetupColors.accent : SetupColors.muted).withValues(
        alpha: 0.14,
      ),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: highlight ? const Color(0xFFE5546F) : SetupColors.muted,
      ),
    ),
  );
}

class _WindowButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _WindowButton({required this.icon, this.onTap});

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 34,
        height: 30,
        decoration: BoxDecoration(
          color: _hover && widget.onTap != null
              ? SetupColors.accent.withValues(alpha: 0.85)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Icon(
          widget.icon,
          size: 17,
          color: widget.onTap == null
              ? SetupColors.muted.withValues(alpha: 0.4)
              : _hover
              ? Colors.white
              : SetupColors.muted,
        ),
      ),
    ),
  );
}

/// Children slide up and fade in one after another.
class _Stagger extends StatelessWidget {
  final List<Widget> children;
  final CrossAxisAlignment crossAxisAlignment;

  const _Stagger({
    required this.children,
    this.crossAxisAlignment = CrossAxisAlignment.start,
  });

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: crossAxisAlignment,
    children: [
      for (var i = 0; i < children.length; i++)
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: Duration(milliseconds: 520 + 70 * i),
          curve: Interval(
            math.min(0.12 * i, 0.6),
            1,
            curve: Curves.easeOutCubic,
          ),
          builder: (context, t, child) => Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, 14 * (1 - t)),
              child: child,
            ),
          ),
          child: children[i],
        ),
    ],
  );
}

/// The Glaze mark with a breathing glow behind it.
class _Logo extends StatefulWidget {
  const _Logo();

  static const _size = 96.0;

  @override
  State<_Logo> createState() => _LogoState();
}

class _LogoState extends State<_Logo> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0.6, end: 1),
    duration: const Duration(milliseconds: 900),
    curve: Curves.elasticOut,
    builder: (context, scale, child) =>
        Transform.scale(scale: scale, child: child),
    child: AnimatedBuilder(
      animation: _breath,
      builder: (context, child) {
        final b = Curves.easeInOut.transform(_breath.value);
        return Container(
          width: _Logo._size,
          height: _Logo._size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_Logo._size * 0.24),
            boxShadow: [
              BoxShadow(
                color: SetupColors.accent.withValues(alpha: 0.25 + 0.2 * b),
                blurRadius: 30 + 20 * b,
                spreadRadius: 2 + 4 * b,
              ),
            ],
          ),
          child: child,
        );
      },
      child: ClipRRect(
        // The mark's PNG is a square tile; the app icon's corners.
        borderRadius: BorderRadius.circular(_Logo._size * 0.24),
        child: Image.asset(
          'assets/glaze.png',
          filterQuality: FilterQuality.medium,
        ),
      ),
    ),
  );
}

/// Two columns: the brand on the left, the page's own content on the right.
class _TwoColumns extends StatelessWidget {
  final Widget left;
  final Widget right;

  const _TwoColumns({required this.left, required this.right});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(36, 8, 28, 26),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 10, child: left),
        const SizedBox(width: 28),
        Expanded(flex: 11, child: right),
      ],
    ),
  );
}

class _Brand extends StatelessWidget {
  final String? subtitle;

  const _Brand({this.subtitle});

  @override
  Widget build(BuildContext context) => Center(
    child: _Stagger(
      children: [
        const _Logo(),
        const SizedBox(height: 26),
        Text(
          Channel.current.appName,
          style: const TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.8,
            color: SetupColors.text,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          Channel.current.versionLabel,
          style: const TextStyle(fontSize: 13, color: SetupColors.muted),
        ),
        const SizedBox(height: 18),
        Text(
          subtitle ?? S.of.tagline,
          style: TextStyle(
            fontSize: 13.5,
            height: 1.5,
            color: SetupColors.text.withValues(alpha: 0.72),
          ),
        ),
      ],
    ),
  );
}

// ── pages ────────────────────────────────────────────────────────────────────

class _WelcomePage extends StatelessWidget {
  final SetupController controller;
  final WindowHooks hooks;

  const _WelcomePage({required this.controller, required this.hooks});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = S.of;
    final previous = c.installedVersion;
    final same = previous == setupVersion;
    return _TwoColumns(
      left: const _Brand(),
      right: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(),
          _Stagger(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Frost(
                child: SetupPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Label(icon: Icons.folder_rounded, text: s.installTo),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.22),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Text(
                          c.paths?.installDir ?? '',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: SetupColors.text,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        previous == null
                            ? s.dataStays
                            : s.installedVersion(previous),
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.45,
                          color: SetupColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Frost(
                child: SetupPanel(
                  padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.desktopShortcut,
                              style: const TextStyle(
                                fontSize: 14,
                                color: SetupColors.text,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              s.desktopShortcutHint,
                              style: const TextStyle(
                                fontSize: 12,
                                color: SetupColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: c.desktopShortcut,
                        onChanged: c.setDesktopShortcut,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              SetupButton(label: s.cancel, onTap: hooks.onClose),
              const SizedBox(width: 10),
              SetupButton(
                label: previous == null
                    ? s.install
                    : same
                    ? s.reinstall
                    : s.update,
                icon: Icons.download_rounded,
                tone: SetupButtonTone.primary,
                large: true,
                onTap: c.start,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Label({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 15, color: SetupColors.accent),
      const SizedBox(width: 7),
      Text(
        text,
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: SetupColors.text,
        ),
      ),
    ],
  );
}

class _UninstallPage extends StatelessWidget {
  final SetupController controller;
  final WindowHooks hooks;

  const _UninstallPage({required this.controller, required this.hooks});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = S.of;
    final dataDir = c.paths?.dataDir ?? '';
    return _TwoColumns(
      left: _Brand(subtitle: s.uninstallHint),
      right: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(),
          _Stagger(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                s.uninstallTitle(Channel.current.appName),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: SetupColors.text,
                ),
              ),
              const SizedBox(height: 16),
              Frost(
                child: SetupPanel(
                  child: c.canDeleteData
                      ? InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => c.setDeleteData(!c.deleteData),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Checkbox(
                                value: c.deleteData,
                                onChanged: (v) => c.setDeleteData(v ?? false),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 9),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        s.deleteData,
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: c.deleteData
                                              ? SetupColors.error
                                              : SetupColors.text,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        s.deleteDataHint(dataDir),
                                        style: const TextStyle(
                                          fontSize: 12,
                                          height: 1.45,
                                          color: SetupColors.muted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.shield_rounded,
                              size: 18,
                              color: SetupColors.success,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                s.legacyKeepsData(dataDir),
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  height: 1.45,
                                  color: SetupColors.text,
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              SetupButton(label: s.cancel, onTap: hooks.onClose),
              const SizedBox(width: 10),
              SetupButton(
                label: s.remove,
                icon: Icons.delete_outline_rounded,
                tone: SetupButtonTone.destructive,
                large: true,
                onTap: c.start,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WorkingPage extends StatelessWidget {
  final SetupController controller;

  const _WorkingPage({required this.controller});

  String _title(S s) {
    final app = Channel.current.appName;
    return switch (controller.mode) {
      SetupMode.install =>
        controller.installedVersion == null
            ? s.installing(app)
            : s.updating(app),
      SetupMode.update => s.updating(app),
      SetupMode.uninstall => s.removing(app),
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = S.of;
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 4, 36, 24),
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: 10,
                  child: Center(child: _ProgressRing(value: c.progress)),
                ),
                const SizedBox(width: 24),
                Expanded(
                  flex: 11,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _title(s),
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: SetupColors.text,
                        ),
                      ),
                      const SizedBox(height: 18),
                      for (final step in c.steps)
                        _StepRow(
                          label: _stepLabel(step, s, c.mode),
                          state: _stateOf(step, c),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 380),
            curve: Curves.easeOutCubic,
            child: c.waitingForApp
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _AppOpenBanner(controller: c),
                  )
                : const SizedBox(width: double.infinity),
          ),
          SizedBox(
            height: 18,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              child: Text(
                c.detail,
                key: ValueKey(c.detail),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: SetupColors.muted.withValues(alpha: 0.8),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _stepLabel(SetupStep step, S s, SetupMode mode) =>
      switch (step) {
        SetupStep.close => s.stepClose,
        SetupStep.files =>
          mode == SetupMode.uninstall ? s.stepRemoveFiles : s.stepFiles,
        SetupStep.shortcuts => s.stepShortcuts,
        SetupStep.data => s.stepData,
        SetupStep.finish => s.stepFinish,
      };

  static _StepState _stateOf(SetupStep step, SetupController c) {
    final current = c.step;
    if (current == null) return _StepState.pending;
    final order = c.steps;
    final i = order.indexOf(step);
    final at = order.indexOf(current);
    if (i < at || (current == SetupStep.finish && c.progress >= 1)) {
      return _StepState.done;
    }
    return i == at ? _StepState.active : _StepState.pending;
  }
}

enum _StepState { pending, active, done }

class _StepRow extends StatelessWidget {
  final String label;
  final _StepState state;

  const _StepRow({required this.label, required this.state});

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      _StepState.pending => SetupColors.muted.withValues(alpha: 0.55),
      _StepState.active => SetupColors.text,
      _StepState.done => SetupColors.text.withValues(alpha: 0.7),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 22,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 380),
              transitionBuilder: (child, a) => ScaleTransition(
                scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack),
                child: FadeTransition(opacity: a, child: child),
              ),
              child: switch (state) {
                _StepState.pending => Center(
                  key: const ValueKey('p'),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: SetupColors.muted.withValues(alpha: 0.4),
                    ),
                  ),
                ),
                _StepState.active => const GlazeSpinner(
                  key: ValueKey('a'),
                  size: 18,
                  glow: false,
                ),
                _StepState.done => Container(
                  key: const ValueKey('d'),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: SetupColors.accent,
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    size: 15,
                    color: Colors.white,
                  ),
                ),
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 250),
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                fontWeight: state == _StepState.active
                    ? FontWeight.w600
                    : FontWeight.w400,
                color: color,
              ),
              child: Text(label),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressRing extends StatelessWidget {
  final double value;

  const _ProgressRing({required this.value});

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 168,
    child: Stack(
      alignment: Alignment.center,
      children: [
        GlazeSpinner(value: value.clamp(0.0, 1.0), size: 168, strokeWidth: 7),
        TweenAnimationBuilder<double>(
          tween: Tween(end: value),
          duration: const Duration(milliseconds: 300),
          builder: (context, v, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${(v * 100).round()}',
                style: const TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1,
                  color: SetupColors.text,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const Text(
                '%',
                style: TextStyle(fontSize: 13, color: SetupColors.muted),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _AppOpenBanner extends StatelessWidget {
  final SetupController controller;

  const _AppOpenBanner({required this.controller});

  @override
  Widget build(BuildContext context) {
    final s = S.of;
    return Frost(
      child: SetupPanel(
        tint: SetupColors.accent.withValues(alpha: 0.12),
        padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
        child: Row(
          children: [
            const Icon(
              Icons.info_outline_rounded,
              size: 18,
              color: SetupColors.accent,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.appStillOpen,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: SetupColors.text,
                    ),
                  ),
                  Text(
                    s.appStillOpenHint,
                    style: const TextStyle(
                      fontSize: 12,
                      color: SetupColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            SetupButton(
              label: s.closeGlaze,
              icon: Icons.power_settings_new_rounded,
              tone: SetupButtonTone.primary,
              onTap: controller.closeGlazeNow,
            ),
          ],
        ),
      ),
    );
  }
}

class _DonePage extends StatefulWidget {
  final SetupController controller;
  final WindowHooks hooks;

  const _DonePage({required this.controller, required this.hooks});

  @override
  State<_DonePage> createState() => _DonePageState();
}

class _DonePageState extends State<_DonePage> {
  @override
  void initState() {
    super.initState();
    // An update was started by Glaze, which has quit: bring it back and go.
    if (widget.controller.mode == SetupMode.update) {
      Future<void>.delayed(const Duration(milliseconds: 1400), () async {
        await widget.controller.launchGlaze();
        widget.hooks.onClose();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final s = S.of;
    final app = Channel.current.appName;
    final uninstall = c.mode == SetupMode.uninstall;
    final updated = c.mode == SetupMode.update || c.installedVersion != null;
    final title = uninstall
        ? s.removed(app)
        : updated
        ? s.updated(app)
        : s.installed(app);
    final hint = uninstall
        ? (c.deleteData && c.canDeleteData ? s.removedData : s.removedKeptData)
        : c.mode == SetupMode.update
        ? s.startingGlaze
        : s.installedHint;
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 30),
        child: _Stagger(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const _Burst(),
            const SizedBox(height: 26),
            Text(
              title,
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
                color: SetupColors.text,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: 420,
              child: Text(
                hint,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13.5,
                  height: 1.5,
                  color: SetupColors.muted,
                ),
              ),
            ),
            const SizedBox(height: 26),
            if (c.mode != SetupMode.update)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SetupButton(label: s.close, onTap: widget.hooks.onClose),
                  if (!uninstall) ...[
                    const SizedBox(width: 10),
                    SetupButton(
                      label: s.openGlaze,
                      icon: Icons.arrow_forward_rounded,
                      tone: SetupButtonTone.primary,
                      large: true,
                      onTap: () async {
                        await c.launchGlaze();
                        widget.hooks.onClose();
                      },
                    ),
                  ],
                ],
              )
            else
              const GlazeSpinner(size: 22, glow: false),
          ],
        ),
      ),
    );
  }
}

/// The check that lands when a run is done: a disc popping in, a ring
/// spreading out from it and fading, then the tick drawn in.
class _Burst extends StatefulWidget {
  const _Burst();

  @override
  State<_Burst> createState() => _BurstState();
}

class _BurstState extends State<_Burst> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, _) => CustomPaint(
      size: const Size.square(120),
      painter: _BurstPainter(_c.value),
    ),
  );
}

class _BurstPainter extends CustomPainter {
  final double t;

  _BurstPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final disc = Curves.elasticOut.transform(
      const Interval(0, 0.55).transform(t),
    );
    final ring = Curves.easeOutCubic.transform(
      const Interval(0.08, 0.8).transform(t),
    );
    final tick = Curves.easeInOutCubic.transform(
      const Interval(0.35, 0.75).transform(t),
    );
    const r = 38.0;

    canvas.drawCircle(
      center,
      r + 24 * ring,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3 * (1 - ring) + 0.5
        ..color = SetupColors.accent.withValues(alpha: 0.6 * (1 - ring)),
    );
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4 + math.pi / 8;
      final d = r + 6 + 34 * ring;
      canvas.drawCircle(
        center + Offset(math.cos(a), math.sin(a)) * d,
        3 * (1 - ring),
        Paint()..color = SetupColors.accent.withValues(alpha: 1 - ring),
      );
    }
    canvas.drawCircle(
      center,
      r * disc,
      Paint()
        ..color = SetupColors.accent
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.5),
    );
    canvas.drawCircle(
      center,
      r * disc + 10,
      Paint()
        ..color = SetupColors.accent.withValues(alpha: 0.25 * disc.clamp(0, 1))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );
    if (tick > 0) {
      final path = Path()
        ..moveTo(center.dx - 15, center.dy + 1)
        ..lineTo(center.dx - 4, center.dy + 12)
        ..lineTo(center.dx + 17, center.dy - 11);
      final metric = path.computeMetrics().first;
      canvas.drawPath(
        metric.extractPath(0, metric.length * tick),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = Colors.white,
      );
    }
  }

  @override
  bool shouldRepaint(_BurstPainter old) => old.t != t;
}

class _FailedPage extends StatelessWidget {
  final SetupController controller;
  final WindowHooks hooks;

  const _FailedPage({required this.controller, required this.hooks});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = S.of;
    final details = '${c.error}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 10, 36, 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Stagger(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: SetupColors.error.withValues(alpha: 0.16),
                ),
                child: const Icon(
                  Icons.error_outline_rounded,
                  color: SetupColors.error,
                  size: 26,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                s.failed,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: SetupColors.text,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                c.missingPayload ? s.noPayload : s.failedHint,
                style: const TextStyle(
                  fontSize: 13.5,
                  height: 1.5,
                  color: SetupColors.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Frost(
              child: SetupPanel(
                padding: const EdgeInsets.all(14),
                child: SizedBox(
                  width: double.infinity,
                  child: SingleChildScrollView(
                    child: SelectableText(
                      details,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.5,
                        color: SetupColors.text,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy_rounded, size: 18),
                color: SetupColors.muted,
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: details)),
              ),
              const Spacer(),
              SetupButton(label: s.close, onTap: hooks.onClose),
              if (!c.missingPayload) ...[
                const SizedBox(width: 10),
                SetupButton(
                  label: s.tryAgain,
                  icon: Icons.refresh_rounded,
                  tone: SetupButtonTone.primary,
                  large: true,
                  onTap: c.start,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
