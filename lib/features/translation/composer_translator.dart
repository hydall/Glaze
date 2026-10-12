import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';

/// The composer's translate action: replaces the draft with its translation,
/// and — while the field still holds exactly that translation — puts the
/// original back on the next tap.
///
/// The result is only ever written into the text field. Sending it is the
/// user's own decision, made after they have read (and maybe edited) it.
class ComposerTranslator extends ChangeNotifier {
  final TextEditingController _controller;

  ComposerTranslator(this._controller);

  CancelToken? _token;
  String? _original;
  String? _translation;

  /// A request is running. The composer locks its field meanwhile, so the
  /// result can never overwrite something typed while it was out.
  bool get busy => _token != null;

  /// The field still shows the last translation, so a tap restores the
  /// original instead of translating again.
  bool get canRestore =>
      _translation != null && _controller.text == _translation;

  /// One tap: cancel a running request, restore the original, or translate.
  /// [onEmpty] runs for an empty draft; [onError] for a failed request.
  Future<void> toggle({
    required Future<String> Function(String text, CancelToken token) translate,
    required VoidCallback onEmpty,
    required void Function(Object error) onError,
  }) async {
    final running = _token;
    if (running != null) {
      running.cancel('Composer translation cancelled');
      _token = null;
      notifyListeners();
      return;
    }
    if (canRestore) {
      _setText(_original ?? '');
      _forget();
      notifyListeners();
      return;
    }
    final source = _controller.text;
    if (source.trim().isEmpty) {
      onEmpty();
      return;
    }
    final token = CancelToken();
    _token = token;
    notifyListeners();
    try {
      final result = await translate(source, token);
      if (token.isCancelled || !identical(_token, token)) return;
      _original = source;
      _translation = result;
      _setText(result);
    } catch (error) {
      if (!token.isCancelled) onError(error);
    } finally {
      if (identical(_token, token)) {
        _token = null;
        notifyListeners();
      }
    }
  }

  void _setText(String text) {
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _forget() {
    _original = null;
    _translation = null;
  }

  @override
  void dispose() {
    _token?.cancel('Composer disposed');
    _token = null;
    super.dispose();
  }
}
