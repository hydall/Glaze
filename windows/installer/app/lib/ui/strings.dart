import 'dart:ui' show PlatformDispatcher;

/// The setup's text, in English and Russian like the app. Picked from the
/// system language once; there is nothing to switch.
class S {
  final bool ru;

  const S._(this.ru);

  static final S of = S._(
    const [
      'ru',
      'be',
      'uk',
    ].contains(PlatformDispatcher.instance.locale.languageCode.toLowerCase()),
  );

  String _(String en, String ruText) => ru ? ruText : en;

  String get windowTitle => _('Glaze Setup', 'Установка Glaze');
  String get tagline => _(
    'AI roleplay chat client.\nLocal, novice-friendly, open-source.',
    'Клиент для ИИ ролевых чатов.\nЛокальный, дружественный новичкам, с открытым исходным кодом.',
  );
  String get installTo => _('Install to', 'Папка установки');
  String get desktopShortcut => _('Desktop shortcut', 'Ярлык на рабочем столе');
  String get desktopShortcutHint => _(
    'The Start menu gets one either way.',
    'В меню «Пуск» ярлык будет в любом случае.',
  );
  String installedVersion(String v) => _(
    'Version $v is installed. It will be replaced; your chats, characters and settings stay.',
    'Установлена версия $v. Она будет заменена; чаты, персонажи и настройки сохранятся.',
  );
  String get dataStays => _(
    'Your chats, characters and settings are kept outside this folder.',
    'Чаты, персонажи и настройки хранятся отдельно от этой папки.',
  );
  String get install => _('Install', 'Установить');
  String get update => _('Update', 'Обновить');
  String get reinstall => _('Reinstall', 'Переустановить');
  String get cancel => _('Cancel', 'Отмена');
  String get close => _('Close', 'Закрыть');
  String get openGlaze => _('Open Glaze', 'Открыть Glaze');
  String get tryAgain => _('Try again', 'Попробовать снова');

  String installing(String app) => _('Installing $app', 'Устанавливаю $app');
  String updating(String app) => _('Updating $app', 'Обновляю $app');
  String removing(String app) => _('Removing $app', 'Удаляю $app');

  String get stepClose => _('Preparing', 'Подготовка');
  String get stepFiles => _('Copying files', 'Копирование файлов');
  String get stepRemoveFiles => _('Removing files', 'Удаление файлов');
  String get stepShortcuts =>
      _('Shortcuts and Apps entry', 'Ярлыки и запись в «Приложениях»');
  String get stepData => _('Deleting your data', 'Удаление данных');
  String get stepFinish => _('Finishing', 'Завершение');

  String get appStillOpen => _('Glaze is still open', 'Glaze ещё открыт');
  String get appStillOpenHint => _(
    'Close it to go on, or let setup close it.',
    'Закройте его, чтобы продолжить, или дайте установщику закрыть его.',
  );
  String get closeGlaze => _('Close Glaze', 'Закрыть Glaze');

  String installed(String app) => _('$app is installed', '$app установлен');
  String updated(String app) => _('$app is updated', '$app обновлён');
  String removed(String app) => _('$app is removed', '$app удалён');
  String get startingGlaze => _('Starting Glaze…', 'Запускаю Glaze…');
  String get installedHint => _(
    'Find it in the Start menu. It updates itself from inside the app.',
    'Он есть в меню «Пуск» и обновляется прямо из приложения.',
  );
  String get removedKeptData => _(
    'Your data was kept: installing Glaze again picks it up where you left off.',
    'Данные сохранены: после повторной установки всё будет на месте.',
  );
  String get removedData =>
      _('Your data was deleted too.', 'Данные тоже удалены.');

  String uninstallTitle(String app) => _('Remove $app?', 'Удалить $app?');
  String get uninstallHint => _(
    'This removes the program, its shortcuts and its entry in Apps.',
    'Будут удалены программа, её ярлыки и запись в «Приложениях».',
  );
  String get remove => _('Remove', 'Удалить');
  String get deleteData => _('Also delete my data', 'Удалить и мои данные');
  String deleteDataHint(String path) => _(
    'Characters, chats, presets and settings in $path. Leave it off to keep them for the next install.',
    'Персонажи, чаты, пресеты и настройки в $path. Не отмечайте, чтобы сохранить их для следующей установки.',
  );
  String legacyKeepsData(String path) => _(
    'Your data in $path stays: the old Glaze app is still installed and keeps its data there too.',
    'Данные в $path останутся: старое приложение Glaze ещё установлено и хранит данные там же.',
  );

  String get failed => _('Something went wrong', 'Что-то пошло не так');
  String get failedHint => _(
    'Your data was not touched. The details below help us find the cause.',
    'Ваши данные не затронуты. Подробности ниже помогут найти причину.',
  );
  String get noPayload => _(
    'This setup carries no Glaze build. Download the setup file again.',
    'В этом установщике нет сборки Glaze. Скачайте файл установщика заново.',
  );

  String channelLabel(String id) => switch (id) {
    'stable' => _('Stable', 'Стабильная'),
    'nightly' => 'Nightly',
    _ => id,
  };
}
