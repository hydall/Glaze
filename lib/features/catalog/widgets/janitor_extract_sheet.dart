import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../core/llm/tokenizer.dart';
import '../services/janitor_extractor.dart';

/// Dev tool: extract a JanitorAI character's **hidden card** + **closed
/// lorebook** via the webview proxy and save both to the Glaze DB.
///
/// Port of the SillyTavern `janitor-lorebook` extension UI: paste a character
/// URL → Run (capture + separate) → preview → Save (import character + rebuild
/// the lorebook with the active LLM).
void showJanitorExtractSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (_) => const _JanitorExtractSheet(),
  );
}

class _JanitorExtractSheet extends ConsumerStatefulWidget {
  const _JanitorExtractSheet();

  @override
  ConsumerState<_JanitorExtractSheet> createState() =>
      _JanitorExtractSheetState();
}

class _JanitorExtractSheetState extends ConsumerState<_JanitorExtractSheet> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _phase;
  String? _error;
  ExtractionResult? _result;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final url = _controller.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _phase = null;
      _result = null;
    });
    try {
      final result = await ref.read(janitorExtractorProvider).extract(
            url,
            onPhase: (p) {
              if (mounted) setState(() => _phase = p);
            },
          );
      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final result = _result;
    if (result == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final commit = await ref.read(janitorExtractorProvider).commit(
            result,
            onPhase: (p) {
              if (mounted) setState(() => _phase = p);
            },
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      final msg = commit.lorebookError != null
          ? 'Imported ${commit.characterName} (lorebook failed: ${commit.lorebookError})'
          : 'Imported ${commit.characterName} + ${commit.lorebookEntryCount} lorebook entries';
      GlazeToast.show(context, msg);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Material(
        color: cs.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                'JanitorAI — Extract card + closed lorebook',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Captures the hidden card and triggered lorebook via the webview '
                'proxy, then rebuilds entries with the active LLM. Requires being '
                'logged into JanitorAI and an active API connection.',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                enabled: !_busy,
                style: TextStyle(fontSize: 14, color: cs.onSurface),
                decoration: InputDecoration(
                  hintText: 'https://janitorai.com/characters/...',
                  hintStyle:
                      TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
                  filled: true,
                  fillColor: cs.surfaceContainerHighest,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: (_) => _busy ? null : _run(),
              ),
              if (_busy) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: cs.primary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _phase ?? 'Working…',
                        style: TextStyle(
                            color: cs.onSurfaceVariant, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                ),
              ],
              if (_result != null && !_busy) ...[
                const SizedBox(height: 16),
                _Preview(result: _result!),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : _run,
                      child: Text(_result == null ? 'Run' : 'Re-run'),
                    ),
                  ),
                  if (_result != null) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _busy ? null : _save,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: cs.primary,
                          foregroundColor: cs.onPrimary,
                        ),
                        child: const Text('Save to DB'),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.result});
  final ExtractionResult result;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final card = result.character.charData;
    TextStyle label() =>
        TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface);
    TextStyle value() => TextStyle(fontSize: 12, color: cs.onSurfaceVariant);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Name: ${card.name}', style: label()),
          const SizedBox(height: 4),
          Text('Card (description): ${estimateTokens(card.description)} tokens',
              style: value()),
          Text('Scenario: ${estimateTokens(card.scenario)} tokens',
              style: value()),
          Text('First message: ${estimateTokens(card.firstMes)} tokens',
              style: value()),
          Text(
            'Closed lorebook: ${result.hasLorebook ? 'extracted content, ${estimateTokens(result.lorebookText)} tokens' : result.hasAdvancedLorebook ? 'advanced (inline) — full prompt ${estimateTokens(result.fullPromptText)} tokens' : 'none found'}',
            style: value(),
          ),
          if (result.hasLorebook && !result.hasAdvancedLorebook) ...[
            const SizedBox(height: 8),
            Text('Extracted content (preview):', style: label()),
            const SizedBox(height: 4),
            Text(
              result.lorebookText.length > 600
                  ? '${result.lorebookText.substring(0, 600)}…'
                  : result.lorebookText,
              style: value(),
            ),
          ],
        ],
      ),
    );
  }
}
