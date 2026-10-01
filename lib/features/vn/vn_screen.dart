import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/fullscreen_editor.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_scaffold.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/list_controls.dart';
import '../chat/bridge/chat_webview_environment.dart';
import 'services/vn_generator_service.dart';
import 'services/vn_script.dart';
import 'vn_provider.dart';

/// The 3D visual-novel mode: a walkable first-person game the model writes as
/// a short script, played in its own WebView, apart from any chat.
class VnScreen extends ConsumerStatefulWidget {
  const VnScreen({super.key});

  @override
  ConsumerState<VnScreen> createState() => _VnScreenState();
}

class _VnScreenState extends ConsumerState<VnScreen> {
  late final Future<String> _page = _buildPage();
  InAppWebViewController? _controller;
  bool _pageLoaded = false;
  // WebView2 attaches to a window that already has a frame on screen.
  bool _mountNativeView = !Platform.isWindows;

  @override
  void initState() {
    super.initState();
    if (!_mountNativeView) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _mountNativeView = true);
      });
    }
  }

  static Future<String> _buildPage() async {
    final parts = await Future.wait([
      rootBundle.loadString(kVnPageAsset),
      rootBundle.loadString(kVnThreeAsset),
      rootBundle.loadString(kVnEngineAsset),
    ]);
    return buildVnPage(shell: parts[0], three: parts[1], engine: parts[2]);
  }

  Future<void> _play(String? script) async {
    final controller = _controller;
    if (controller == null || !_pageLoaded || script == null) return;
    final lang = context.locale.languageCode == 'en' ? 'en' : 'ru';
    await controller.evaluateJavascript(
      source:
          'window.VN && VN.load(${jsonEncode(script)}, ${jsonEncode({'lang': lang})});',
    );
  }

  Future<void> _askPremise() async {
    final notifier = ref.read(vnProvider.notifier);
    final language = context.locale.languageCode == 'en' ? 'English' : 'Russian';
    await GlazeBottomSheet.show<void>(
      context,
      title: 'vn_generate'.tr(),
      input: BottomSheetInput(
        placeholder: 'vn_premise_hint'.tr(),
        confirmLabel: 'vn_generate_confirm'.tr(),
        onConfirm: (premise) {
          Navigator.of(context, rootNavigator: true).pop();
          unawaited(_generate(notifier, premise, language));
        },
      ),
    );
  }

  Future<void> _generate(
    VnNotifier notifier,
    String premise,
    String language,
  ) async {
    try {
      await notifier.generate(premise: premise, language: language);
    } on VnGenerationException catch (e) {
      GlazeToast.showWithoutContext(switch (e.failure) {
        VnGenerationFailure.noApi => 'vn_err_no_api'.tr(),
        VnGenerationFailure.incompleteApi => 'vn_err_incomplete_api'.tr(),
        VnGenerationFailure.noScenes => 'vn_err_no_scenes'.tr(),
      }, isError: true);
    } catch (e) {
      GlazeToast.showWithoutContext(
        'vn_err_failed'.tr(args: [e.toString()]),
        isError: true,
      );
    }
  }

  Future<void> _editScript() async {
    final current = ref.read(vnProvider).script ?? '';
    var edited = current;
    await FullscreenEditorScreen.show(
      context,
      title: 'vn_script'.tr(),
      initialValue: current,
      autofocus: false,
      onChanged: (value) => edited = value,
    );
    if (edited != current) ref.read(vnProvider.notifier).setScript(edited);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(vnProvider.select((s) => s.script), (_, script) {
      unawaited(_play(script));
    });
    final generating = ref.watch(vnProvider.select((s) => s.generating));

    return GlazeScaffold(
      title: 'vn_title'.tr(),
      actions: [
        GlazeActionChip(
          icon: Icons.auto_awesome,
          tooltip: 'vn_generate'.tr(),
          onTap: generating ? () {} : _askPremise,
        ),
        GlazeActionChip(
          icon: Icons.code,
          tooltip: 'vn_script'.tr(),
          onTap: _editScript,
        ),
        GlazeActionChip(
          icon: Icons.restart_alt,
          tooltip: 'vn_sample'.tr(),
          onTap: () => unawaited(ref.read(vnProvider.notifier).loadSample()),
        ),
      ],
      body: Stack(
        children: [
          Positioned.fill(
            child: FutureBuilder<String>(
              future: _page,
              builder: (context, snapshot) {
                final html = snapshot.data;
                if (html == null || !_mountNativeView) {
                  return const Center(child: GlazeSpinner());
                }
                return InAppWebView(
                  webViewEnvironment: chatWebViewEnvironment,
                  initialData: InAppWebViewInitialData(data: html),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    supportZoom: false,
                    disableContextMenu: true,
                    disableHorizontalScroll: true,
                    disableVerticalScroll: true,
                    mediaPlaybackRequiresUserGesture: true,
                    isInspectable: kDebugMode,
                  ),
                  onWebViewCreated: (controller) {
                    _controller = controller;
                    controller.addJavaScriptHandler(
                      handlerName: 'vn',
                      callback: _onEngineEvent,
                    );
                  },
                  onLoadStop: (_, _) {
                    _pageLoaded = true;
                    unawaited(_play(ref.read(vnProvider).script));
                  },
                );
              },
            ),
          ),
          if (generating) const _GeneratingBadge(),
        ],
      ),
    );
  }

  void _onEngineEvent(List<dynamic> args) {
    if (!kDebugMode || args.isEmpty) return;
    debugPrint('[VN3D] ${args.first}');
  }
}

class _GeneratingBadge extends StatelessWidget {
  const _GeneratingBadge();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: GlassSurface(
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const GlazeSpinner(size: 16, strokeWidth: 2),
                const SizedBox(width: 10),
                Text(
                  'vn_generating'.tr(),
                  style: TextStyle(color: context.cs.onSurface, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
