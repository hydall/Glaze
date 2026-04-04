// Блокировка совсем старых WebView до загрузки Vue
(function () {
    try {
        var ua = navigator.userAgent;
        var match = ua.match(/Chrome\/(\d+)/);
        if (match && parseInt(match[1], 10) < 100) {
            var lang = (navigator.language || navigator.userLanguage || "en").substring(0, 2).toLowerCase();
            var isRu = lang === 'ru';
            var title = isRu ? "Обновите WebView" : "Update WebView";
            var desc = isRu ? "Ваша версия Android System WebView слишком старая (Chrome " + match[1] + ").<br><br>Приложение не может работать на версиях ниже 100. Пожалуйста, обновите системный компонент."
                : "Your Android System WebView is too old (Chrome " + match[1] + ").<br><br>The app cannot run on versions below 100. Please update the system component.";
            var btn = isRu ? "Обновить в Google Play" : "Update in Google Play";

            document.addEventListener('DOMContentLoaded', function () {
                document.body.style.opacity = '1';
                document.body.style.backgroundColor = '#19191a';
                document.body.innerHTML = '<div style="display:flex;flex-direction:column;align-items:center;justify-content:center;height:100vh;padding:24px;text-align:center;font-family:sans-serif;color:#fff;box-sizing:border-box;">' +
                    '<svg viewBox="0 0 24 24" style="width:64px;height:64px;fill:#ff4444;margin-bottom:16px"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>' +
                    '<h2 style="margin:0 0 12px 0;">' + title + '</h2>' +
                    '<p style="font-size:16px;line-height:1.5;margin:0 0 24px 0;opacity:0.8;">' + desc + '</p>' +
                    '<a href="https://play.google.com/store/apps/details?id=com.google.android.webview" style="display:inline-block;padding:12px 24px;background:#5181b8;color:#fff;text-decoration:none;border-radius:24px;font-weight:600;font-size:16px;">' + btn + '</a>' +
                    '</div>';
            });
        }
    } catch (e) { }
})();
