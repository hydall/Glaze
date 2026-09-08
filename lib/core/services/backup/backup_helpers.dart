import '../../db/app_db.dart';
import '../image_storage_service.dart';
import 'authors_note_helper.dart';
import 'data_url_helpers.dart';
import 'js_lorebook_mapper.dart';
import 'js_preset_mapper.dart';
import 'type_converters.dart';

export 'authors_note_helper.dart';
export 'data_url_helpers.dart';
export 'js_lorebook_mapper.dart';
export 'js_preset_mapper.dart';
export 'type_converters.dart';

abstract class BackupHelpers
    with TypeConverters, DataUrlHelpers, JsLorebookMapper, JsPresetMapper, AuthorsNoteHelper {
  AppDatabase get db;
  ImageStorageService get imageStorage;
}
