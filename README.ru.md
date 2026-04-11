<p align="center">
  <img src="assets/logo.png" width="256" alt="Glaze Logo">
</p>

# Glaze

[![Telegram](https://img.shields.io/badge/Telegram-2CA5E0?style=flat&logo=telegram&logoColor=white)](https://t.me/glazeapp)
[![Boosty](https://img.shields.io/badge/Boosty-F15F2C?style=flat&logo=boosty&logoColor=white)](https://boosty.to/hydall)

[English](README.md)

Glaze — это локальный, удобный для новичков ИИ-клиент для ролевых чатов на мобильных устройствах. Работает с любым OpenAI-совместимым (Chat Completion) LLM-провайдером.

> [!WARNING]
> Glaze всё ещё находится в стадии активной разработки. Приложение пока нестабильно и может содержать ошибки.
>
> 🧪 **Дисклеймер**: Это приложение было **vibecoded** с помощью Gemini 3 Flash, 3.1 Pro и Claude Opus 4.6. Умерьте свои ожидания.

## 📸 Скриншоты

| | | |
|:---:|:---:|:---:|
| <img src="assets/screenshots/screenshot_02.png" width="200"> | <img src="assets/screenshots/screenshot_03.png" width="200"> | <img src="assets/screenshots/screenshot_04.png" width="200"> |
| <img src="assets/screenshots/screenshot_05.png" width="200"> | <img src="assets/screenshots/screenshot_06.png" width="200"> | <img src="assets/screenshots/screenshot_07.png" width="200"> |
| <img src="assets/screenshots/screenshot_08.png" width="200"> | <img src="assets/screenshots/screenshot_01.png" width="200"> | |

## ✨ Основные Особенности

- **Простая Установка и Удобный Интерфейс** — Вам не требуются глубокие познания в ИТ, чтобы пользоваться приложением. Просто установите его и начните общаться.
- **Реально Работающая Статистика Пользователя** — Получайте наглядную информацию о том, сколько сообщений вы отправили, сколько часов провели в приложении и многом другом.
- **Поддержка Моделей с Рассуждениями (Reasoning)** — Больше никаких регулярных выражений; встроенные рассуждения корректно распознаются и помещаются в отдельный блок, который не отправляется обратно модели. В вашем пресете используются собственные теги для рассуждений? Glaze может обрабатывать и их.
- **Гибкая Темизация** — Glaze позволяет легко настраивать внешний вид приложения. Изменяйте цвета, шрифты и фоновые изображения, а затем экспортируйте свою тему в виде JSON-файла, чтобы поделиться ею с другими.
- **Фоновая Генерация** — Glaze может генерировать ответы в фоновом режиме и отправит вам уведомление, когда всё будет готово.

## 🤝 Базовая Совместимость с SillyTavern

- **Пресеты** — Все JSON-пресеты для SillyTavern совместимы с Glaze. Несколько популярных пресетов уже установлены по умолчанию.
- **Продвинутая Система Макросов** — Доступна базовая поддержка макросов (полная совместимость с SillyTavern пока в разработке). Поддерживаются переменные (setvars/getvars), случайный выбор, броски кубиков и подстановка данных персонажа/пользователя.
- **Совместимость с Карточками Персонажей** — Импорт и экспорт карточек персонажей в формате SillyTavern V2 (JSON и PNG).
- **Лорбуки (World Info)** — Полная поддержка лорбуков для более глубокого погружения в ролевую игру.
- **Поддержка Регулярных Выражений (Regex)** — Полная поддержка скриптов регулярных выражений, включая те, что встроены в ваши любимые пресеты.

## 📥 Установка

Загрузите последний релиз со страницы [Releases](../../releases).

- **Android** — Установите APK-файл напрямую на ваше устройство.
- **iOS** — Установите IPA-файл методом неофициальной загрузки (sideloading) с помощью [AltStore](https://altstore.io/) или аналогичного инструмента. Приложение пока недоступно в App Store.
- **Windows и Linux*** — Загрузите установщик для поддерживаемой ОС и запустите его прямо на своем компьютере. 

## 🛠️ Разработка

Glaze создан на базе Vue 3 и Capacitor и предлагает простую кроссплатформенную разработку. Порядок внесения вклада описан в [руководстве по содействию](CONTRIBUTING.md). Для разработки вам понадобятся Node.js и устройство на базе Android/iOS или эмулятор.

### 📋 Предварительные Требования

- [Node.js](https://nodejs.org/) 18+
- [Android Studio](https://developer.android.com/studio) (для сборки под Android)
- Xcode (для сборки под iOS, только macOS)

### 🏗️ Настройка

```bash
git clone https://github.com/hydall/glaze.git
cd glaze
npm install
```

### 🚀 Сервер для Разработки

```bash
npm run dev
```

### 🤖 Сборка для Android

```bash
npm run build
npx cap sync android
npx cap open android
```

### 🍏 Сборка для iOS

```bash
npm run build
npx cap sync ios
npx cap open ios
```

### 🧪 Тестирование

```bash
npm test
```

## 📜 Лицензия

Этот проект распространяется по лицензии [GNU Affero General Public License v3.0](LICENSE).
