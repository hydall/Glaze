const savedLang = localStorage.getItem('sc_lang');
const systemLang = (navigator.language || 'en').toLowerCase().startsWith('ru') ? 'ru' : 'en';
export let currentLang = savedLang || systemLang;

export function setLanguage(lang) {
    currentLang = lang;
    localStorage.setItem('sc_lang', lang);
}

export let themeMode = localStorage.getItem('sc_theme') || 'system';
export function setThemeMode(mode) {
    themeMode = mode;
    localStorage.setItem('sc_theme', mode);
}
export function getThemeMode() {
    return themeMode;
}

export let imageViewerMode = localStorage.getItem('sc_image_viewer') || 'default';
export function setImageViewerMode(mode) {
    imageViewerMode = mode;
    localStorage.setItem('sc_image_viewer', mode);
}