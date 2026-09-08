import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

final rightSidebarSheetProvider =
    StateProvider.autoDispose<Widget?>((ref) => null);

final rightSidebarSheetOccupiedProvider = Provider.autoDispose<bool>((ref) {
  return ref.watch(rightSidebarSheetProvider) != null;
});

void showSheetInRightSidebar(WidgetRef ref, Widget sheet) {
  ref.read(rightSidebarSheetProvider.notifier).state = sheet;
}

void closeRightSidebarSheet(WidgetRef ref) {
  ref.read(rightSidebarSheetProvider.notifier).state = null;
}
