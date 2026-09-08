# Технический анализ и архитектура: Единый JS-фреймворк для Glaze (Flutter / Mobile)

В данном документе представлен технический анализ и архитектурный дизайн для внедрения поддержки динамического выполнения JavaScript и расширений (аналог **JS-Slash-Runner** и **ExtBlocks**) в мобильный клиент **Glaze** на базе **Flutter**.

---

## 1. Архитектурный обзор

Мобильные платформы (Android и iOS) накладывают строгие ограничения на выполнение динамического кода и рендеринг веб-контента. В отличие от десктопного браузера, где SillyTavern работает в едином DOM-пространстве, во Flutter-приложении требуется разделение на две среды:

1.  **Интерфейсный уровень (UI Renderers):** Встроенные в сообщения чата виджеты `WebView` для отрисовки интерактивных HTML-панелей.
2.  **Фоновый уровень (Background Script Engine):** Изолированный безголовый (headless) JS-движок для отслеживания игрового состояния, фоновой генерации контекста и обработки событий.

### Схема взаимодействия компонентов

```mermaid
graph TD
    subgraph Flutter Host (Glaze)
        AppVars[Хранилище переменных Glaze]
        CommandExec[Исполнитель STScript / Команд]
        LLMConn[Модуль LLM подключений]
        ChatScreen[Экран чата Flutter]
    end

    subgraph Headless JS Runtime (Фоновый движок)
        BGRuntime[QuickJS / Скрытый WebView]
        BGScripts[Фоновые скрипты: глобальные/персонажные]
    end

    subgraph Message Bubble (UI WebView)
        UIFrame[WebView во фрейме сообщения]
        UIJs[Интерактивный JS-код интерфейса]
    end

    %% Взаимодействие фонового движка и Glaze
    BGRuntime -- "glaze.executeCommand()" --> CommandExec
    BGRuntime -- "glaze.getVariables() / updateVariables()" --> AppVars
    BGRuntime -- "glaze.generateText()" --> LLMConn
    
    %% Взаимодействие UI-фрейма и Glaze
    UIJs -- "glaze.executeCommand()" --> CommandExec
    UIJs -- "glaze.getVariables() / updateVariables()" --> AppVars

    %% Отображение
    ChatScreen -- "Внедряет HTML" --> UIFrame
```

---

## 2. Лучшее из двух миров (Слияние концепций)

Объединив визуальную мощь **Tavern Helper** и логическую глубину **ExtBlocks**, мы получаем единую, более простую и гибкую систему:

*   **Отмена сложного MongoDB-синтаксиса в YAML (улучшение ExtBlocks):** Вместо сложного парсинга операторов вроде `$push` или `$inc` через YAML-апдейтеры, всё состояние меняется с помощью стандартного JavaScript. Это упрощает написание логики для авторов карт и делает её нативной.
*   **Группировка по Connection Profiles (улучшение ExtBlocks):** Glaze предоставляет фоновым скриптам доступ к своим настроенным профилям ИИ. Скрипт может просто вызвать `glaze.generateText(prompt, { modelPreset: 'small' })`.
*   **Единый JavaScript Bridge SDK:** И фоновые скрипты, и интерактивные UI-панели используют **один и тот же JS-интерфейс (`window.glaze`)**, что устраняет путаницу в методах.

---

## 3. Спецификация единого JavaScript API (`glaze.*`)

Каждая среда исполнения JS (фоновая и визуальная) получает автоматически инжектируемый глобальный объект `glaze`, реализующий следующий интерфейс:

```typescript
interface GlazeAPI {
  // --- РАЗДЕЛ 1: Переменные (State Management) ---
  /** Получить все переменные или по конкретному пути (поддерживается dot-notation через lodash) */
  getVariables(scope: 'chat' | 'global' | 'character' | 'message', path?: string): Promise<any>;
  /** Обновить переменные, объединив их с текущими */
  setVariables(scope: 'chat' | 'global' | 'character' | 'message', data: Record<string, any>): Promise<void>;
  /** Удалить переменную по указанному пути */
  deleteVariable(scope: 'chat' | 'global' | 'character' | 'message', path: string): Promise<void>;

  // --- РАЗДЕЛ 2: Команды и Управление (Execution) ---
  /** Выполнить слэш-команду или макрос в консоли Glaze */
  executeCommand(command: string): Promise<string>;
  /** Запустить генерацию ответа ИИ (эквивалент /trigger) */
  triggerGeneration(): Promise<void>;

  // --- РАЗДЕЛ 3: Внедрение промптов (Prompt Injection) ---
  /** Динамически внедрить системную инструкцию в контекст следующей генерации */
  injectPrompt(id: string, content: string, options?: { depth?: number; role?: 'system' | 'user' | 'assistant' }): Promise<void>;
  /** Удалить ранее внедренный промпт */
  uninjectPrompt(id: string): Promise<void>;

  // --- РАЗДЕЛ 4: Вспомогательные генерации (Secondary LLM Calls) ---
  /** Сделать запрос к LLM через Glaze, используя один из сохраненных профилей подключения */
  generateText(prompt: string, options?: { preset?: 'big' | 'medium' | 'small'; temperature?: number }): Promise<string>;

  // --- РАЗДЕЛ 5: Уведомления и Медиа ---
  /** Показать системное всплывающее уведомление (toast) на экране мобильного устройства */
  showToast(message: string, type?: 'success' | 'info' | 'warning' | 'error'): void;
  /** Воспроизвести аудиофайл по URL или пути из ресурсов */
  playAudio(audioUrl: string): void;
}
```

---

## 4. Реализация на стороне Flutter (Glaze)

### А. Среда исполнения скриптов (Execution Engines)

#### 1. Background Engine (Фоновые скрипты)
Для выполнения JS без визуального рендеринга на мобильных устройствах есть два пути:
*   **Вариант A (Рекомендуемый для производительности):** Использование библиотеки `flutter_js` (под капотом QuickJS).
    *   *Плюсы:* Работает в фоне нативно, быстро запускается, не требует тяжелых WebView.
    *   *Минусы:* Нет встроенной поддержки событий жизненного цикла браузера, сетевых запросов `fetch` и DOM-структур (нужно полифиллить).
*   **Вариант Б (Рекомендуемый для совместимости):** Скрытый, постоянно работающий экземпляр `HeadlessInAppWebView` (из пакета `flutter_inappwebview`).
    *   *Плюсы:* Идеальная совместимость со всеми JS-библиотеками, полноценный стек браузера (`fetch`, `Promises`, `localStorage`, `console.log`).
    *   *Минусы:* Потребляет немного больше оперативной памяти.

> [!TIP]
> **Решение для Glaze:** Использование **`HeadlessInAppWebView`** является оптимальным выбором на первом этапе для обеспечения 100% совместимости со скриптами, написанными для десктопного SillyTavern.

#### 2. UI Renderer (Интерактивные сообщения)
Интеграция интерактивных окон внутрь списка сообщений Flutter:
*   Для каждого сообщения чата, содержащего HTML-код (с тегами `<body>`), Flutter-виджет `MessageBubble` рендерит встроенный `InAppWebView`.
*   Необходимо ограничить высоту фрейма во избежание сбоев прокрутки списка чата. Высота вычисляется динамически на основе контента (`document.body.scrollHeight`) и передается через мост во Flutter.

### Б. Реализация двустороннего моста (Javascript Channels)

Для интеграции JS с Dart-кодом используется механизм сообщений.

**Пример инициализации моста во Flutter:**

```dart
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// Настройка WebView для рендерера сообщений
Widget buildMessageWebView(String htmlContent, ChatController chatController) {
  return InAppWebView(
    initialData: InAppWebViewInitialData(
      data: htmlContent,
      mimeType: 'text/html',
      encoding: 'utf-8',
    ),
    onWebViewCreated: (controller) {
      // Регистрируем обработчик вызова команд
      controller.addJavaScriptHandler(
        handlerName: 'glazeBridge',
        callback: (args) async {
          final String method = args[0];
          final Map<String, dynamic> params = args[1];

          switch (method) {
            case 'executeCommand':
              final result = await chatController.executeSTScript(params['command']);
              return {'status': 'ok', 'data': result};
            case 'setVariables':
              await chatController.updateVariables(params['scope'], params['data']);
              return {'status': 'ok'};
            case 'getVariables':
              final data = chatController.getVariables(params['scope']);
              return {'status': 'ok', 'data': data};
            case 'generateText':
              final text = await chatController.generateTextSecondary(params['prompt'], params['preset']);
              return {'status': 'ok', 'data': text};
            default:
              return {'status': 'error', 'message': 'Unknown method'};
          }
        },
      );
    },
  );
}
```

**Инжектируемый на стороне JS SDK-код (прослойка моста):**

```javascript
window.glaze = {
  async executeCommand(command) {
    const response = await window.flutter_inappwebview.callHandler('glazeBridge', 'executeCommand', { command });
    return response.data;
  },
  async getVariables(scope, path) {
    const response = await window.flutter_inappwebview.callHandler('glazeBridge', 'getVariables', { scope });
    if (path) {
      // Использование встроенного в прослойку мини-lodash для быстрого получения данных по пути
      return getObjectPathValue(response.data, path);
    }
    return response.data;
  },
  async setVariables(scope, data) {
    await window.flutter_inappwebview.callHandler('glazeBridge', 'setVariables', { scope, data });
  },
  async generateText(prompt, options = {}) {
    const response = await window.flutter_inappwebview.callHandler('glazeBridge', 'generateText', { prompt, preset: options.preset || 'small' });
    return response.data;
  }
};
```

---

## 5. Безопасность и оптимизация производительности на мобильных ОС

Поскольку выполнение JS происходит на мобильном устройстве пользователя, критически важно учесть следующие аспекты:

1.  **Песочница (Sandbox):** WebViews не должны иметь доступ к локальным файлам приложения (`android:allowFileAccess="false"`, `ios:allowUniversalAccessFromFileURLs="false"`). Скрипты должны взаимодействовать с системой *исключительно* через определенный нами Dart-мост.
2.  **Энергопотребление (Background Execution):** Фоновый `HeadlessInAppWebView` должен переходить в режим глубокого сна (или полностью приостанавливать выполнение скриптов через `pauseTimers()`), когда приложение свернуто или экран заблокирован.
3.  **Переиспользование пула WebViews:** Создание и уничтожение WebView для каждого сообщения при скроллинге чата вызовет сильные лаги (jank). Рекомендуется использовать **кэшируемый пул WebView-виджетов** или конвертировать неактивные (прокрученные наверх) сообщения в статичные скриншоты/HTML-текст без активного JS.

---

## 6. Пошаговый план внедрения в Glaze

```
[ ] Этап 1: Добавление базовых зависимостей
    - Интеграция flutter_inappwebview в pubspec.yaml.
    - Настройка политик безопасности для AndroidManifest.xml и Info.plist.

[ ] Этап 2: Создание Headless JS-контекста
    - Разработка синглтон-сервиса (напр. `JsEngineService`), инициализирующего фоновый headless-контекст при запуске чата.
    - Реализация инъекции JS SDK.

[ ] Этап 3: Реализация Dart-моста для работы со стейтом чата
    - Связывание локального стейта чата Glaze (переменные, макросы) с API `getVariables` / `setVariables`.
    - Поддержка выполнения STScript-команд через мост.

[ ] Этап 4: Разработка визуального Message WebView виджета
    - Создание обертки для отображения UI в сообщениях чата.
    - Настройка авто-изменения высоты веб-вью по высоте документа.

[ ] Этап 5: Логика фоновой генерации (аналог ExtBlocks)
    - Перенос концепции фоновых генераций: запуск выполнения триггеров на новые сообщения.
    - Внедрение инжектированных скриптами промптов в итоговый контекст сборщика истории Glaze.
```
