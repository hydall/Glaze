import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/glaze_scaffold.dart';
import 'widgets/character_gallery_view.dart';

/// Standalone `/character/:charId/gallery` route.
///
/// The gallery's primary home is now the character sheet's third tab; this
/// route stays for deep links and shares the same [CharacterGalleryView], so
/// the two cannot drift apart.
class GalleryScreen extends ConsumerWidget {
  final String charId;
  const GalleryScreen({super.key, required this.charId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GlazeScaffold(
      title: 'menu_image_viewer'.tr(),
      onBack: () {
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/characters');
        }
      },
      body: CharacterGalleryView(charId: charId),
    );
  }
}
