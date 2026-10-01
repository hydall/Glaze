import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/state/db_provider.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../vn_provider.dart';

/// Asks for the idea of a new novel, files it in the chat list and opens it;
/// the novel screen then writes the setup passes.
Future<void> showNewVnSheet(BuildContext context, WidgetRef ref) async {
  final repo = ref.read(chatRepoProvider);
  final router = GoRouter.of(context);
  final rootNav = Navigator.of(context, rootNavigator: true);
  await GlazeBottomSheet.show<void>(
    context,
    title: 'vn_new'.tr(),
    input: BottomSheetInput(
      placeholder: 'vn_premise_hint'.tr(),
      confirmLabel: 'vn_generate_confirm'.tr(),
      onConfirm: (premise) {
        rootNav.pop();
        unawaited(() async {
          final sessionId = await createVnSession(repo, premise);
          await router.push('/vn/$sessionId');
        }());
      },
    ),
  );
}
