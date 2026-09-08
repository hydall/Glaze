import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../../core/models/lorebook.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_scaffold.dart';
import '../../../shared/widgets/help_tip.dart';

class LorebookPerBookSettingsScreen extends StatefulWidget {
  final LorebookSettings? settings;
  final LorebookGlobalSettings? globalSettings;

  const LorebookPerBookSettingsScreen({super.key, this.settings, this.globalSettings});

  @override
  State<LorebookPerBookSettingsScreen> createState() =>
      _LorebookPerBookSettingsScreenState();
}

class _LorebookPerBookSettingsScreenState
    extends State<LorebookPerBookSettingsScreen> {
  late LorebookSettings _settings;
  bool _hasCustom = false;

  @override
  void initState() {
    super.initState();
    _hasCustom = widget.settings != null;
    _settings = widget.settings ?? _settingsFromGlobal(widget.globalSettings);
  }

  LorebookSettings _settingsFromGlobal(LorebookGlobalSettings? g) {
    if (g == null) return const LorebookSettings();
    return LorebookSettings(
      scanDepth: null,
      maxInjectedEntries: null,
      recursiveScan: g.recursiveScan,
      caseSensitive: g.caseSensitive,
      matchWholeWords: g.matchWholeWords ? 'true' : 'false',
      vectorSearchEnabled: true,
      embeddingTarget: 'content',
      vectorThreshold: g.vectorThreshold,
      vectorTopK: g.vectorTopK,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.cs.surface,
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: GlazeAppBar(
                title: 'title_lorebook_settings'.tr(),
                leading: BackButton(onPressed: () => _pop(context)),
                actions: [
                  TextButton(
                    onPressed: _hasCustom ? _resetToGlobal : null,
                    child: Text(
                      'lorebook_reset_to_global'.tr(),
                      style: TextStyle(
                        fontSize: 12,
                        color: _hasCustom
                            ? context.cs.primary
                            : context.cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!_hasCustom)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: context.cs.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: context.cs.primary.withValues(alpha: 0.2)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: context.cs.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'lorebook_using_global_defaults'.tr(),
                        style: TextStyle(
                            fontSize: 12, color: context.cs.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── Scanning ──────────────────────────────────────────────
                _SectionHeader('section_scan_recursion'.tr(), helpTerm: 'lorebook-recursion'),
                _NumberField(
                  label: 'label_scan_depth_lore'.tr(),
                  value: _settings.scanDepth ?? 0,
                  min: 0,
                  max: 100,
                  hint: 'lorebook_global_default_hint'.tr(),
                  onChanged: (v) =>
                      _update(_settings.copyWith(scanDepth: v == 0 ? null : v)),
                ),
                const SizedBox(height: 12),
                _NumberField(
                  label: 'label_max_injected_entries'.tr(),
                  value: _settings.maxInjectedEntries ?? 0,
                  min: 0,
                  max: 100,
                  hint: 'lorebook_global_default_hint'.tr(),
                  onChanged: (v) => _update(
                      _settings.copyWith(maxInjectedEntries: v == 0 ? null : v)),
                ),
                const SizedBox(height: 24),

                // ── Matching ──────────────────────────────────────────────
                _SectionHeader('lorebook_matching'.tr(), helpTerm: 'lorebook-keys'),
                _SwitchField(
                  label: 'label_recursive_scan'.tr(),
                  value: _settings.recursiveScan,
                  onChanged: (v) => _update(_settings.copyWith(recursiveScan: v)),
                ),
                const SizedBox(height: 4),
                _SwitchField(
                  label: 'label_case_sensitive'.tr(),
                  value: _settings.caseSensitive,
                  onChanged: (v) => _update(_settings.copyWith(caseSensitive: v)),
                ),
                const SizedBox(height: 8),
                _DropdownField<String>(
                  label: 'label_match_whole_words'.tr(),
                  value: _settings.matchWholeWords ?? '',
                  items: [
                    DropdownMenuItem(value: '', child: Text('match_global'.tr())),
                    DropdownMenuItem(value: 'false', child: Text('off'.tr())),
                    DropdownMenuItem(value: 'true', child: Text('on'.tr())),
                    DropdownMenuItem(
                        value: 'glaze', child: Text('match_whole_words_glaze'.tr())),
                  ],
                  onChanged: (v) => _update(
                      _settings.copyWith(matchWholeWords: v.isEmpty ? null : v)),
                ),
                const SizedBox(height: 24),

                // ── Vector Search ─────────────────────────────────────────
                _SectionHeader('section_vector_search'.tr()),
                _SwitchField(
                  label: 'label_vector_search'.tr(),
                  value: _settings.vectorSearchEnabled,
                  onChanged: (v) =>
                      _update(_settings.copyWith(vectorSearchEnabled: v)),
                ),
                if (_settings.vectorSearchEnabled) ...[
                  const SizedBox(height: 8),
                  _DropdownField<String>(
                    label: 'label_embedding_target'.tr(),
                    value: _settings.embeddingTarget,
                    items: [
                      DropdownMenuItem(value: 'content', child: Text('target_content'.tr())),
                      DropdownMenuItem(value: 'comment', child: Text('target_comment'.tr())),
                      DropdownMenuItem(value: 'both', child: Text('search_type_both'.tr())),
                    ],
                    onChanged: (v) =>
                        _update(_settings.copyWith(embeddingTarget: v)),
                  ),
                  const SizedBox(height: 12),
                  _SliderField(
                    label: 'label_similarity_threshold'.tr(),
                    value: _settings.vectorThreshold,
                    min: 0.0,
                    max: 1.0,
                    divisions: 20,
                    displayText: _settings.vectorThreshold.toStringAsFixed(2),
                    onChanged: (v) =>
                        _update(_settings.copyWith(vectorThreshold: v)),
                  ),
                  const SizedBox(height: 12),
                  _NumberField(
                    label: 'label_top_k'.tr(),
                    value: _settings.vectorTopK,
                    min: 1,
                    max: 50,
                    onChanged: (v) => _update(_settings.copyWith(vectorTopK: v)),
                  ),
                ],
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _pop(BuildContext context) {
    if (_hasCustom) {
      Navigator.pop(context, {'settings': _settings.toJson()});
    } else {
      Navigator.pop(context, {'reset': true});
    }
  }

  void _update(LorebookSettings s) {
    setState(() {
      _settings = s;
      _hasCustom = true;
    });
  }

  void _resetToGlobal() {
    setState(() {
      _settings = _settingsFromGlobal(widget.globalSettings);
      _hasCustom = false;
    });
  }
}

// ── Reusable widgets (same style as global settings screen) ────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final String? helpTerm;
  const _SectionHeader(this.title, {this.helpTerm});

  @override
  Widget build(BuildContext context) {
    final label = Text(
      title,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: context.cs.primary,
        letterSpacing: 0.5,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: helpTerm == null
          ? label
          : Row(mainAxisSize: MainAxisSize.min, children: [label, HelpTip(term: helpTerm!)]),
    );
  }
}

class _NumberField extends StatefulWidget {
  final String label;
  final int value;
  final int min;
  final int max;
  final String? hint;
  final ValueChanged<int> onChanged;

  const _NumberField({
    required this.label,
    required this.value,
    this.min = 0,
    this.max = 2147483647,
    this.hint,
    required this.onChanged,
  });

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: widget.value == 0 && widget.hint != null ? '' : widget.value.toString(),
    );
  }

  @override
  void didUpdateWidget(_NumberField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      final newText =
          widget.value == 0 && widget.hint != null ? '' : widget.value.toString();
      if (_ctrl.text != newText) _ctrl.text = newText;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _commit() {
    final text = _ctrl.text;
    if (text.isEmpty) {
      widget.onChanged(0);
      return;
    }
    final n = int.tryParse(text);
    if (n != null && n >= widget.min && n <= widget.max) {
      widget.onChanged(n);
    } else {
      _ctrl.text =
          widget.value == 0 && widget.hint != null ? '' : widget.value.toString();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(widget.label,
              style:
                  TextStyle(color: context.cs.onSurfaceVariant, fontSize: 14)),
        ),
        SizedBox(
          width: 80,
          child: TextField(
            controller: _ctrl,
            keyboardType: TextInputType.number,
            style: TextStyle(color: context.cs.onSurface, fontSize: 14),
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              hintText: widget.hint,
              hintStyle: TextStyle(
                  fontSize: 10,
                  color: context.cs.onSurfaceVariant.withValues(alpha: 0.4)),
            ),
            onSubmitted: (_) => _commit(),
            onEditingComplete: _commit,
            onTapOutside: (_) {
              FocusScope.of(context).unfocus();
              _commit();
            },
          ),
        ),
      ],
    );
  }
}

class _DropdownField<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T> onChanged;

  const _DropdownField({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style:
                  TextStyle(color: context.cs.onSurfaceVariant, fontSize: 14)),
        ),
        const SizedBox(width: 8),
        Flexible(
          flex: 2,
          child: DropdownButtonFormField<T>(
            initialValue: value,
            items: items,
            isExpanded: true,
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
            style: TextStyle(color: context.cs.onSurface, fontSize: 13),
            dropdownColor: context.cs.surface,
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
      ],
    );
  }
}

class _SliderField extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String displayText;
  final ValueChanged<double> onChanged;

  const _SliderField({
    required this.label,
    required this.value,
    this.min = 0.0,
    this.max = 1.0,
    this.divisions = 10,
    required this.displayText,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style:
                    TextStyle(color: context.cs.onSurfaceVariant, fontSize: 14)),
            Text(displayText,
                style: TextStyle(
                    color: context.cs.onSurface,
                    fontSize: 13,
                    fontWeight: FontWeight.w500)),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          activeColor: context.cs.primary,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _SwitchField extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchField(
      {required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 14)),
        Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: context.cs.primary),
      ],
    );
  }
}
