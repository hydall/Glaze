import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/platform/haptics.dart';

const String kKeyboardHeightPref = 'chat_last_keyboard_height';
const double _kDefaultKeyboardHeight = 320;

/// Identifies which content the drawer is currently showing.
enum DrawerPanel { magic, quickReplies }

class ChatDrawerController extends ChangeNotifier {
  final FocusNode _inputFocus = FocusNode();
  final AnimationController _drawerAnimController;
  late final Animation<double> drawerAnim;

  bool _drawerOpen = false;
  bool _switchingToDrawer = false;
  DrawerPanel _activePanel = DrawerPanel.magic;
  double _lastKeyboardHeight = _kDefaultKeyboardHeight;
  double _activeDrawerHeight = _kDefaultKeyboardHeight;

  double _tempMaxHeight = 0;
  Timer? _heightTimer;
  bool _batterySaverMode = false;

  final Future<double> Function() _readKeyboardHeight;
  final Future<void> Function(double) _persistKeyboardHeight;

  ChatDrawerController({
    required TickerProvider vsync,
    required this._readKeyboardHeight,
    required this._persistKeyboardHeight,
  }) : _drawerAnimController = AnimationController(
         vsync: vsync,
         duration: const Duration(milliseconds: 260),
       ) {
    drawerAnim = CurvedAnimation(
      parent: _drawerAnimController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _inputFocus.addListener(_onFocusChanged);
  }

  FocusNode get inputFocus => _inputFocus;
  bool get drawerOpen => _drawerOpen;
  bool get switchingToDrawer => _switchingToDrawer;
  DrawerPanel get activePanel => _activePanel;
  double get lastKeyboardHeight => _lastKeyboardHeight;
  double get activeDrawerHeight => _activeDrawerHeight;
  bool get isDrawerAnimating => _drawerAnimController.isAnimating;

  void setBatterySaverMode(bool enabled) {
    _batterySaverMode = enabled;
  }

  Future<void> restoreKeyboardHeight() async {
    try {
      final saved = await _readKeyboardHeight();
      if (saved > 200) {
        _lastKeyboardHeight = saved;
        notifyListeners();
      }
    } catch (_) {}
  }

  void toggleDrawer(
    BuildContext context, {
    DrawerPanel panel = DrawerPanel.magic,
  }) {
    if (_drawerOpen) {
      if (_activePanel == panel) {
        _drawerOpen = false;
        _drawerAnimController.reverse();
      } else {
        _activePanel = panel;
        Haptics.selectionClick();
      }
      notifyListeners();
      return;
    }
    _activePanel = panel;
    Haptics.selectionClick();
    _activeDrawerHeight = _lastKeyboardHeight;

    final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
    if (keyboardHeight > 0 || _inputFocus.hasFocus) {
      _switchingToDrawer = true;
      if (_batterySaverMode) {
        _drawerOpen = true;
        _drawerAnimController.forward();
      }
      _inputFocus.unfocus();
      notifyListeners();
    } else {
      _drawerOpen = true;
      _drawerAnimController.forward();
      notifyListeners();
    }
  }

  void closeDrawer() {
    if (!_drawerOpen && !_switchingToDrawer) return;
    _drawerOpen = false;
    _switchingToDrawer = false;
    _drawerAnimController.reverse();
    notifyListeners();
  }

  void _onFocusChanged() {
    if (_inputFocus.hasFocus && _drawerOpen) {
      _drawerOpen = false;
      _activeDrawerHeight = _lastKeyboardHeight;
      _drawerAnimController.reverse();
      notifyListeners();
    }
  }

  void handleKeyboardFrame(double keyboardHeight) {
    if (keyboardHeight > 200 && _inputFocus.hasFocus) {
      if (keyboardHeight > _tempMaxHeight) {
        _tempMaxHeight = keyboardHeight;
        _heightTimer?.cancel();
        _heightTimer = Timer(const Duration(milliseconds: 300), () {
          if (_tempMaxHeight > 200 && _tempMaxHeight != _lastKeyboardHeight) {
            _lastKeyboardHeight = _tempMaxHeight;
            _persistKeyboardHeight(_lastKeyboardHeight);
            notifyListeners();
          }
        });
      }
    }

    if (!_inputFocus.hasFocus && _tempMaxHeight != 0) {
      _tempMaxHeight = 0;
    }
  }

  bool checkSwitchingTransition(double keyboardHeight) {
    final threshold = _batterySaverMode ? 20.0 : 0.0;
    if (_switchingToDrawer && keyboardHeight <= threshold) {
      _switchingToDrawer = false;
      if (!_drawerOpen) {
        _drawerOpen = true;
      }
      if (_drawerAnimController.value < 1.0) {
        _drawerAnimController.forward();
      }
      notifyListeners();
      return true;
    }
    return false;
  }

  bool checkDrawerCollision(double keyboardHeight) {
    if (keyboardHeight > 0 && _drawerOpen && !_switchingToDrawer) {
      closeDrawer();
      return true;
    }
    return false;
  }

  double computeTargetBottomPanelInset(double keyboardHeight, double safeBottom) {
    final targetDrawerInset = (_drawerOpen || _switchingToDrawer)
        ? _activeDrawerHeight
        : 0.0;
    final isIdle = keyboardHeight == 0 &&
        !_drawerOpen &&
        !_switchingToDrawer &&
        _drawerAnimController.value == 0;
    final bottomPadding = isIdle ? safeBottom : 0.0;
    return math.max(targetDrawerInset, keyboardHeight) + bottomPadding;
  }

  bool canPop() => !_drawerOpen && !_inputFocus.hasFocus;

  @override
  void dispose() {
    _heightTimer?.cancel();
    _inputFocus.removeListener(_onFocusChanged);
    _inputFocus.dispose();
    _drawerAnimController.dispose();
    super.dispose();
  }
}