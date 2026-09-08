import 'dart:ui';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/theme/app_colors.dart';
import '../../shared/theme/theme_provider.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../core/services/onboarding_service.dart';
import '../backup/backup_screen.dart';
import '../../core/state/active_selection_provider.dart';
import '../settings/api_list_provider.dart';
import '../settings/api_settings_screen.dart';
import '../settings/widgets/chat_layout_picker.dart';
import '../personas/persona_list_screen.dart';

// ---------------------------------------------------------------------------
// Slide data
// ---------------------------------------------------------------------------

enum OnboardingSlideType { welcome, features, dataImport, api, persona, layout, allSet }

class _SlideData {
  final OnboardingSlideType type;
  final String title;
  final String? desc;
  final IconData? icon;
  const _SlideData({required this.type, required this.title, this.desc, this.icon});
}

class _InfoBlock {
  final IconData icon;
  final String title;
  final String desc;
  const _InfoBlock({required this.icon, required this.title, required this.desc});
}

const _slides = <_SlideData>[
  _SlideData(type: OnboardingSlideType.welcome, title: 'onboarding_welcome_title'),
  _SlideData(type: OnboardingSlideType.features, title: 'onboarding_features_title'),
  _SlideData(
    type: OnboardingSlideType.dataImport,
    title: 'onboarding_import_title',
    desc: 'onboarding_import_slide_desc',
    icon: Icons.download_rounded,
  ),
  _SlideData(
    type: OnboardingSlideType.api,
    title: 'onboarding_api_title',
    desc: 'onboarding_preset_slide_desc',
    icon: Icons.dns_outlined,
  ),
  _SlideData(
    type: OnboardingSlideType.persona,
    title: 'onboarding_persona_title',
    desc: 'onboarding_persona_slide_desc',
    icon: Icons.person_outline_rounded,
  ),
  _SlideData(
    type: OnboardingSlideType.layout,
    title: 'onboarding_layout_title',
    desc: 'onboarding_layout_slide_desc',
    icon: Icons.view_quilt_outlined,
  ),
  _SlideData(
    type: OnboardingSlideType.allSet,
    title: 'onboarding_allset_title',
    desc: 'onboarding_allset_slide_desc',
    icon: Icons.check_circle_outline_rounded,
  ),
];

const _introContent = <_InfoBlock>[
  _InfoBlock(
    icon: Icons.layers_outlined,
    title: 'onboarding_feature_roleplay_title',
    desc: 'onboarding_feature_roleplay_desc',
  ),
  _InfoBlock(
    icon: Icons.link_rounded,
    title: 'onboarding_feature_rules_title',
    desc: 'onboarding_feature_rules_desc',
  ),
  _InfoBlock(
    icon: Icons.verified_outlined,
    title: 'onboarding_feature_privacy_title',
    desc: 'onboarding_feature_privacy_desc',
  ),
];

const _featuresContent = <_InfoBlock>[
  _InfoBlock(
    icon: Icons.image_outlined,
    title: 'onboarding_feature_imggen_title',
    desc: 'onboarding_feature_imggen_desc',
  ),
  _InfoBlock(
    icon: Icons.menu_book_outlined,
    title: 'onboarding_feature_glossary_title',
    desc: 'onboarding_feature_glossary_desc',
  ),
  _InfoBlock(
    icon: Icons.palette_outlined,
    title: 'onboarding_feature_custom_title',
    desc: 'onboarding_feature_custom_desc',
  ),
  _InfoBlock(
    icon: Icons.description_outlined,
    title: 'onboarding_feature_st_title',
    desc: 'onboarding_feature_st_desc',
  ),
];

// ---------------------------------------------------------------------------
// Flow widget
// ---------------------------------------------------------------------------

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  int _currentSlide = 0;
  int _direction = 1;

  bool get _isLastSlide => _currentSlide == _slides.length - 1;

  String get _buttonLabel {
    if (_isLastSlide) return 'onboarding_btn_start'.tr();
    switch (_slides[_currentSlide].type) {
      case OnboardingSlideType.dataImport:
        return 'onboarding_btn_skip'.tr();
      case OnboardingSlideType.persona:
        final personaId = ref.watch(activePersonaIdProvider);
        if (personaId != null) {
          return 'onboarding_btn_next'.tr();
        }
        return 'onboarding_btn_skip'.tr();
      case OnboardingSlideType.api:
        final apiConfig = ref.watch(activeApiConfigProvider);
        if (apiConfig != null && apiConfig.apiKey.isNotEmpty) {
          return 'onboarding_btn_next'.tr();
        }
        return 'onboarding_btn_skip'.tr();
      case OnboardingSlideType.layout:
        return 'onboarding_btn_next'.tr();
      default:
        return 'onboarding_btn_next'.tr();
    }
  }

  void _next() {
    if (_isLastSlide) {
      _finish();
    } else {
      setState(() { _direction = 1; _currentSlide++; });
    }
  }

  void _prev() {
    if (_currentSlide > 0) {
      setState(() { _direction = -1; _currentSlide--; });
    }
  }

  Future<void> _finish() async {
    await markOnboardingComplete();
    if (mounted) Navigator.of(context).pop();
  }

  /// Confirmation bottom sheet for skipping the whole onboarding flow.
  void _confirmSkipOnboarding() {
    GlazeBottomSheet.show<void>(
      context,
      title: 'onboarding_skip_confirm_title'.tr(),
      child: _SkipConfirmSheet(
        onCancel: () => Navigator.of(context, rootNavigator: true).pop(),
        onConfirm: () {
          Navigator.of(context, rootNavigator: true).pop();
          _finish();
        },
      ),
    );
  }

  void _openSheet(Widget sheet) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      useRootNavigator: true,
      builder: (_) => sheet,
    );
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0E),
      body: Stack(
        children: [
          // ── Scrollable content ──
          Positioned.fill(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                top: topPad + 84,
                bottom: 120 + bottomPad,
                left: 24,
                right: 24,
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: (currentChild, previousChildren) {
                  return Stack(
                    alignment: Alignment.topCenter,
                    children: <Widget>[
                      ...previousChildren,
                      ?currentChild,
                    ],
                  );
                },
                transitionBuilder: (child, anim) {
                  final dir = (child.key == ValueKey(_currentSlide)) ? _direction : -_direction;
                  return FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween(
                        begin: Offset(0.06 * dir, 0),
                        end: Offset.zero,
                      ).animate(anim),
                      child: child,
                    ),
                  );
                },
                child: KeyedSubtree(
                  key: ValueKey(_currentSlide),
                  child: _buildSlide(_slides[_currentSlide]),
                ),
              ),
            ),
          ),

          // ── Header gradient ──
          Positioned(
            top: 0, left: 0, right: 0,
            child: IgnorePointer(
              child: Container(
                height: topPad + 84,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x66000000), Colors.transparent],
                  ),
                ),
              ),
            ),
          ),

          // ── Stories progress bar ──
          Positioned(
            top: topPad + 16, left: 20, right: 20,
            child: _StoriesBar(
              total: _slides.length,
              current: _currentSlide,
            ),
          ),

          // ── Back button ──
          if (_currentSlide > 0)
            Positioned(
              top: topPad + 36, left: 12,
              child: _GlassBackButton(onTap: _prev),
            ),

          // ── Skip onboarding (top-right) ──
          if (!_isLastSlide)
            Positioned(
              top: topPad + 36, right: 12,
              child: _SkipOnboardingButton(onTap: _confirmSkipOnboarding),
            ),

          // ── Footer gradient ──
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: IgnorePointer(
              child: Container(
                height: 120 + bottomPad,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0x80000000), Colors.transparent],
                  ),
                ),
              ),
            ),
          ),

          // ── Footer button ──
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                child: _PrimaryButton(
                  label: _buttonLabel,
                  onTap: _next,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Slide builders ──

  Widget _buildSlide(_SlideData slide) {
    switch (slide.type) {
      case OnboardingSlideType.welcome:
        return _buildBlocksSlide(slide.title, _introContent);
      case OnboardingSlideType.features:
        return _buildBlocksSlide(slide.title, _featuresContent);
      case OnboardingSlideType.dataImport:
        return _buildActionSlide(
          slide: slide,
          actionIcon: Icons.download_rounded,
          actionTitle: 'onboarding_action_restore'.tr(),
          actionSub: 'onboarding_action_restore_sub'.tr(),
          onAction: () => _openSheet(const BackupScreen(fromOnboarding: true)),
        );
      case OnboardingSlideType.api:
        return _buildActionSlide(
          slide: slide,
          actionIcon: Icons.settings_outlined,
          actionTitle: 'onboarding_action_configure_api'.tr(),
          actionSub: 'onboarding_action_configure_sub'.tr(),
          onAction: () => _openSheet(const ApiSettingsScreen(startExpanded: true)),
        );
      case OnboardingSlideType.persona:
        return _buildActionSlide(
          slide: slide,
          actionIcon: Icons.person_add_outlined,
          actionTitle: 'onboarding_action_setup_persona'.tr(),
          actionSub: 'onboarding_action_setup_sub'.tr(),
          onAction: () => _openSheet(const PersonaListScreen()),
        );
      case OnboardingSlideType.layout:
        return _buildLayoutSlide(slide);
      case OnboardingSlideType.allSet:
        return _buildStandardSlide(slide);
    }
  }

  /// Welcome / Features — title + list of info blocks
  Widget _buildBlocksSlide(String title, List<_InfoBlock> blocks) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.tr(),
          style: const TextStyle(
            fontSize: 32, fontWeight: FontWeight.w800,
            color: Colors.white, height: 1.2,
          ),
        ),
        const SizedBox(height: 16),
        ...blocks.map((b) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _IntroBlockCard(block: b),
        )),
      ],
    );
  }

  /// Standard centered slide — icon + title + description
  Widget _buildStandardSlide(_SlideData slide) {
    return SizedBox(
      width: double.infinity,
      child: Column(
        children: [
          const SizedBox(height: 40),
          _IconBubble(icon: slide.icon ?? Icons.check),
          const SizedBox(height: 24),
          Text(
            slide.title.tr(),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 28, fontWeight: FontWeight.w800,
              color: Colors.white, height: 1.3,
            ),
          ),
          if (slide.desc != null) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                slide.desc!.tr(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16, color: context.cs.onSurfaceVariant, height: 1.5,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Standard slide + clickable action card
  Widget _buildActionSlide({
    required _SlideData slide,
    required IconData actionIcon,
    required String actionTitle,
    required String actionSub,
    required VoidCallback onAction,
  }) {
    return SizedBox(
      width: double.infinity,
      child: Column(
        children: [
          const SizedBox(height: 40),
          _IconBubble(icon: slide.icon ?? Icons.settings),
          const SizedBox(height: 24),
          Text(
            slide.title.tr(),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 28, fontWeight: FontWeight.w800,
              color: Colors.white, height: 1.3,
            ),
          ),
          if (slide.desc != null) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                slide.desc!.tr(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16, color: context.cs.onSurfaceVariant, height: 1.5,
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          _ClickableBlock(
            icon: actionIcon,
            title: actionTitle,
            subtitle: actionSub,
            onTap: onAction,
          ),
        ],
      ),
    );
  }

  /// Chat layout picker slide — inline `default` / `bubble` thumbnails reused
  /// from the theme editor's layout picker.
  Widget _buildLayoutSlide(_SlideData slide) {
    final currentLayout =
        ref.watch(themeProvider.select((s) => s.activePreset.chatLayout));
    return SizedBox(
      width: double.infinity,
      child: Column(
        children: [
          const SizedBox(height: 40),
          _IconBubble(icon: slide.icon ?? Icons.view_quilt_outlined),
          const SizedBox(height: 24),
          Text(
            slide.title.tr(),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 28, fontWeight: FontWeight.w800,
              color: Colors.white, height: 1.3,
            ),
          ),
          if (slide.desc != null) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                slide.desc!.tr(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16, color: context.cs.onSurfaceVariant, height: 1.5,
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: LayoutPreviewCard(
                  title: 'layout_default'.tr(),
                  subtitle: 'layout_default_desc'.tr(),
                  isActive: currentLayout == 'default',
                  onTap: () => _setChatLayout('default'),
                  child: const LayoutMiniPreview(layout: 'default'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: LayoutPreviewCard(
                  title: 'layout_bubble'.tr(),
                  subtitle: 'layout_bubble_desc'.tr(),
                  isActive: currentLayout == 'bubble',
                  onTap: () => _setChatLayout('bubble'),
                  child: const LayoutMiniPreview(layout: 'bubble'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _setChatLayout(String layout) async {
    final preset = ref.read(themeProvider).activePreset;
    if (preset.chatLayout == layout) return;
    await ref.read(themeProvider.notifier).updatePreset(
          preset.copyWith(chatLayout: layout),
        );
  }
}

// ---------------------------------------------------------------------------
// Reusable sub-widgets
// ---------------------------------------------------------------------------

/// Stories-style progress bar (Instagram / Telegram-like)
class _StoriesBar extends StatelessWidget {
  final int total;
  final int current;
  const _StoriesBar({required this.total, required this.current});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(total, (i) {
        final filled = i <= current;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(left: i == 0 ? 0 : 3, right: i == total - 1 ? 0 : 3),
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: const Color(0x33808080),
              ),
              child: AnimatedFractionallySizedBox(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
                alignment: Alignment.centerLeft,
                widthFactor: filled ? 1.0 : 0.0,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(2),
                     color: context.cs.primary,
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

/// Glass-morphism pill button to skip the entire onboarding (top-right)
class _SkipOnboardingButton extends StatelessWidget {
  final VoidCallback onTap;
  const _SkipOnboardingButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: context.cs.surface.withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              boxShadow: const [
                BoxShadow(color: Color(0x4D000000), blurRadius: 15, offset: Offset(0, 4)),
              ],
            ),
            child: Text(
              'onboarding_btn_skip_onboarding'.tr(),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Confirmation body shown inside the "Skip Onboarding?" bottom sheet.
class _SkipConfirmSheet extends StatelessWidget {
  final VoidCallback onCancel;
  final VoidCallback onConfirm;
  const _SkipConfirmSheet({required this.onCancel, required this.onConfirm});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'onboarding_skip_confirm_desc'.tr(),
            style: TextStyle(
              fontSize: 15,
              height: 1.5,
              color: context.cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          GestureDetector(
            onTap: onConfirm,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 15),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFFF4444).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: const Color(0xFFFF4444).withValues(alpha: 0.4),
                ),
              ),
              child: Text(
                'onboarding_skip_confirm_confirm'.tr(),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFFF6B6B),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: onCancel,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 15),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: Text(
                'onboarding_skip_confirm_cancel'.tr(),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: context.cs.onSurface,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Glass-morphism circular back button
class _GlassBackButton extends StatelessWidget {
  final VoidCallback onTap;
  const _GlassBackButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: context.cs.surface.withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              boxShadow: const [
                BoxShadow(color: Color(0x4D000000), blurRadius: 15, offset: Offset(0, 4)),
              ],
            ),
            child: Icon(Icons.arrow_back, size: 20, color: context.cs.primary),
          ),
        ),
      ),
    );
  }
}

/// Accent-tinted circular icon bubble (100×100)
class _IconBubble extends StatelessWidget {
  final IconData icon;
  const _IconBubble({required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 100, height: 100,
      decoration: BoxDecoration(
        color: context.cs.primary.withValues(alpha: 0.1),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 48, color: context.cs.primary),
    );
  }
}

/// Info block card (column layout) — for welcome/features slides
class _IntroBlockCard extends StatelessWidget {
  final _InfoBlock block;
  const _IntroBlockCard({required this.block});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x14808080),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(block.icon, size: 48, color: context.cs.primary),
          const SizedBox(height: 8),
          Text(
            block.title.tr(),
            style: const TextStyle(
              fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            block.desc.tr(),
            style: TextStyle(
              fontSize: 15, color: context.cs.onSurfaceVariant, height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Clickable action card — for data import / api / persona slides
class _ClickableBlock extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _ClickableBlock({
    required this.icon, required this.title,
    required this.subtitle, required this.onTap,
  });

  @override
  State<_ClickableBlock> createState() => _ClickableBlockState();
}

class _ClickableBlockState extends State<_ClickableBlock> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) { setState(() => _pressed = false); widget.onTap(); },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _pressed ? const Color(0x26808080) : const Color(0x14808080),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(widget.icon, size: 48, color: context.cs.primary),
              const SizedBox(height: 8),
              Text(
                widget.title,
                style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.subtitle,
                style: TextStyle(
                  fontSize: 15, color: context.cs.onSurfaceVariant, height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-width accent primary button
class _PrimaryButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _PrimaryButton({required this.label, required this.onTap});

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) { setState(() => _pressed = false); widget.onTap(); },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: context.cs.primary,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            widget.label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
