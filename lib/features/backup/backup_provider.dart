import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/backup_service.dart';
import '../../core/state/db_provider.dart';

final backupServiceProvider = FutureProvider<BackupService>((ref) async {
  final db = ref.watch(appDbProvider);
  final imageStorage = await ref.watch(imageStorageProvider.future);
  return BackupService(db, imageStorage);
});
