import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/character.dart';
import '../../../core/services/character_book_converter.dart';
import '../../../core/state/character_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/lorebook_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_error_dialog.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../character_list/character_detail_screen.dart';
import '../picks_models.dart';
import '../picks_provider.dart';

class PicksDetailLauncher extends ConsumerStatefulWidget {
  final PicksCharacter character;
  final String imageUrl;
  final String relativePath;

  const PicksDetailLauncher({
    super.key,
    required this.character,
    required this.imageUrl,
    required this.relativePath,
  });

  @override
  ConsumerState<PicksDetailLauncher> createState() =>
      _PicksDetailLauncherState();
}

class _PicksDetailLauncherState extends ConsumerState<PicksDetailLauncher> {
  Character? _character;
  Uint8List? _pngBytes;
  String? _error;
  bool _importing = false;

  double _downloadProgress = 0;
  bool _downloading = false;

  PicksCharacter get char => widget.character;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() {
      _downloading = true;
      _downloadProgress = 0;
      _error = null;
    });

    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 60),
        ),
      );

      final res = await dio.get<List<int>>(
        '$kPicksBaseUrl/${widget.relativePath}',
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() => _downloadProgress = received / total);
          }
        },
      );

      final bytes = Uint8List.fromList(res.data ?? []);
      final importer = await ref.read(characterImporterProvider.future);
      final result = await importer.importFromBytes(bytes, '${char.id}.png');

      if (mounted) {
        setState(() {
          _character = result.character;
          _pngBytes = bytes;
          _downloading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _downloading = false;
        });
      }
    }
  }

  // [includeLorebooks] is unused here — Picks characters have no attached
  // lorebooks tab, so the import-options sheet never appears. The named
  // parameter is kept to satisfy CharacterDetailScreen.onImport's signature.
  Future<void> _doImport({bool includeLorebooks = false}) async {
    if (_character == null || _importing) return;
    setState(() => _importing = true);

    try {
      final existingChars = ref.read(charactersProvider).value ?? [];
      final existing = existingChars.where(
        (c) => c.picksHash != null && c.name == char.name,
      );

      Character characterWithHash;
      if (existing.isNotEmpty) {
        final old = existing.first;
        characterWithHash = _character!.copyWith(
          id: old.id,
          picksHash: char.hash,
        );
      } else {
        characterWithHash = _character!.copyWith(picksHash: char.hash);
      }

      await ref.read(charactersProvider.notifier).add(characterWithHash);

      final importer = await ref.read(characterImporterProvider.future);
      final result = await importer.importFromBytes(
        _pngBytes!,
        '${char.id}.png',
      );

      if (result.characterBookData != null) {
        final converted = convertCharacterBook(
          result.characterBookData!,
          characterWithHash.id,
        );
        debugPrint(
          '[character_import] picks saving_lorebook id=${converted.id} '
          'name=${converted.name} entries=${converted.entries.length} '
          'character=${characterWithHash.id}',
        );
        await ref.read(lorebooksProvider.notifier).put(converted);
      } else {
        debugPrint('[character_import] picks no_lorebook character=${characterWithHash.id}');
      }

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        final wasUpdate = existing.isNotEmpty;
        GlazeToast.show(
          context,
          '${wasUpdate ? 'Updated' : 'Imported'} ${char.name}',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _importing = false);
        GlazeErrorDialog.show(context, e, prefix: 'Import failed: ');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _ErrorView(message: _error!, onRetry: _fetch);
    }

    if (_downloading) {
      return _DownloadingView(name: char.name, progress: _downloadProgress);
    }

    final character = _character;
    if (character == null) {
      return const _LoadingView();
    }

    return CharacterDetailScreen(
      charId: 'preview:${char.id}',
      previewCharacter: character,
      previewAvatarUrl: widget.imageUrl,
      onImport: _doImport,
      importing: _importing,
    );
  }
}

class _DownloadingView extends StatelessWidget {
  final String name;
  final double progress;

  const _DownloadingView({required this.name, required this.progress});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 320,
      decoration: BoxDecoration(
        color: context.cs.surfaceContainerHighest,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            name,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: context.cs.onSurface,
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: 180,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: progress > 0 ? progress : null,
                minHeight: 6,
                backgroundColor: context.cs.surfaceContainerHighest,
                color: context.cs.primary,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            progress > 0
                ? '${(progress * 100).round()}%'
                : 'onboarding_status_connecting'.tr(),
            style: TextStyle(fontSize: 13, color: context.cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 360,
      decoration: BoxDecoration(
        color: context.cs.surfaceContainerHighest,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Center(
        child: CircularProgressIndicator(color: context.cs.primary),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 360,
      decoration: BoxDecoration(
        color: context.cs.surfaceContainerHighest,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 48,
            color: context.cs.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            message,
            style: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 13),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: onRetry,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: context.cs.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'Retry',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
