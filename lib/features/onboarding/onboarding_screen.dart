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
import '../../shared/shell/desktop/desktop_layout_provider.dart';
import 'onboarding_models.dart';
import 'widgets/onboarding_desktop_wizard.dart';
import 'widgets/onboarding_widgets.dart';

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

  bool get _isLastSlide => _currentSlide == onboardingSlides.length - 1;

  String get _buttonLabel {
    if (_isLastSlide) return 'onboarding_btn_start'.tr();
    switch (onboardingSlides[_currentSlide].type) {
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
      setState(() {
        _direction = 1;
        _currentSlide++;
      });
    }
  }

  void _prev() {
    if (_currentSlide > 0) {
      setState(() {
        _direction = -1;
        _currentSlide--;
      });
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
      child: OnboardingSkipConfirmSheet(
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

  /// Onboarding is pushed on the root navigator, above the shell, so there is
  /// no `DesktopScope` to read here — apply the shell's own rule directly
  /// (see `DesktopShell.build`).
  bool _isDesktop(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= 768 &&
      !ref.watch(forceMobileLayoutProvider);

  @override
  Widget build(BuildContext context) {
    if (_isDesktop(context)) return _buildDesktop(context);

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
                    children: <Widget>[...previousChildren, ?currentChild],
                  );
                },
                transitionBuilder: (child, anim) {
                  final dir = (child.key == ValueKey(_currentSlide))
                      ? _direction
                      : -_direction;
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
                  child: _buildSlide(onboardingSlides[_currentSlide]),
                ),
              ),
            ),
          ),

          // ── Header gradient ──
          Positioned(
            top: 0,
            left: 0,
            right: 0,
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
            top: topPad + 16,
            left: 20,
            right: 20,
            child: OnboardingStoriesBar(
              total: onboardingSlides.length,
              current: _currentSlide,
            ),
          ),

          // ── Back button ──
          if (_currentSlide > 0)
            Positioned(
              top: topPad + 36,
              left: 12,
              child: OnboardingGlassBackButton(onTap: _prev),
            ),

          // ── Skip onboarding (top-right) ──
          if (!_isLastSlide)
            Positioned(
              top: topPad + 36,
              right: 12,
              child: OnboardingSkipButton(onTap: _confirmSkipOnboarding),
            ),

          // ── Footer gradient ──
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
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
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                child: OnboardingPrimaryButton(
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

  /// The wide-window flow: the same slides, laid out as the Vue wizard.
  Widget _buildDesktop(BuildContext context) {
    final slide = onboardingSlides[_currentSlide];
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0E),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 320),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, anim) {
          final dir = (child.key == ValueKey(_currentSlide))
              ? _direction
              : -_direction;
          return FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween(
                begin: Offset(0.04 * dir, 0),
                end: Offset.zero,
              ).animate(anim),
              child: child,
            ),
          );
        },
        child: KeyedSubtree(
          key: ValueKey(_currentSlide),
          child: OnboardingDesktopWizard(
            slideIndex: _currentSlide,
            slideCount: onboardingSlides.length,
            icon: _slideIcon(slide),
            title: slide.title,
            description: slide.desc,
            body: _slideBody(slide),
            buttonLabel: _buttonLabel,
            onNext: _next,
            onBack: _currentSlide > 0 ? _prev : null,
            onSkip: _isLastSlide ? null : _confirmSkipOnboarding,
          ),
        ),
      ),
    );
  }

  // ── Slide builders ──

  /// The one thing a slide asks the user to open, when it has one. Shared by
  /// the phone slide and the desktop wizard so the two never drift apart.
  ({IconData icon, String title, String sub, VoidCallback onTap})? _slideAction(
    OnboardingSlideData slide,
  ) {
    switch (slide.type) {
      case OnboardingSlideType.dataImport:
        return (
          icon: Icons.download_rounded,
          title: 'onboarding_action_restore'.tr(),
          sub: 'onboarding_action_restore_sub'.tr(),
          onTap: () => _openSheet(const BackupScreen(fromOnboarding: true)),
        );
      case OnboardingSlideType.api:
        return (
          icon: Icons.settings_outlined,
          title: 'onboarding_action_configure_api'.tr(),
          sub: 'onboarding_action_configure_sub'.tr(),
          onTap: () => _openSheet(const ApiSettingsScreen(startExpanded: true)),
        );
      case OnboardingSlideType.persona:
        return (
          icon: Icons.person_add_outlined,
          title: 'onboarding_action_setup_persona'.tr(),
          sub: 'onboarding_action_setup_sub'.tr(),
          onTap: () => _openSheet(const PersonaListScreen()),
        );
      default:
        return null;
    }
  }

  /// The info blocks a slide lists, when it lists any.
  List<OnboardingInfoBlock>? _slideBlocks(OnboardingSlideData slide) {
    return switch (slide.type) {
      OnboardingSlideType.welcome => onboardingIntroContent,
      OnboardingSlideType.features => onboardingFeaturesContent,
      _ => null,
    };
  }

  Widget _buildSlide(OnboardingSlideData slide) {
    switch (slide.type) {
      case OnboardingSlideType.welcome:
      case OnboardingSlideType.features:
        return _buildBlocksSlide(slide.title, _slideBlocks(slide)!);
      case OnboardingSlideType.dataImport:
      case OnboardingSlideType.api:
      case OnboardingSlideType.persona:
        final action = _slideAction(slide)!;
        return _buildActionSlide(
          slide: slide,
          actionIcon: action.icon,
          actionTitle: action.title,
          actionSub: action.sub,
          onAction: action.onTap,
        );
      case OnboardingSlideType.layout:
        return _buildLayoutSlide(slide);
      case OnboardingSlideType.allSet:
        return _buildStandardSlide(slide);
    }
  }

  /// The right-hand pane's content in the desktop wizard: whatever the slide
  /// offers below its title and description.
  Widget? _slideBody(OnboardingSlideData slide) {
    final blocks = _slideBlocks(slide);
    if (blocks != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: blocks
            .map(
              (b) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: OnboardingIntroBlockCard(block: b),
              ),
            )
            .toList(),
      );
    }
    final action = _slideAction(slide);
    if (action != null) {
      return OnboardingClickableBlock(
        icon: action.icon,
        title: action.title,
        subtitle: action.sub,
        onTap: action.onTap,
      );
    }
    if (slide.type == OnboardingSlideType.layout) return _buildLayoutPicker();
    return null;
  }

  /// Icon shown in the wizard's visual pane. Welcome and Features carry no
  /// icon of their own, so they borrow their first block's — the same
  /// fallback the Vue wizard used (`slides[i].icon || introContent[0].icon`).
  IconData _slideIcon(OnboardingSlideData slide) =>
      slide.icon ?? _slideBlocks(slide)?.first.icon ?? Icons.layers_outlined;

  /// Welcome / Features — title + list of info blocks
  Widget _buildBlocksSlide(String title, List<OnboardingInfoBlock> blocks) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.tr(),
          style: const TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 16),
        ...blocks.map(
          (b) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: OnboardingIntroBlockCard(block: b),
          ),
        ),
      ],
    );
  }

  /// Standard centered slide — icon + title + description
  Widget _buildStandardSlide(OnboardingSlideData slide) {
    return SizedBox(
      width: double.infinity,
      child: Column(
        children: [
          const SizedBox(height: 40),
          OnboardingIconBubble(icon: slide.icon ?? Icons.check),
          const SizedBox(height: 24),
          Text(
            slide.title.tr(),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1.3,
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
                  fontSize: 16,
                  color: context.cs.onSurfaceVariant,
                  height: 1.5,
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
    required OnboardingSlideData slide,
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
          OnboardingIconBubble(icon: slide.icon ?? Icons.settings),
          const SizedBox(height: 24),
          Text(
            slide.title.tr(),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1.3,
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
                  fontSize: 16,
                  color: context.cs.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          OnboardingClickableBlock(
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
  Widget _buildLayoutSlide(OnboardingSlideData slide) {
    return SizedBox(
      width: double.infinity,
      child: Column(
        children: [
          const SizedBox(height: 40),
          OnboardingIconBubble(icon: slide.icon ?? Icons.view_quilt_outlined),
          const SizedBox(height: 24),
          Text(
            slide.title.tr(),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1.3,
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
                  fontSize: 16,
                  color: context.cs.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          _buildLayoutPicker(),
        ],
      ),
    );
  }

  /// The `default` / `bubble` thumbnails, shared by the phone slide and the
  /// desktop wizard's content pane.
  Widget _buildLayoutPicker() {
    final currentLayout = ref.watch(
      themeProvider.select((s) => s.activePreset.chatLayout),
    );
    return Row(
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
    );
  }

  Future<void> _setChatLayout(String layout) async {
    final preset = ref.read(themeProvider).activePreset;
    if (preset.chatLayout == layout) return;
    await ref
        .read(themeProvider.notifier)
        .updatePreset(preset.copyWith(chatLayout: layout));
  }
}
