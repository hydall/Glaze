class StreamAccumulator {
  final String? tagStart;
  final String? tagEnd;
  final bool hasInlineTags;
  final String? headerModel;
  final String? headerInline;

  StringBuffer _raw = StringBuffer();
  StringBuffer _text = StringBuffer();
  StringBuffer _externalReasoning = StringBuffer();
  StringBuffer _inlineReasoning = StringBuffer();
  StringBuffer _tagCandidate = StringBuffer();
  StringBuffer _variantCandidate = StringBuffer();
  bool _hasExternalReasoning = false;
  bool _splitDone = false;
  _ParsePhase _phase = _ParsePhase.beforeReasoning;
  bool _variantOpenPossible = false;
  bool _variantClosePossible = false;
  bool _variantOpenTail = false;
  bool _variantCloseTail = false;

  StreamAccumulator({
    this.tagStart,
    this.tagEnd,
    this.hasInlineTags = false,
    this.headerModel,
    this.headerInline,
  });

  bool get _parsesInline => hasInlineTags && tagStart != null && tagEnd != null;

  bool get _normalizesThinkVariants {
    if (!_parsesInline) return false;
    final startLower = tagStart!.toLowerCase();
    final endLower = tagEnd!.toLowerCase();
    final usesThink =
        startLower.startsWith('<think') &&
        !startLower.startsWith('<thinking') &&
        endLower.startsWith('</think') &&
        !endLower.startsWith('</thinking');
    final usesThinking =
        startLower.startsWith('<thinking') && endLower.startsWith('</thinking');
    return usesThink || usesThinking;
  }

  String get _alternateOpen =>
      tagStart!.toLowerCase().startsWith('<thinking') ? '<think' : '<thinking';
  String get _alternateClose =>
      tagEnd!.toLowerCase().startsWith('</thinking') ? '</think' : '</thinking';

  void consumeDelta(String delta, {String? reasoningDelta}) {
    if (reasoningDelta != null && reasoningDelta.isNotEmpty) {
      _externalReasoning.write(reasoningDelta);
      _hasExternalReasoning = true;
    }

    if (!_parsesInline) {
      _text.write(delta);
      return;
    }

    _openEmptyTagIfNeeded();
    for (var i = 0; i < delta.length; i++) {
      _consumeVariantChar(delta[i]);
    }
  }

  void _openEmptyTagIfNeeded() {
    if (_phase != _ParsePhase.beforeReasoning || tagStart!.isNotEmpty) return;
    _phase = _ParsePhase.inReasoning;
    _trimTextLeft();
    if (tagEnd!.isEmpty) _closeReasoning();
  }

  void _consumeVariantChar(String char) {
    if (!_normalizesThinkVariants) {
      _emitNormalized(char);
      return;
    }

    if (_variantCandidate.isEmpty) {
      if (char != '<') {
        _emitNormalized(char);
        return;
      }
      _variantCandidate.write(char);
      _variantOpenPossible = true;
      _variantClosePossible = true;
      return;
    }

    _variantCandidate.write(char);
    final index = _variantCandidate.length - 1;
    final openComplete = _advanceVariant(
      char,
      index,
      _alternateOpen,
      isOpen: true,
    );
    final closeComplete = _advanceVariant(
      char,
      index,
      _alternateClose,
      isOpen: false,
    );
    if (openComplete || closeComplete) {
      _clearVariantCandidate();
      _emitNormalized(openComplete ? tagStart! : tagEnd!);
    } else if (!_variantOpenPossible && !_variantClosePossible) {
      _rejectVariantCandidate();
    }
  }

  bool _advanceVariant(
    String char,
    int index,
    String literal, {
    required bool isOpen,
  }) {
    var possible = isOpen ? _variantOpenPossible : _variantClosePossible;
    var inTail = isOpen ? _variantOpenTail : _variantCloseTail;
    if (!possible) return false;

    if (index < literal.length) {
      possible = char.toLowerCase() == literal[index];
    } else if (!inTail) {
      if (_isWordCharacter(char)) {
        possible = false;
      } else if (char == '>') {
        return true;
      } else {
        inTail = true;
      }
    } else if (char == '>') {
      return true;
    }

    if (isOpen) {
      _variantOpenPossible = possible;
      _variantOpenTail = inTail;
    } else {
      _variantClosePossible = possible;
      _variantCloseTail = inTail;
    }
    return false;
  }

  bool _isWordCharacter(String char) {
    final code = char.codeUnitAt(0);
    return (code >= 0x30 && code <= 0x39) ||
        (code >= 0x41 && code <= 0x5a) ||
        code == 0x5f ||
        (code >= 0x61 && code <= 0x7a);
  }

  void _rejectVariantCandidate() {
    final rejected = _variantCandidate.toString();
    final restart = rejected.lastIndexOf('<');
    _clearVariantCandidate();
    final committedEnd = restart > 0 ? restart : 1;
    _emitNormalized(rejected.substring(0, committedEnd));
    for (var i = committedEnd; i < rejected.length; i++) {
      _consumeVariantChar(rejected[i]);
    }
  }

  void _clearVariantCandidate() {
    _variantCandidate = StringBuffer();
    _variantOpenPossible = false;
    _variantClosePossible = false;
    _variantOpenTail = false;
    _variantCloseTail = false;
  }

  void _emitNormalized(String value) {
    _raw.write(value);
    if (_phase == _ParsePhase.afterReasoning) {
      _writeVisibleText(value);
      return;
    }

    for (var i = 0; i < value.length; i++) {
      _consumeTagChar(value[i]);
    }
  }

  void _consumeTagChar(String char) {
    final target = _phase == _ParsePhase.beforeReasoning ? tagStart! : tagEnd!;
    if (target.isEmpty) {
      if (_phase == _ParsePhase.inReasoning) _closeReasoning();
      _writeVisibleText(char);
      return;
    }

    final index = _tagCandidate.length;
    if (char == target[index]) {
      _tagCandidate.write(char);
      if (_tagCandidate.length == target.length) {
        _tagCandidate = StringBuffer();
        if (_phase == _ParsePhase.beforeReasoning) {
          _phase = _ParsePhase.inReasoning;
          _trimTextLeft();
          if (tagEnd!.isEmpty) _closeReasoning();
        } else {
          _closeReasoning();
        }
      }
      return;
    }

    final rejected = '${_tagCandidate.toString()}$char';
    _tagCandidate = StringBuffer();
    _writeCurrent(rejected[0]);
    for (var i = 1; i < rejected.length; i++) {
      _consumeTagChar(rejected[i]);
    }
  }

  void _closeReasoning() {
    _phase = _ParsePhase.afterReasoning;
    _splitDone = true;
  }

  void _writeCurrent(String value) {
    if (_phase == _ParsePhase.inReasoning) {
      _inlineReasoning.write(value);
    } else {
      _writeVisibleText(value);
    }
  }

  void _writeVisibleText(String value) {
    if (_phase == _ParsePhase.afterReasoning && _text.isEmpty) {
      value = value.trimLeft();
    }
    _text.write(value);
  }

  void _trimTextLeft() {
    final trimmed = _text.toString().trimLeft();
    _text = StringBuffer(trimmed);
  }

  void flush() {}

  String _combineReasoning() {
    final external = _externalReasoning.toString().trim();
    final inline = _inlineReasoningWithPending.trim();

    if (external.isNotEmpty && inline.isNotEmpty) {
      final hModel = headerModel ?? '';
      final hInline = headerInline ?? '';
      final prefix = hModel.isNotEmpty ? '$hModel\n' : '';
      final midfix = hInline.isNotEmpty ? '$hInline\n' : '';
      return '$prefix$external\n\n---\n\n$midfix$inline';
    }
    return inline.isNotEmpty ? inline : external;
  }

  String get _pending =>
      '${_tagCandidate.toString()}${_variantCandidate.toString()}';

  String get _inlineReasoningWithPending =>
      '${_inlineReasoning.toString()}${_phase == _ParsePhase.inReasoning ? _pending : ''}';

  String get text =>
      '${_text.toString()}${_phase == _ParsePhase.inReasoning ? '' : _pending}';
  String get reasoning => _combineReasoning();
  bool get hasExternalReasoning => _hasExternalReasoning;
  bool get splitDone => _splitDone;

  String get raw =>
      _parsesInline ? '${_raw.toString()}${_variantCandidate.toString()}' : '';

  void reset() {
    _raw = StringBuffer();
    _text = StringBuffer();
    _externalReasoning = StringBuffer();
    _inlineReasoning = StringBuffer();
    _tagCandidate = StringBuffer();
    _clearVariantCandidate();
    _hasExternalReasoning = false;
    _splitDone = false;
    _phase = _ParsePhase.beforeReasoning;
  }
}

enum _ParsePhase { beforeReasoning, inReasoning, afterReasoning }
