// Content of the site. Everything user-facing lives here, in both languages,
// so adding a release or a feature never means touching the markup.
//
// Release items are grouped the way the app groups its settings: a short
// caps sub-header and the rows under it.

window.GLAZE = {
  repo: 'hydall/Glaze',

  // Shown until the GitHub API answers (or when it is rate-limited).
  fallbackRelease: {
    tag: 'v0.8.0',
    date: '2026-10-04',
    assets: [
      { name: 'v0.8.0.apk', size: 52428800 },
      { name: 'v0.8.0-arm64-v8a.apk', size: 26214400 },
      { name: 'v0.8.0-armeabi-v7a.apk', size: 25165824 },
      { name: 'v0.8.0.ipa', size: 27262976 },
      { name: 'v0.8.0-windows.zip', size: 27918336 },
      { name: 'v0.8.0-linux.pkg.tar.zst', size: 22020096 },
      { name: 'v0.8.0-linux.tar.zst', size: 35651584 },
    ],
  },

  devVersion: '0.8.0',

  // Where the Download page's Nightly channel looks for builds.
  nightly: { workflow: 'build-branch.yml', branch: 'nightly' },

  links: {
    github: 'https://github.com/hydall/Glaze',
    releases: 'https://github.com/hydall/Glaze/releases',
    issues: 'https://github.com/hydall/Glaze/issues',
    discord: 'https://discord.gg/jnGhd7p6Ht',
    telegram: 'https://t.me/glazeapp',
    boosty: 'https://boosty.to/hydall',
    bmc: 'https://buymeacoffee.com/hydall',
    altstore: 'https://altstore.io/',
    license: 'https://www.gnu.org/licenses/agpl-3.0.html',
  },

  ui: {
    ru: {
      features_title: 'Что умеет Glaze',
      download_title: 'Скачать Glaze',
      download_lead: 'Бесплатно и без аккаунта: понадобится только ключ API вашего провайдера.',
      roadmap_title: 'Как развивался Glaze',
      about_title: 'Кто делает Glaze',
      hero_platforms: 'Android · iOS · Windows · Linux',
      hero_license: 'Открытый код, AGPL-3.0',
      dl_latest: 'Последний релиз',
      status_latest: 'Последний',
      nav_overview: 'Обзор',
      nav_features: 'Возможности',
      nav_screenshots: 'Скриншоты',
      nav_articles: 'Статьи',
      nav_roadmap: 'Роадмап',
      nav_download: 'Скачать',
      nav_resources: 'Ресурсы',

      articles_title: 'Статьи',
      articles_lead: 'Новости проекта и подробные заметки к релизам.',
      article_latest: 'Последняя статья',
      article_read: 'Читать',
      article_all: 'Все статьи',
      article_back: 'Все статьи',
      article_loading: 'Загружаем статью…',
      article_failed: 'Не удалось загрузить статью.',
      article_not_found: 'Такой статьи нет.',
      article_only_ru: 'Статья доступна только на русском.',
      kind_changelog: 'Чейнджлог',
      kind_news: 'Новости',

      screenshots_title: 'Как выглядит Glaze',
      screenshots_lead: 'Экраны приложения на телефоне и на ПК. Нажмите на скриншот, чтобы открыть его целиком.',
      shots_phone: 'Телефон',
      shots_desktop: 'ПК',
      shots_platform: 'Устройство',
      shots_close: 'Закрыть',
      shots_prev: 'Предыдущий',
      shots_next: 'Следующий',

      tagline: 'Клиент для ИИ ролевых чатов.\nЛокальный, дружественный новичкам, с открытым исходным кодом.',
      btn_download: 'Скачать',
      btn_github: 'GitHub',
      beta: 'BETA',

      glance: [
        ['lock', 'Полностью локально', 'Glaze не использует серверы для хранения и сбора ваших данных. Всё хранится на телефоне. Исключение только одно: облачная синхронизация, если вы сами включите Dropbox или Google Drive.'],
        ['devices', 'Нативно и кроссплатформенно', 'Благодаря Flutter приложение работает и на десктопе, и на мобильных, с адаптивной вёрсткой. Например, десктопный интерфейс можно включить на Android с внешним монитором или на планшете.'],
        ['swap_horiz', 'Совместим с SillyTavern', 'Glaze полностью совместим с отраслевыми стандартами: JSON-пресеты, карточки и персоны. Можно импортировать бэкап SillyTavern и продолжить ролевую игру в Glaze.'],
        ['person_search', 'Библиотека персонажей', 'Ищите и импортируйте персонажей с любимых площадок (Janitor, Chub, DataCat) прямо в Glaze, без сторонних скраперов и ручного скачивания файлов. Закрытых персонажей тоже можно импортировать, а приватные лорбуки из Janitor можно вытаскивать прямо на устройстве.'],
        ['palette', 'Настраиваемый интерфейс', 'Скройте ненужные функции, поменяйте цвета и шрифты, настройте Glaze под себя. А потом поделитесь темами с друзьями одним файлом.'],
      ],
      overview_features_header: 'Возможности',
      overview_features_link: '…и многое другое',

      notice_header: 'Честно о статусе',
      notice_text: 'Glaze в активной разработке: приложение пока нестабильно и может содержать ошибки. Код во многом написан с помощью ИИ-моделей («навайбкожен»). Умерьте ожидания. Баг-репорты приветствуются.',
      notice_report: 'Сообщить об ошибке',

      features_lead: 'Всё, что есть в приложении сейчас.',

      channel_label: 'Канал сборок',
      channel_stable: 'Стабильная',
      channel_nightly: 'Nightly',
      nightly_latest: 'Последний nightly',
      nightly_build: 'Сборка',
      nightly_commits: 'Коммиты',
      nightly_run: 'Запуск в Actions',
      nightly_failed: 'Не удалось получить данные о сборке из GitHub.',
      nightly_failed_short: 'Недоступно',
      dl_loading_short: 'Загрузка…',
      nightly_header: 'Ночные сборки',
      nightly_text: 'Собираются автоматически из ветки nightly, со всем, что ещё в работе, и без проверки. Что-то может сломаться, поэтому перед установкой сделайте бэкап. Nightly ставится отдельным приложением рядом со стабильной версией и не делит с ней данные. Файлы скачиваются ZIP-архивом через nightly.link. Распакуйте его.',
      dl_how_nightly: {
        android: 'В архиве APK. Распакуйте и откройте его. Приложение появится как «Glaze Nightly».',
        ios: 'В архиве IPA. Поставьте его через AltStore или похожий инструмент, рядом с обычным Glaze.',
        windows: 'В архиве ещё один ZIP с приложением: распакуйте его в отдельную папку и запустите Glaze.exe.',
        linux: 'Внутри пакет выбранного формата. Установите его как обычно.',
      },
      dl_all: 'Все релизы',
      dl_loading: 'Загружаем данные релиза…',
      dl_api_failed: 'Не удалось связаться с GitHub. Показаны ссылки на v0.8.0.',
      dl_missing: 'В этом релизе нет',
      dl_how: {
        android: 'Скачайте APK и откройте его. Разрешите установку из этого источника, если система спросит. Есть универсальная сборка, а также отдельные под arm64 и arm32.',
        ios: 'В App Store приложения нет. Поставьте IPA через AltStore или похожий инструмент для сайдлоада.',
        windows: 'Распакуйте архив в любую папку и запустите Glaze.exe. Установщик не нужен.',
        linux: 'Пакет pacman для Arch или переносимый архив .tar.zst: распакуйте его куда угодно и запустите Glaze. В 0.7 был только .deb.',
      },

      plat_android: 'Android',
      plat_ios: 'iOS',
      plat_windows: 'Windows',
      plat_linux: 'Linux',
      plat_android_sub: 'APK · arm64 · arm32',
      plat_ios_sub: 'IPA · сайдлоад',
      plat_windows_sub: 'ZIP · x64',
      plat_linux_sub: 'pacman · tar.zst',
      asset_universal: 'APK',
      asset_arm64: 'arm64',
      asset_arm32: 'arm32',

      roadmap_lead: 'Ровно то, что выходило в релизах, начиная с первой публичной альфы. Сверху то, над чем работаем сейчас.',
      status_planned: 'Планы',
      status_dev: 'В разработке',
      status_alpha: 'alpha',
      status_beta: 'beta',
      release_notes: 'Заметки к релизу',

      about_header: 'О Glaze',
      about_text: [
        'Glaze это клиент для ролевых чатов с языковыми моделями. Подключаете своего провайдера, импортируете персонажа и пишете историю. Сервера Glaze между вами и моделью нет: запросы уходят напрямую провайдеру, а всё остальное хранится на устройстве.',
        'Проект начинался в начале 2026 года как мобильное приложение на Vue и Capacitor. Летом его полностью переписали на Flutter, чтобы телефон и ПК стали полноценными приложениями с общим кодом.',
      ],
      authors_header: 'Разработчики',
      creators_header: 'Создатели',
      credits_header: 'Благодарности',
      credits_presets: 'Пресеты',
      credits_by: 'Автор',
      resources_header: 'Наши ресурсы',
      role_hydall: 'Руководитель проекта, UX/UI дизайнер, программист',
      role_danvitv: 'Бэкенд-архитектор, программист',
      danvitv_until: 'до 0.8.0',
      testers_header: 'Тестеры',
      community_header: 'Сообщество',
      community_join: 'Предлагайте функции, получайте помощь и общайтесь',
      community_support: 'Поддержать проект',
      community_source: 'Исходный код и баг-трекер',
      credit_ref: 'Основано на',
      credit_insp: 'Вдохновлено',
      credit_port: 'Портировано из',
      license_header: 'Лицензия',
      license_text: 'Вы можете свободно использовать, изменять и распространять Glaze на условиях AGPL-3.0. Любые модификации также должны быть доступны под той же лицензией.',


      noscript: 'Для этой страницы нужен JavaScript. Сборки и описание проекта есть на GitHub:',
    },

    en: {
      features_title: 'What Glaze does',
      download_title: 'Get Glaze',
      download_lead: 'Free, no account needed: just an API key from your provider.',
      roadmap_title: 'How Glaze got here',
      about_title: 'Who makes Glaze',
      hero_platforms: 'Android · iOS · Windows · Linux',
      hero_license: 'Open source, AGPL-3.0',
      dl_latest: 'Latest release',
      status_latest: 'Latest',
      nav_overview: 'Overview',
      nav_features: 'Features',
      nav_screenshots: 'Screenshots',
      nav_articles: 'Posts',
      nav_roadmap: 'Roadmap',
      nav_download: 'Download',
      nav_resources: 'Resources',

      articles_title: 'Posts',
      articles_lead: 'Project news and detailed release notes.',
      article_latest: 'Latest post',
      article_read: 'Read',
      article_all: 'All posts',
      article_back: 'All posts',
      article_loading: 'Loading the post…',
      article_failed: 'Could not load the post.',
      article_not_found: 'There is no such post.',
      article_only_ru: 'This post is only available in Russian.',
      kind_changelog: 'Changelog',
      kind_news: 'News',

      screenshots_title: 'What Glaze looks like',
      screenshots_lead: 'The app on a phone and on a PC. Click a screenshot to see it in full.',
      shots_phone: 'Phone',
      shots_desktop: 'Desktop',
      shots_platform: 'Device',
      shots_close: 'Close',
      shots_prev: 'Previous',
      shots_next: 'Next',

      tagline: 'AI roleplay chat client.\nLocal, novice-friendly, open-source.',
      btn_download: 'Download',
      btn_github: 'GitHub',
      beta: 'BETA',

      glance: [
        ['lock', 'Fully local', 'Glaze uses no servers to store or collect your data. Everything is stored on your phone. The only exception is cloud sync, if you decide to sync your data with Dropbox or Google Drive.'],
        ['devices', 'Native and cross-platform', 'Thanks to Flutter, the app runs on both desktop and mobile, responsively. For example, you can use the desktop layout on Android with an external monitor, or on a tablet.'],
        ['swap_horiz', 'SillyTavern-compatible', 'Glaze is fully compatible with industry standards: JSON presets, characters and personas. You can also import your SillyTavern backup and continue your roleplay in Glaze.'],
        ['person_search', 'Character Library', 'Browse and import characters from your favorite platforms (Janitor, Chub, DataCat) straight into Glaze, with no need for scrapers or manual downloads. You can also import private characters and scrape private lorebooks from Janitor right on the device.'],
        ['palette', 'Customizable Interface', 'Hide any feature you do not need, change the colors and fonts, and style Glaze to your liking. Then share your themes with friends in a single file.'],
      ],
      overview_features_header: 'Features',
      overview_features_link: '...and more',

      notice_header: 'Where it stands',
      notice_text: 'Glaze is under heavy development: it is not stable yet and may contain bugs. Much of it was vibecoded with a plethora of AI models. Curb your expectations. Bug reports are welcome.',
      notice_report: 'Report a bug',

      features_lead: 'What the app does today.',

      channel_label: 'Build channel',
      channel_stable: 'Stable',
      channel_nightly: 'Nightly',
      nightly_latest: 'Latest nightly',
      nightly_build: 'Build',
      nightly_commits: 'Commits',
      nightly_run: 'Actions run',
      nightly_failed: 'Could not get build data from GitHub.',
      nightly_failed_short: 'Unavailable',
      dl_loading_short: 'Loading…',
      nightly_header: 'Nightly builds',
      nightly_text: 'Built automatically from the nightly branch, with everything still in progress and nothing tested. Things may break, so make a backup first. Nightly installs as a separate app next to the stable one and does not share its data. Files download as a ZIP via nightly.link. Unpack it.',
      dl_how_nightly: {
        android: 'The archive holds an APK. Unpack and open it. The app shows up as "Glaze Nightly".',
        ios: 'The archive holds an IPA. Sideload it with AltStore or a similar tool, next to regular Glaze.',
        windows: 'The archive holds another ZIP with the app: unpack it into its own folder and run Glaze.exe.',
        linux: 'Inside is the package in the chosen format. Install it as usual.',
      },
      dl_all: 'All releases',
      dl_loading: 'Loading release data…',
      dl_api_failed: 'Could not reach GitHub. Showing links for v0.8.0.',
      dl_missing: 'Not in this release',
      dl_how: {
        android: 'Download the APK and open it. Allow installs from this source if the system asks. There is a universal build, plus separate arm64 and arm32 ones.',
        ios: 'Glaze is not on the App Store. Sideload the IPA with AltStore or a similar tool.',
        windows: 'Unpack the archive anywhere and run Glaze.exe. No installer needed.',
        linux: 'A pacman package for Arch, or a portable .tar.zst archive: unpack it anywhere and run Glaze. 0.7 shipped a .deb only.',
      },

      plat_android: 'Android',
      plat_ios: 'iOS',
      plat_windows: 'Windows',
      plat_linux: 'Linux',
      plat_android_sub: 'APK · arm64 · arm32',
      plat_ios_sub: 'IPA · sideload',
      plat_windows_sub: 'ZIP · x64',
      plat_linux_sub: 'pacman · tar.zst',
      asset_universal: 'APK',
      asset_arm64: 'arm64',
      asset_arm32: 'arm32',

      roadmap_lead: 'Exactly what shipped, starting from the first public alpha. What we are working on now is at the top.',
      status_planned: 'Planned',
      status_dev: 'In development',
      status_alpha: 'alpha',
      status_beta: 'beta',
      release_notes: 'Release notes',

      about_header: 'About Glaze',
      about_text: [
        'Glaze is a client for roleplay chats with language models. Connect your provider, import a character and write a story. There is no Glaze server between you and the model: requests go straight to your provider, and everything else stays on your device.',
        'It started in early 2026 as a mobile app built on Vue and Capacitor. Over the summer it was rewritten from scratch in Flutter, so that phone and PC are both first-class apps sharing one codebase.',
      ],
      authors_header: 'Developers',
      creators_header: 'Creators',
      credits_header: 'Credits',
      credits_presets: 'Presets',
      credits_by: 'By',
      resources_header: 'Our Resources',
      role_hydall: 'Project Lead, UX/UI Designer, Programmer',
      role_danvitv: 'Backend Architect, Programmer',
      danvitv_until: 'until 0.8.0',
      testers_header: 'Testers',
      community_header: 'Community',
      community_join: 'Suggest features, get help and hang out',
      community_support: 'Support the project',
      community_source: 'Source code & issues',
      credit_ref: 'Based on',
      credit_insp: 'Inspired by',
      credit_port: 'Ported from',
      license_header: 'License',
      license_text: 'You are free to use, modify, and distribute Glaze under the terms of the AGPL-3.0 license. Any modifications must also be made available under the same license.',


      noscript: 'This page needs JavaScript. Builds and the project description are on GitHub:',
    },
  },

  // Projects credited under the features they helped shape.
  credits: {
    sillyimages: ['SillyImages', 'https://github.com/0xl0cal/sillyimages'],
    characterlibrary: ['SillyTavern-CharacterLibrary', 'https://github.com/Sillyanonymous/SillyTavern-CharacterLibrary'],
    marinara: ['Marinara Engine', 'https://github.com/Pasta-Devs/Marinara-Engine'],
    lumiverse: ['Lumiverse', 'https://github.com/prolix-oc/Lumiverse'],
    extblocks: ['Monblant/ExtBlocks', 'https://gitgud.io/Monblant/extblocks'],
  },

  // What each credited project lent Glaze, for the Credits block in Resources.
  creditNotes: {
    sillyimages: {
      ru: 'Основа для генерации картинок прямо в чате',
      en: 'Reference for inline image generation',
    },
    characterlibrary: {
      ru: 'Основа для извлечения карточек с JanitorAI через браузер',
      en: 'Reference for JanitorAI extraction through a browser',
    },
    marinara: {
      ru: 'Вдохновение для агентского пайплайна',
      en: 'Inspiration for the agentic pipeline',
    },
    lumiverse: {
      ru: 'Вдохновение для агентского пайплайна',
      en: 'Inspiration for the agentic pipeline',
    },
    extblocks: {
      ru: 'Формат блоков и песочница расширений',
      en: 'The block format and the extension sandbox',
    },
  },

  // Authors of the presets Glaze ships with (see featured_presets.dart).
  presetCredits: [
    { name: 'Shino', author: 'Shino', url: 'https://t.me/ah_ah_shino4ka' },
    { name: 'Fawnie v3', author: 'fawn1e', url: 'https://t.me/dearfawwn' },
    {
      name: 'MicroCot Talks Mini',
      author: 'MicroCoT',
      url: 'https://t.me/sillytavern1',
    },
    { name: 'Renri', author: 'nimda trashcan' },
  ],

  testers: ['nightsyr', 'Саша Белый', 'múrx', 'lina', 'ShikiN', 'N K', 'Сатаник1155'],

  // ── Features ───────────────────────────────────────────────────────────────
  features: [
    {
      icon: 'chat_bubble',
      title: { ru: 'Чат', en: 'Chat' },
      items: [
        { icon: 'swipe', ru: ['Свайпы, правки и ветки', 'Свайп вправо перегенерирует ответ, варианты сохраняются. Любое сообщение можно отредактировать, а с любого места начать новую ветку чата.'], en: ['Swipes, edits and branches', 'Swipe right to regenerate and keep every variant. Edit any message, or branch the chat into a new session from any point.'] },
        { icon: 'record_voice_over', ru: ['Имперсонация и направленная генерация', 'Модель может написать реплику за вас или ответить по вашей инструкции, в том числе для свайпа.'], en: ['Impersonation and guided generation', 'Let the model write your line for you, or steer its reply or swipe with an instruction.'] },
        { icon: 'notifications_active', ru: ['Фоновая генерация', 'Ответ пишется, пока приложение свёрнуто; по готовности приходит уведомление. В списке чатов видно, где идёт генерация и что не прочитано.'], en: ['Background generation', 'Replies keep generating while the app is in the background and notify you when ready. The chat list shows live generation and unread replies.'] },
      ],
    },
    {
      icon: 'cable',
      title: { ru: 'Модели и промпт', en: 'Models and prompt' },
      items: [
        { icon: 'cloud', ru: ['Любой провайдер', 'OpenAI, Anthropic, Gemini, OpenRouter и любые OpenAI-совместимые эндпоинты, включая Responses API. Запросы идут напрямую, без серверов Glaze.'], en: ['Any provider', 'OpenAI, Anthropic, Gemini, OpenRouter and any OpenAI-compatible endpoint, Responses API included. Requests go straight to the provider, no Glaze server in between.'] },
        { icon: 'settings_ethernet', ru: ['Тонкая настройка эндпоинтов', 'Постобработка промпта как в SillyTavern (merge, semi, strict, single) и полный контроль над отправляемыми параметрами.'], en: ['Endpoint fine-tuning', 'SillyTavern-style prompt post-processing (merge, semi, strict, single) and full control over sent parameters.'] },
        { icon: 'psychology', ru: ['Нативные рассуждения', 'Reasoning моделей разбирается в отдельный блок и не уходит обратно в модель. Собственные теги пресета тоже понимаются.'], en: ['Native reasoning', 'A model\'s reasoning is parsed into its own block and never sent back. A preset\'s own reasoning tags are understood too.'] },
        { icon: 'calculate', ru: ['Точный подсчёт токенов', 'Токенайзер своей модели: Claude, Gemini, Llama, Qwen, DeepSeek, Mistral и другие. Подбирается сам по названию модели.'], en: ['Accurate token counts', 'Each model family\'s own tokenizer: Claude, Gemini, Llama, Qwen, DeepSeek, Mistral and more, picked automatically from the model name.'] },
        { icon: 'manage_search', ru: ['Инспектор промпта', 'Что именно ушло модели: таймлайн запросов, разбивка по токенам, покрытие лорбуков, сырой запрос. Карточка контекста под шапкой чата показывает, что попадёт в следующий.'], en: ['Prompt Inspector', 'Exactly what went to the model: a request timeline, token breakdown, lorebook coverage, the raw request. A context card under the chat header shows what makes the next one.'] },
      ],
    },
    {
      icon: 'tune',
      title: { ru: 'Пресеты и ExtBlocks', en: 'Presets and ExtBlocks' },
      items: [
        { icon: 'tune', ru: ['Пресеты SillyTavern', 'JSON-пресеты работают как есть, несколько популярных уже встроены. Блоки можно раскладывать по папкам и включать папками.'], en: ['SillyTavern presets', 'JSON presets work as they are; several popular ones come preinstalled. Blocks can be grouped into folders and toggled a folder at a time.'] },
        { icon: 'extension', ru: ['ExtBlocks', 'Инфоблоки, трекеры, картинки и HTML-панели считает отдельная дешёвая модель параллельно с основной. JS работает в песочнице, где по умолчанию всё запрещено. Блоки из оригинального расширения импортируются.'], en: ['ExtBlocks', 'Info blocks, trackers, images and HTML panels run on a separate, cheap model alongside the main one. JS is sandboxed, deny by default. Blocks from the original extension import as they are.'], credit: { kind: 'port', names: ['extblocks'] } },
        { icon: 'data_object', ru: ['Макросы', 'setvar/getvar, случайный выбор, броски кубиков, подстановка данных персонажа и пользователя.'], en: ['Macros', 'setvar/getvar, random choices, dice rolls, character and user substitution.'] },
        { icon: 'code', ru: ['Regex-скрипты', 'Глобальные и встроенные в пресеты, с учётом глубины; отдельно для отображения и для промпта.'], en: ['Regex scripts', 'Global and preset-embedded, with depth limits respected; display-only and prompt-only.'] },
      ],
    },
    {
      icon: 'auto_stories',
      title: { ru: 'Память и лор', en: 'Memory and lore' },
      items: [
        { icon: 'menu_book', ru: ['Лорбуки (World Info)', 'Поиск записей по ключевым словам и по смыслу: векторный поиск с эмбеддингами, отдельные пресеты для них.'], en: ['Lorebooks (World Info)', 'Entries found by keyword and by meaning: vector search over embeddings, with presets of their own.'] },
        { icon: 'history_edu', ru: ['Книги памяти', 'Автоматические сводки длинных чатов, которые подмешиваются в контекст. Черновики можно проверить и поправить перед одобрением.'], en: ['Memory books', 'Automatic summaries of long chats, injected back into the context. Review and edit drafts before approving them.'] },
        { icon: 'badge', ru: ['Персоны и заметки автора', 'Несколько персон с привязкой к персонажу или чату, Author\'s Note.'], en: ['Personas and Author\'s Note', 'Multiple personas bound per character or per chat, plus Author\'s Note.'] },
      ],
    },
    {
      icon: 'travel_explore',
      title: { ru: 'Персонажи', en: 'Characters' },
      items: [
        { icon: 'search', ru: ['Каталог', 'JanitorAI, Chub, DataCat, JannyAI и другие прямо в приложении: поиск, фильтры, теги, аккаунт Chub и лента Timeline. NSFW-картинки можно размыть.'], en: ['Catalog', 'JanitorAI, Chub, DataCat, JannyAI and more, right in the app: search, filters, tags, a Chub account and its Timeline feed. NSFW images can be blurred.'], credit: { kind: 'insp', names: ['characterlibrary'] } },
        { icon: 'lock_open', ru: ['Janitor Extractor (ранее JAR)', 'Извлечение карточек и лорбуков с JanitorAI, в том числе закрытых, прямо на устройстве. Полностью встроен в Glaze.'], en: ['Janitor Extractor (previously JAR)', 'Extracts JanitorAI cards and lorebooks, private ones included, right on the device. Fully built into Glaze.'], link: 'https://github.com/hydall/JAR' },
        { icon: 'link', ru: ['Импорт по ссылке', 'Chub, JannyAI, Pygmalion, RisuAI, Perchance, AICharacterCards: вставьте ссылку, персонаж в библиотеке.'], en: ['Import by URL', 'Chub, JannyAI, Pygmalion, RisuAI, Perchance, AICharacterCards: paste a link, get the character.'] },
        { icon: 'collections_bookmark', ru: ['Библиотека', 'Папки, вариации персонажа и скрытие персонажей.'], en: ['Library', 'Folders, character variations and hidden characters.'] },
        { icon: 'contact_page', ru: ['Карточки персонажей', 'Импорт и экспорт V2 в JSON и PNG, CharX и ZIP с галереей.'], en: ['Character cards', 'V2 import and export as JSON and PNG, CharX and ZIP with the gallery.'] },
      ],
    },
    {
      icon: 'image',
      title: { ru: 'Картинки', en: 'Images' },
      items: [
        { icon: 'image', ru: ['Картинки в сообщениях', 'До четырёх изображений в одном сообщении, в том числе прямо из буфера обмена.'], en: ['Images in messages', 'Up to four images per message, pasted straight from the clipboard if you like.'] },
        { icon: 'imagesmode', ru: ['Прямо в ролевой игре', 'Модель вставляет тег, Glaze рисует картинку на месте и сохраняет её как свайп.'], en: ['Inside the roleplay', 'The model emits a tag and Glaze draws the image in place, keeping it as a swipe.'], credit: { kind: 'ref', names: ['sillyimages'] } },
        { icon: 'cloud', ru: ['Провайдеры', 'OpenAI-совместимые эндпоинты, rout.my, Naistera.'], en: ['Providers', 'OpenAI-compatible endpoints, rout.my, Naistera.'] },
        { icon: 'account_tree', ru: ['NovelAI, ComfyUI и другие', 'Нативный NovelAI с референсами, ComfyUI с библиотекой воркфлоу, xAI Imagine, OpenRouter, Electron Hub, A1111, библиотека стилей, свои размеры.'], en: ['NovelAI, ComfyUI and more', 'Native NovelAI with references, ComfyUI with a workflow library, xAI Imagine, OpenRouter, Electron Hub, A1111, a style library, custom sizes.'] },
      ],
    },
    {
      icon: 'brush',
      title: { ru: 'Интерфейс', en: 'Interface' },
      items: [
        { icon: 'desktop_windows', ru: ['Настоящий ПК-интерфейс', 'Три колонки, плавающие окна, которые можно двигать, растягивать и переключать по Ctrl+Tab, горячие клавиши. Работает и на планшетах.'], en: ['A real desktop layout', 'Three columns, floating windows you can move, resize and switch with Ctrl+Tab, keyboard shortcuts. Works on tablets too.'] },
        { icon: 'dashboard_customize', ru: ['Панель ввода и инструменты под себя', 'Кнопки под полем ввода настраиваются: инструменты, быстрые ответы и действия закрепляются в одну строку. Есть кнопки быстрой вставки *звёздочек* и «кавычек». Сетку инструментов можно переставлять, а ненужные функции скрыть.'], en: ['Your own composer and tools', 'The button row under the composer is yours to arrange: pin tools, quick replies and actions to it. Quick-insert buttons for *asterisks* and "quotes" included. The tools grid can be rearranged, and features you do not need hidden.'] },
        { icon: 'format_paint', ru: ['Темы', 'Цвета, шрифты, фон, прозрачность и размытие элементов. Тему можно выгрузить в JSON и поделиться.'], en: ['Themes', 'Colours, fonts, background, element opacity and blur. Export a theme as JSON and share it.'] },
        { icon: 'school', ru: ['Глоссарий для новичков', 'Встроенный справочник терминов ИИ и ролевых игр. Подсказки в настройках ведут прямо к нужной статье.'], en: ['A glossary for newcomers', 'A built-in reference of AI and roleplay terms. Hints across the settings link straight to the right entry.'] },
      ],
    },
    {
      icon: 'cloud_sync',
      title: { ru: 'Данные', en: 'Your data' },
      items: [
        { icon: 'sync', ru: ['Облачная синхронизация', 'Dropbox или Google Drive, по желанию с шифрованием.'], en: ['Cloud sync', 'Dropbox or Google Drive, optionally encrypted.'] },
        { icon: 'unarchive', ru: ['Бэкапы и переезд', 'Свой формат .glz, а ещё полный бэкап SillyTavern (.zip) и Tavo (.tbk) переносятся в Glaze вместе с чатами.'], en: ['Backups and moving in', 'Glaze\'s own .glz, plus full SillyTavern (.zip) and Tavo (.tbk) backups move into Glaze, chats included.'] },
      ],
    },
  ],

  // Who writes the articles: the name shown, an avatar in img/ and a link.
  authors: {
    hydall: { name: 'hydall', img: 'hydall.jpg', url: 'https://github.com/hydall' },
  },

  // ── Articles, newest first ─────────────────────────────────────────────────
  // Body: Markdown in site/articles/<slug>.<lang>.md. `langs` lists the
  // languages it is written in; any other shows the first one with a notice.
  articles: [
    {
      slug: '0.8.0',
      kind: 'changelog',
      date: '2026-10-04',
      author: 'hydall',
      langs: ['ru', 'en'],
      title: { ru: 'Glaze beta 0.8.0', en: 'Glaze beta 0.8.0' },
      lead: {
        ru: 'Вернулся ПК-интерфейс, JAR встроен в Glaze целиком, NovelAI и ComfyUI для картинок, настраиваемая панель ввода и очень много исправлений.',
        en: 'The desktop layout is back, JAR is fully built in, NovelAI and ComfyUI for images, a customizable composer and a great many fixes.',
      },
    },
  ],

  // ── Screenshots ────────────────────────────────────────────────────────────
  // Files: img/screens/web/<platform>_<id>_<lang>.webp, made from the PNGs
  // next to them. `phoneOnly` items have no desktop shot worth showing.
  screenshots: [
    {
      icon: 'chat_bubble',
      title: { ru: 'Чат', en: 'Chat' },
      items: [
        { id: 'chat', ru: ['Чат', 'Разметка реплик и настраиваемая панель ввода.'], en: ['Chat', 'Styled dialogue and a configurable composer.'] },
        { id: 'chat_drawer', ru: ['Инструменты и действия', 'Все инструменты чата в одной панели.'], en: ['Tools and actions', 'Every chat tool in one drawer.'] },
        { id: 'chat_inspector', ru: ['Инспектор промпта', 'Что занимает контекст.'], en: ['Prompt Inspector', 'What fills the context.'] },
        { id: 'chat_sessions', ru: ['Сессии', 'Несколько историй с одним персонажем.'], en: ['Sessions', 'Several stories with one character.'] },
        { id: 'chat_history', phoneOnly: true, ru: ['Список чатов', 'Чаты, сгруппированные по персонажу.'], en: ['Chat list', 'Chats grouped by character.'] },
      ],
    },
    {
      icon: 'group',
      title: { ru: 'Персонажи', en: 'Characters' },
      items: [
        { id: 'characters', ru: ['Библиотека', 'Ваши персонажи, избранное и папки.'], en: ['Library', 'Your characters, favourites and folders.'] },
        { id: 'character_detail_info', ru: ['Карточка персонажа', 'Описание, теги и кнопка чата.'], en: ['Character page', 'Description, tags and a chat button.'] },
        { id: 'character_editor', ru: ['Редактор персонажа', 'Все поля карточки.'], en: ['Character editor', 'Every card field.'] },
        { id: 'character_filter', ru: ['Фильтры', 'Избранное, токены и теги.'], en: ['Filters', 'Favourites, tokens and tags.'] },
        { id: 'third_party_providers', ru: ['Провайдеры контента', 'Источники каталога включаются по одному.'], en: ['Content providers', 'Catalog sources, switched on one by one.'] },
      ],
    },
    {
      icon: 'construction',
      title: { ru: 'Инструменты', en: 'Tools' },
      items: [
        { id: 'tools', phoneOnly: true, ru: ['Инструменты', 'Плитки, которые можно переставлять.'], en: ['Tools', 'Tiles you can rearrange.'] },
        { id: 'tools_presets', ru: ['Пресеты', 'Встроенные и свои пресеты.'], en: ['Presets', 'Built-in and your own presets.'] },
        { id: 'tools_api', ru: ['Подключение API', 'Провайдер, модель и ключ.'], en: ['API connection', 'Provider, model and key.'] },
        { id: 'tools_embeddings', ru: ['Эмбеддинги', 'Подключение для векторного поиска.'], en: ['Embeddings', 'The connection for vector search.'] },
        { id: 'lorebook_editor', ru: ['Лорбук', 'Записи с поиском.'], en: ['Lorebook', 'Entries, with search.'] },
        { id: 'lorebook_connections', ru: ['Привязки лорбука', 'Глобально, для персонажа или для чата.'], en: ['Lorebook bindings', 'Global, per character or per chat.'] },
        { id: 'tools_regex', ru: ['Regex-скрипты', 'Скрипты пресета и глобальные.'], en: ['Regex scripts', 'Preset and global scripts.'] },
        { id: 'persona_editor', ru: ['Персона', 'За кого вы играете.'], en: ['Persona', 'Who you play as.'] },
      ],
    },
    {
      icon: 'brush',
      title: { ru: 'Оформление и настройки', en: 'Look and settings' },
      items: [
        { id: 'theme_editor', ru: ['Редактор темы', 'Цвета, шрифт и эффекты.'], en: ['Theme editor', 'Colours, font and effects.'] },
        { id: 'menu_settings', ru: ['Настройки', 'Все настройки с поиском.'], en: ['Settings', 'Every setting, with search.'] },
        { id: 'menu_glossary', ru: ['Глоссарий', 'Термины ИИ и ролевых игр.'], en: ['Glossary', 'AI and roleplay terms.'] },
      ],
    },
  ],

  // ── Releases, newest first ─────────────────────────────────────────────────
  releases: [
    {
      version: null,
      status: 'planned',
      title: { ru: 'Дальше', en: 'Next' },
      groups: [
        {
          items: {
            ru: ['???'],
            en: ['???'],
          },
        },
      ],
    },
    {
      version: '0.8.0',
      date: '2026-10-04',
      status: 'latest',
      channel: 'beta',
      tag: 'v0.8.0',
      // Release notes link to this post instead of the GitHub release page.
      article: '0.8.0',
      title: { ru: 'Каталоги, картинки и ПК', en: 'Catalogs, images and desktop' },
      groups: [
        {
          title: { ru: 'Чат', en: 'Chat' },
          items: {
            ru: [
              'Две выдвижные панели чата объединены в одну с вкладками, панель под полем ввода стала удобнее',
              'Кнопки над полем ввода настраиваются; «Продолжить» стало отдельной кнопкой',
              'Вставка до четырёх изображений в сообщение, в том числе из буфера обмена',
              'Кнопки быстрой вставки *звёздочек* и «кавычек» — в «Действиях» и в полноэкранном редакторе',
              'Каждое сообщение помечено персоной, от которой оно отправлено',
              'Метка в чате, откуда начинается история в промпте',
              'Инспектор промпта: таймлайн запросов и разбивка по токенам',
              'Карточка контекста под шапкой чата: что попадёт в запрос, а что отрезано',
              'Кнопка «наверх» и подтверждение удаления сообщений',
            ],
            en: [
              'The two chat drawers merged into one tabbed panel, and the composer row got more convenient',
              'Configurable composer buttons; Continue became a button of its own',
              'Paste up to four images into a message, from the clipboard included',
              'Quick-insert buttons for *asterisks* and "quotes", in Actions and the fullscreen editor',
              'Every user message is stamped with the persona that sent it',
              'A marker showing where the prompt\'s history begins',
              'Prompt inspector: a request timeline and a token breakdown',
              'A context card under the chat header: what makes the request, and what got cut',
              'A back-to-top button and a confirmation before deleting messages',
            ],
          },
        },
        {
          title: { ru: 'Память и лор', en: 'Memory and lore' },
          items: {
            ru: [
              'Единое окно памяти с новым поиском и сводками',
              'Отдельные пресеты для эмбеддингов, векторизация всего лорбука одной кнопкой',
            ],
            en: [
              'A unified Memory sheet with reworked search and summaries',
              'Separate embedding presets, vectorize a whole lorebook in one go',
            ],
          },
        },
        {
          title: { ru: 'Картинки', en: 'Images' },
          items: {
            ru: [
              'Нативный NovelAI, включая референсы V4.5',
              'ComfyUI со своими воркфлоу и импортом API-workflow',
              'xAI Imagine, OpenRouter, Electron Hub, A1111 и библиотека стилей',
              'Произвольные ширина и высота, правки Naistera',
            ],
            en: [
              'Native NovelAI, V4.5 references included',
              'ComfyUI with custom workflows and API-workflow import',
              'xAI Imagine, OpenRouter, Electron Hub, A1111 and a style library',
              'Custom width and height, plus Naistera fixes',
            ],
          },
        },
        {
          title: { ru: 'Каталог', en: 'Catalog' },
          items: {
            ru: [
              'Аккаунт Chub, нативные фильтры поиска и лента Timeline',
              'DataCat на новом Client API',
              'Импорт персонажей по ссылке с большего числа сайтов',
              'Размытие NSFW/NSFL-изображений с показом по нажатию',
              'Популярные пользовательские теги JanitorAI в фильтрах',
            ],
            en: [
              'Chub account, native search filters and the Timeline feed',
              'DataCat moved onto its new Client API',
              'Import characters by URL from more sites',
              'NSFW/NSFL images blurred until revealed',
              'JanitorAI\'s popular custom tags in the filters',
            ],
          },
        },
        {
          title: { ru: 'Пресеты и API', en: 'Presets and API' },
          items: {
            ru: [
              'Новый пресет по умолчанию для свежей установки — Shino',
              'Токенайзеры под каждую модель: Claude, Gemini, Llama, Qwen, DeepSeek, Mistral и другие',
              'Обрезка истории в режиме, дружественном к кэшированию',
              'Постобработка промпта как в SillyTavern для кастомных эндпоинтов',
              'Поддержка NoAssistant, Responses API как отдельный протокол',
              'Экономные параметры генерации для новых подключений и сброс настроек API',
            ],
            en: [
              'A new default preset for a fresh install — Shino',
              'Tokenizers for every model: Claude, Gemini, Llama, Qwen, DeepSeek, Mistral and more',
              'History trimming in a cache-friendly mode',
              'SillyTavern-style prompt post-processing for custom endpoints',
              'NoAssistant support, Responses API as a protocol of its own',
              'Lean generation defaults for new connections and a reset for API settings',
            ],
          },
        },
        {
          title: { ru: 'ПК и интерфейс', en: 'Desktop and UI' },
          items: {
            ru: [
              'Три колонки, плавающие окна, горячие клавиши',
              'Нижние листы на ПК открываются окнами по центру',
              'Сетка «Инструменты» настраивается, как стартовый экран Windows Phone',
              'Папки в пресетах и других списках, сортировка и мультивыбор',
              'Единый стиль экранов, окон, шторок и переключателей',
              'Вишнёвый акцент и обновлённый логотип',
            ],
            en: [
              'Three columns, floating windows, keyboard shortcuts',
              'Bottom sheets open as centred windows on desktop',
              'A Tools grid you can rearrange like a Windows Phone start screen',
              'Folders, sorting and multi-select across presets and other lists',
              'One style for every screen, window, sheet and switch',
              'A cherry accent and a refreshed logo',
            ],
          },
        },
        {
          title: { ru: 'Персонажи и расширения', en: 'Characters and extensions' },
          items: {
            ru: [
              'JAR закончен и полностью встроен в Glaze',
              'extBlocks больше не эксперимент: импорт блоков оригинального расширения',
              'Настройки извлечения JanitorAI сведены в одну, гайд при первом открытии каталога',
            ],
            en: [
              'JAR is finished and fully built into Glaze',
              'extBlocks leave Experimental: the original extension\'s blocks import',
              'JanitorAI extraction settings merged into one, a catalog guide on first open',
            ],
          },
        },
        {
          title: { ru: 'Прочее', en: 'Other' },
          items: {
            ru: [
              'Пакет pacman и переносимый .tar.zst для Linux, APK для arm32',
              'Восстановление активной персоны из бэкапа SillyTavern',
              'Studio уходит на полный реворк',
            ],
            en: [
              'A pacman package and a portable .tar.zst for Linux, an arm32 APK',
              'The active persona is restored from a SillyTavern backup',
              'Studio goes in for a complete rework',
            ],
          },
        },
      ],
    },
    {
      version: '0.7.0-a',
      date: '2026-08-07',
      status: 'released',
      channel: 'beta',
      tag: 'v0.7.0-a',
      title: { ru: 'Исправления и Linux', en: 'Fixes and Linux' },
      groups: [
        {
          items: {
            ru: [
              'Вариации персонажа: отдельный раздел, их легко найти и безопасно менять',
              'Импорт нескольких лорбуков и пресетов за раз',
              'Песочница JS-моста расширений стала строже',
              'Инспектор промпта переведён на русский',
              'Сборка .deb для Linux',
              'Исправлены пустой чат на Windows, гонка WebView на iOS и импорт бэкапа',
            ],
            en: [
              'Character variations became their own destination, easy to find and safe to manage',
              'Import several lorebooks and presets at once',
              'A stricter sandbox for the extension JS bridge',
              'Prompt Inspector localized',
              'A .deb build for Linux',
              'Fixed the blank chat on Windows, an iOS WebView race and backup import',
            ],
          },
        },
      ],
    },
    {
      version: '0.7.0',
      date: '2026-07-28',
      status: 'released',
      channel: 'beta',
      tag: 'v0.7.0',
      title: { ru: 'Переписан на Flutter', en: 'Rewritten in Flutter' },
      groups: [
        {
          title: { ru: 'Основа', en: 'Foundation' },
          items: {
            ru: [
              'Приложение переписано с нуля на Flutter: нативные Android, iOS и Windows',
              'Данные в SQLite, бэкапы в формате .glz, восстановление после сбоев',
              'Каналы сборок: стабильная и тестовая версии ставятся рядом',
              'Проверка обновлений внутри приложения',
            ],
            en: [
              'Rewritten from scratch in Flutter: native Android, iOS and Windows',
              'Data in SQLite, .glz backups, crash recovery',
              'Build channels: stable and testing builds install side by side',
              'In-app update check',
            ],
          },
        },
        {
          title: { ru: 'Чат', en: 'Chat' },
          items: {
            ru: [
              'Новый рендер сообщений, свайп вправо для перегенерации',
              'Имперсонация и гайдед-генерация',
              'Инспектор промпта: контекст, превью и покрытие лорбуков в одном окне',
              'Список чатов показывает идущую генерацию и непрочитанные ответы',
              'Вибрация при ответе бота, выбор диапазона сообщений',
            ],
            en: [
              'A new message renderer, swipe right to regenerate',
              'Impersonation and guided generation',
              'Prompt Inspector: context, preview and lorebook coverage in one place',
              'The chat list shows live generation and unread replies',
              'Vibration on a bot reply, range-select messages',
            ],
          },
        },
        {
          title: { ru: 'Персонажи', en: 'Characters' },
          items: {
            ru: [
              'Каталог: JanitorAI с лорбуками, DataCat, Chub, JannyAI',
              'Голокарты: случайные персонажи с наклоном от гироскопа',
              'Подборка «Наш выбор» с персонажами от авторов',
              'Удаление с эффектом рассыпания',
            ],
            en: [
              'Catalog: JanitorAI with lorebooks, DataCat, Chub, JannyAI',
              'Holocards: random characters that tilt with the gyroscope',
              '"Our Picks": characters curated by the authors',
              'A dust-disintegration delete',
            ],
          },
        },
        {
          title: { ru: 'API и эксперименты', en: 'API and experiments' },
          items: {
            ru: [
              'Свои параметры запроса, переключатели параметров генерации, глубина истории рассуждений',
              'Кэширование промптов Anthropic',
              'Glaze Studio и расширения ExtBlocks за флагом «Экспериментальные функции»',
              'Зал славы тестеров с титрами в стиле «Звёздных войн»',
            ],
            en: [
              'Custom request parameters, generation-parameter toggles, reasoning history depth',
              'Anthropic prompt caching',
              'Glaze Studio and ExtBlocks extensions, behind Experimental Features',
              'A Hall of Fame for testers with a Star Wars crawl',
            ],
          },
        },
      ],
    },
    {
      version: '0.6.3-alpha',
      date: '2026-05-04',
      status: 'released',
      channel: 'alpha',
      tag: 'v0.6.3-alpha',
      title: { ru: 'Синхронизация без конфликтов', en: 'Sync without conflicts' },
      groups: [
        {
          items: {
            ru: [
              'Окно конфликтов синхронизации, синхронизация галереи в Google Drive',
              'Импорт персонажа по ссылке',
              'Импорт чатов в ПК-интерфейсе',
              'Виртуальный скролл в списке диалогов',
              'Диагностика зависаний воркера с копированием отчёта',
            ],
            en: [
              'A sync conflict screen, gallery sync for Google Drive',
              'Import a character by URL',
              'Chat import in the desktop layout',
              'Virtual scrolling in the dialog list',
              'Worker-timeout diagnostics with a copyable report',
            ],
          },
        },
      ],
    },
    {
      version: '0.6.2-alpha',
      date: '2026-05-04',
      status: 'released',
      channel: 'alpha',
      tag: 'v0.6.2-alpha',
      title: { ru: 'Бэкапы Tavo', en: 'Tavo backups' },
      groups: [
        {
          items: {
            ru: ['Парсер бэкапов Tavo переписан под настоящий формат FlatBuffer', 'Данные больше не теряются после перезапуска'],
            en: ['The Tavo backup parser rewritten for the real FlatBuffer format', 'No more data loss after a restart'],
          },
        },
      ],
    },
    {
      version: '0.6.1-alpha',
      date: '2026-05-03',
      status: 'released',
      channel: 'alpha',
      tag: 'v0.6.1-alpha',
      title: { ru: 'Хотфикс', en: 'Hotfix' },
      groups: [
        {
          items: {
            ru: ['reasoning_effort не отправляется, если выключен', 'Любой параметр генерации можно не отправлять', 'Выбор файла бэкапа снова открывается на Android'],
            en: ['reasoning_effort is not sent when disabled', 'Any generation parameter can be omitted', 'The backup file picker opens on Android again'],
          },
        },
      ],
    },
    {
      version: '0.6.0-alpha',
      date: '2026-05-03',
      status: 'released',
      channel: 'alpha',
      tag: 'v0.6.0-alpha',
      title: { ru: 'Облако и память', en: 'Cloud and memory' },
      groups: [
        {
          items: {
            ru: [
              'Облачная синхронизация через Dropbox и Google Drive, с шифрованием по желанию',
              'Книги памяти: черновики сводок и их внедрение в контекст',
              'Векторный поиск по лорбукам: несколько векторов на запись, поиск по ключам и по смыслу одновременно',
              'Токенизатор и разбивка контекста по токенам',
              'Галерея персонажа, импорт и экспорт CharX/ZIP',
              'Редактирование блока рассуждений',
              'Провайдер изображений rout.my и полные эндпоинты OpenAI',
              'Меньше расход батареи во время генерации',
            ],
            en: [
              'Cloud sync via Dropbox and Google Drive, optionally encrypted',
              'Memory books: summary drafts and their injection into context',
              'Vector lorebook retrieval: multiple vectors per entry, keyword and semantic search together',
              'A tokenizer and a token breakdown of the context',
              'Character gallery, CharX/ZIP import and export',
              'Editing the reasoning block',
              'rout.my image provider and full OpenAI image endpoints',
              'Less battery drain while generating',
            ],
          },
        },
      ],
    },
    {
      version: '0.5.1-alpha',
      date: '2026-04-12',
      status: 'released',
      channel: 'alpha',
      tag: 'v0.5.1-alpha',
      title: { ru: 'Удобство на ПК', en: 'Desktop comfort' },
      groups: [
        {
          items: {
            ru: [
              'Перетаскивание карточек персонажей в окно на ПК',
              'Размер шрифта и выбор своего шрифта',
              'Подсказка, когда чат не помещается в контекст',
              'Импорт и экспорт пресетов вместе с гайдед-промптами и regex',
              'Обновлённый онбординг, пресет Shino по умолчанию',
            ],
            en: [
              'Drag and drop character cards onto the window on PC',
              'Font size and custom font selection',
              'A hint when the chat overflows the context',
              'Preset import/export with guided prompts and regex',
              'Reworked onboarding, Shino as the default preset',
            ],
          },
        },
      ],
    },
    {
      version: '0.5.0-alpha',
      date: '2026-04-09',
      status: 'released',
      channel: 'alpha',
      tag: 'v0.5.0-alpha',
      title: { ru: 'Windows и Linux', en: 'Windows and Linux' },
      groups: [
        {
          items: {
            ru: [
              'Первые сборки для Windows и Linux (установщик, AppImage, deb, pacman)',
              'Генерация изображений прямо в чате и просмотрщик с промптом',
              'Гайдед-генерация',
              'Глоссарий терминов',
              'Горячие клавиши, Enter для отправки с физической клавиатуры',
              'Фоновая генерация на iOS',
            ],
            en: [
              'First Windows and Linux builds (installer, AppImage, deb, pacman)',
              'Inline image generation and a viewer showing the prompt',
              'Guided generation',
              'A glossary of terms',
              'Keyboard shortcuts, Enter to send on a physical keyboard',
              'Background generation on iOS',
            ],
          },
        },
      ],
    },
    {
      version: '0.4.0-alpha',
      date: '2026-03-29',
      status: 'released',
      channel: 'alpha',
      tag: 'v0.4.0-alpha',
      title: { ru: 'Первая публичная альфа', en: 'First public alpha' },
      groups: [
        {
          items: {
            ru: [
              'Android и iOS, приложение на Vue 3 и Capacitor',
              'Пресеты, карточки V2, лорбуки и regex из SillyTavern',
              'Макросы: переменные, случайный выбор, кубики',
              'Нативные рассуждения в отдельном блоке',
              'Статистика, темы, фоновая генерация с уведомлениями',
            ],
            en: [
              'Android and iOS, built on Vue 3 and Capacitor',
              'SillyTavern presets, V2 cards, lorebooks and regex',
              'Macros: variables, random choices, dice',
              'Native reasoning in its own block',
              'Statistics, theming, background generation with notifications',
            ],
          },
        },
      ],
    },
  ],
};
