import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_action_button.dart';
import '../../shared/widgets/glaze_scaffold.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/menu_group.dart';

/// Dev-only gallery for [GlazeSpinner] — every size, color and mode the app
/// uses, side by side with the Material indicator it replaced.
class SpinnerDemoScreen extends StatefulWidget {
  const SpinnerDemoScreen({super.key});

  @override
  State<SpinnerDemoScreen> createState() => _SpinnerDemoScreenState();
}

class _SpinnerDemoScreenState extends State<SpinnerDemoScreen> {
  double _progress = 0.35;
  bool _buttonBusy = true;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;

    return GlazeScaffold(
      title: 'menu_spinner_demo'.tr(),
      onBack: () => Navigator.of(context).pop(),
      body: ListView(
        padding: const EdgeInsets.only(top: 16, bottom: 32),
        children: [
          // ── Hero ──────────────────────────────────────────────────────────
          const _Card(
            child: Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: GlazeSpinner(size: 96),
              ),
            ),
          ),

          // ── Sizes ─────────────────────────────────────────────────────────
          const _Label('Sizes — stroke scales with the diameter'),
          const _Card(
            child: _Wrap(
              children: [
                _Sample(label: '12', child: GlazeSpinner(size: 12)),
                _Sample(label: '16', child: GlazeSpinner(size: 16)),
                _Sample(label: '18', child: GlazeSpinner(size: 18)),
                _Sample(label: '24', child: GlazeSpinner(size: 24)),
                _Sample(label: '36', child: GlazeSpinner(size: 36)),
                _Sample(label: '48', child: GlazeSpinner(size: 48)),
                _Sample(label: '64', child: GlazeSpinner(size: 64)),
              ],
            ),
          ),

          // ── Inferred sizing ───────────────────────────────────────────────
          const _Label('Sizing without an explicit size'),
          const _Card(
            child: _Wrap(
              children: [
                _Sample(
                  label: 'default\n(36)',
                  child: GlazeSpinner(),
                ),
                _Sample(
                  label: 'SizedBox\n18',
                  child: SizedBox(width: 18, height: 18, child: GlazeSpinner()),
                ),
                _Sample(
                  label: 'SizedBox\n28',
                  child: SizedBox(width: 28, height: 28, child: GlazeSpinner()),
                ),
              ],
            ),
          ),

          // ── Colors ────────────────────────────────────────────────────────
          const _Label('Colors'),
          _Card(
            child: _Wrap(
              children: [
                _Sample(
                  label: 'primary',
                  child: GlazeSpinner(size: 32, color: cs.primary),
                ),
                _Sample(
                  label: 'accent',
                  child: GlazeSpinner(size: 32, color: context.colors.accent),
                ),
                _Sample(
                  label: 'error',
                  child: GlazeSpinner(size: 32, color: cs.error),
                ),
                const _Sample(
                  label: 'white',
                  child: GlazeSpinner(size: 32, color: Colors.white),
                ),
                const _Sample(
                  label: 'white70',
                  child: GlazeSpinner(size: 32, color: Colors.white70),
                ),
              ],
            ),
          ),

          // ── Glow / track ──────────────────────────────────────────────────
          const _Label('Halo and track'),
          const _Card(
            child: _Wrap(
              children: [
                _Sample(label: 'default', child: GlazeSpinner(size: 40)),
                _Sample(
                  label: 'no halo',
                  child: GlazeSpinner(size: 40, glow: false),
                ),
                _Sample(
                  label: 'no track',
                  child: GlazeSpinner(
                    size: 40,
                    trackColor: Colors.transparent,
                  ),
                ),
                _Sample(
                  label: 'bare',
                  child: GlazeSpinner(
                    size: 40,
                    glow: false,
                    trackColor: Colors.transparent,
                  ),
                ),
              ],
            ),
          ),

          // ── Determinate ───────────────────────────────────────────────────
          const _Label('Determinate — drag to animate the arc'),
          _Card(
            child: Column(
              children: [
                _Wrap(
                  children: [
                    _Sample(
                      label: '${(_progress * 100).round()}%',
                      child: GlazeSpinner(size: 56, value: _progress),
                    ),
                    _Sample(
                      label: 'small',
                      child: GlazeSpinner(size: 24, value: _progress),
                    ),
                    _Sample(
                      label: 'no halo',
                      child: GlazeSpinner(
                        size: 56,
                        value: _progress,
                        glow: false,
                      ),
                    ),
                  ],
                ),
                MenuGroup(
                  compact: true,
                  items: [
                    MenuRangeItem(
                      label: 'Progress',
                      value: _progress,
                      min: 0,
                      max: 1,
                      divisions: 100,
                      onChanged: (v) => setState(() => _progress = v),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ── Against the Material indicator ────────────────────────────────
          const _Label('Next to the Material indicator it replaced'),
          const _Card(
            child: _Wrap(
              children: [
                _Sample(label: 'GlazeSpinner', child: GlazeSpinner(size: 36)),
                _Sample(
                  label: 'Material',
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: CircularProgressIndicator(),
                  ),
                ),
                _Sample(label: 'Glaze 18', child: GlazeSpinner(size: 18)),
                _Sample(
                  label: 'Material 18',
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ],
            ),
          ),

          // ── In context ────────────────────────────────────────────────────
          const _Label('In context'),
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: () => setState(() => _buttonBusy = !_buttonBusy),
                  child: GlazeActionButton(
                    icon: Icons.play_arrow_rounded,
                    label: _buttonBusy ? 'Working…' : 'Tap to toggle',
                    tone: GlazeActionTone.primary,
                    busy: _buttonBusy,
                    onTap: () => setState(() => _buttonBusy = !_buttonBusy),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const SizedBox(width: 18, height: 18, child: GlazeSpinner()),
                    const SizedBox(width: 12),
                    Text(
                      'Inline row label',
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  height: 120,
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Center(child: GlazeSpinner()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Layout helpers ──────────────────────────────────────────────────────────

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: context.cs.primary.withValues(alpha: 0.7),
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.cs.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.cs.outlineVariant),
      ),
      child: child,
    );
  }
}

class _Wrap extends StatelessWidget {
  const _Wrap({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 20,
      runSpacing: 16,
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: children,
    );
  }
}

/// A spinner plus its caption, aligned on a common baseline so a row of mixed
/// sizes reads as a scale rather than a jumble.
class _Sample extends StatelessWidget {
  const _Sample({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: 64, child: Center(child: child)),
        const SizedBox(height: 6),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 10,
            height: 1.2,
            color: context.cs.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
