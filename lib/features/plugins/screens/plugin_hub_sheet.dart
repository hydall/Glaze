import 'package:cached_network_image/cached_network_image.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/navigation/router.dart';
import '../../../core/utils/error_format.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_error_block.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/menu_group.dart';
import '../compat/tavo/tavo_hub.dart';
import '../providers/plugin_hub_provider.dart';
import '../providers/plugin_library_provider.dart';
import '../services/plugin_package_reader.dart';
import '../widgets/plugin_text_widgets.dart';
import 'plugins_screen.dart';

/// Opens the plugin a hub link points at in a sheet instead of the browser.
/// False when [uri] is not a hub plugin page.
bool openPluginHubLink(BuildContext context, Uri uri) {
  final ref = tavoHubPluginRef(uri);
  if (ref == null) return false;
  GlazeBottomSheet.show<void>(
    context,
    title: 'plugins_hub_title'.tr(),
    child: PluginHubView(pluginRef: ref),
  );
  return true;
}

/// [openPluginHubLink] for callers without a context of their own: links
/// tapped in chats and descriptions, and links the system hands the app.
bool openPluginHubLinkInApp(Uri uri) {
  final context = rootNavigatorKey.currentContext;
  if (context == null || tavoHubPluginRef(uri) == null) return false;
  return openPluginHubLink(context, uri);
}

/// One hub plugin: what the hub says about it and the button that installs
/// or updates it.
class PluginHubView extends ConsumerStatefulWidget {
  const PluginHubView({super.key, required this.pluginRef});

  final String pluginRef;

  @override
  ConsumerState<PluginHubView> createState() => _PluginHubViewState();
}

class _PluginHubViewState extends ConsumerState<PluginHubView> {
  late Future<TavoHubPlugin> _plugin;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() =>
      _plugin = ref.read(tavoHubClientProvider).plugin(widget.pluginRef);

  Future<void> _install(TavoHubPlugin plugin) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await ref.read(tavoHubClientProvider).download(plugin);
      final package = readPluginPackage(bytes);
      if (package.manifest.id != plugin.packageId) {
        throw const TavoHubException(
          'The package does not match the plugin page',
        );
      }
      if (!mounted) return;
      final installed = await installPluginPackage(
        context,
        ref,
        package,
        hubSlug: plugin.slug,
      );
      if (installed != null) ref.invalidate(pluginHubUpdatesProvider);
    } catch (e) {
      if (mounted) setState(() => _error = formatError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<TavoHubPlugin>(
      future: _plugin,
      builder: (context, snap) {
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GlazeErrorBlock(message: formatError(snap.error!)),
                const SizedBox(height: 12),
                GlazeActionButton(
                  icon: Icons.refresh_rounded,
                  label: 'plugins_hub_retry'.tr(),
                  expand: true,
                  onTap: () => setState(_load),
                ),
              ],
            ),
          );
        }
        final plugin = snap.data;
        if (plugin == null) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: GlazeSpinner(color: context.cs.primary),
              ),
            ),
          );
        }
        return _details(context, plugin);
      },
    );
  }

  Widget _details(BuildContext context, TavoHubPlugin plugin) {
    final installed = (ref.watch(pluginLibraryProvider).value ?? const [])
        .where((x) => x.id == plugin.packageId)
        .firstOrNull;
    final newer =
        installed != null &&
        isNewerPluginVersion(plugin.version, installed.manifest.version);
    final locale = context.locale.toLanguageTag();
    final updated = plugin.updatedAt;
    final safety = plugin.safety;
    final warn = safety == 'warn' || safety == 'fail';

    final Widget action;
    if (!plugin.free) {
      action = GlazeActionButton(
        icon: Icons.lock_outline_rounded,
        label: 'plugins_hub_paid'.tr(),
        expand: true,
        onTap: () =>
            launchUrl(plugin.pageUrl, mode: LaunchMode.externalApplication),
      );
    } else if (installed != null && !newer) {
      action = GlazeActionButton(
        icon: Icons.check_rounded,
        label: 'plugins_hub_installed'.tr(),
        expand: true,
        onTap: () {},
      );
    } else {
      action = GlazeActionButton(
        icon: installed == null
            ? Icons.download_rounded
            : Icons.system_update_alt_rounded,
        label: _busy
            ? 'plugins_hub_downloading'.tr()
            : installed == null
            ? 'plugins_hub_install'.tr()
            : 'plugins_hub_update'.tr(namedArgs: {'version': plugin.version}),
        tone: GlazeActionTone.primary,
        expand: true,
        busy: _busy,
        onTap: () {
          if (!_busy) _install(plugin);
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (plugin.iconUrl != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: CachedNetworkImage(
                  imageUrl: plugin.iconUrl!,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        MenuGroup(
          header: plugin.name,
          headerIcon: Icons.extension_rounded,
          items: [
            if (plugin.author != null)
              MenuItem(
                icon: Icons.person_outline_rounded,
                label: 'plugins_author'.tr(),
                value: plugin.author,
                onTap: () {},
              ),
            if (plugin.description case final d?)
              PluginDescriptionItem(text: d, initiallyExpanded: true),
            pluginVersionItem(
              context,
              version: installed != null && newer
                  ? '${installed.manifest.version} → ${plugin.version}'
                  : plugin.version,
              releaseNotes: plugin.changelog,
            ),
            if (plugin.downloads != null)
              MenuItem(
                icon: Icons.download_outlined,
                label: 'plugins_hub_downloads'.tr(),
                value: NumberFormat.decimalPattern(
                  locale,
                ).format(plugin.downloads),
                onTap: () {},
              ),
            if (updated != null)
              MenuItem(
                icon: Icons.update_rounded,
                label: 'plugins_hub_updated'.tr(),
                value: DateFormat.yMMMd(locale).format(updated.toLocal()),
                onTap: () {},
              ),
            if (warn)
              MenuItem(
                icon: Icons.gpp_maybe_outlined,
                label: 'plugins_hub_review_warn'.tr(),
                subtitle: 'plugins_hub_review_warn_hint'.tr(),
                onTap: () {},
              ),
            MenuItem(
              icon: Icons.open_in_new_rounded,
              label: 'plugins_hub_open_browser'.tr(),
              onTap: () => launchUrl(
                plugin.pageUrl,
                mode: LaunchMode.externalApplication,
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                GlazeErrorBlock(message: _error!),
                const SizedBox(height: 12),
              ],
              action,
            ],
          ),
        ),
      ],
    );
  }
}
