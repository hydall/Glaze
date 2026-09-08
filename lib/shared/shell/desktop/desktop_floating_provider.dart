import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';

import 'desktop_layout_provider.dart';

/// The set of views that open as floating overlay windows on desktop.
const desktopFloatingViews = <String>{
  'menu',
  'settings',
  'theme-settings',
  'sync',
  'backup',
};

final _activeFloatingViewProvider = StateProvider<String?>((ref) => null);

final desktopFloatingProvider = Provider.autoDispose<DesktopFloatingController>(
  (ref) => DesktopFloatingController(ref),
);

class DesktopFloatingController {
  final Ref _ref;

  DesktopFloatingController(this._ref);

  String? get activeView => _ref.read(_activeFloatingViewProvider);

  bool get isOpen => activeView != null;

  void open(String viewId) {
    _ref.read(_activeFloatingViewProvider.notifier).state = viewId;
  }

  void close() {
    _ref.read(_activeFloatingViewProvider.notifier).state = null;
  }
}

final activeFloatingViewProvider = _activeFloatingViewProvider;

bool isDesktopFloatingView(String viewId) =>
    desktopFloatingViews.contains(viewId);

void goOrFloat(BuildContext context, WidgetRef ref, String viewId,
    {String? route}) {
  if (isDesktopLayout(context) && isDesktopFloatingView(viewId)) {
    ref.read(desktopFloatingProvider).open(viewId);
  } else {
    context.go(route ?? '/$viewId');
  }
}
