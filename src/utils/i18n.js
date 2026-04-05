import { ref } from 'vue';
import ru from '@/locales/ru/index.json';
import en from '@/locales/en/index.json';
import ruGlossary from '@/locales/ru/glossary.json';
import enGlossary from '@/locales/en/glossary.json';
import { currentLang } from '@/core/config/APPSettings.js';

export const translations = {
    ru: { ...ru, glossary: ruGlossary },
    en: { ...en, glossary: enGlossary }
};

export const i18nTrigger = ref(0);

export function t(key) {
    // Read the trigger so Vue tracks this call
    const _track = i18nTrigger.value;
    return translations[currentLang.value] ? (translations[currentLang.value][key] || key) : key;
}

export function pluralize(count, key) {
    const wordInfo = translations[currentLang.value]?.[key];
    if (!wordInfo) return key;

    if (Array.isArray(wordInfo)) {
        if (currentLang.value === 'ru') {
            const cases = [2, 0, 1, 1, 1, 2];
            return wordInfo[(count % 100 > 4 && count % 100 < 20) ? 2 : cases[(count % 10 < 5) ? Math.floor(count % 10) : 5]];
        } else {
            return count === 1 ? wordInfo[0] : (wordInfo[1] || wordInfo[0]);
        }
    }
    return wordInfo;
}

export function updateLanguage() {
    i18nTrigger.value++;

    const i18nElements = document.querySelectorAll('[data-i18n]');
    const placeholderElements = document.querySelectorAll('[data-i18n-placeholder]');
    const headerTitle = document.getElementById('header-title');

    const elementsToAnimate = [...i18nElements, ...placeholderElements];
    if (headerTitle) elementsToAnimate.push(headerTitle);

    // Fade Out
    elementsToAnimate.forEach(el => {
        el.style.transition = 'opacity 0.15s ease';
        el.style.opacity = '0';
    });

    setTimeout(() => {
        // Update elements with data-i18n
        i18nElements.forEach(el => {
            const key = el.getAttribute('data-i18n');
            if (translations[currentLang.value][key]) {
                el.textContent = translations[currentLang.value][key];
            }
        });

        // Update placeholders
        placeholderElements.forEach(el => {
            const key = el.getAttribute('data-i18n-placeholder');
            if (translations[currentLang.value][key]) {
                el.placeholder = translations[currentLang.value][key];
            }
        });

        // Update Header Title based on active tab
        const activeTab = document.querySelector('.tab-btn.active');
        if (activeTab && headerTitle) {
            const titleKey = activeTab.getAttribute('data-i18n-title');
            if (titleKey && translations[currentLang.value][titleKey]) {
                headerTitle.textContent = translations[currentLang.value][titleKey];
            }
        }

        // Fade In
        elementsToAnimate.forEach(el => {
            el.style.opacity = '1';
        });

        // Cleanup
        setTimeout(() => {
            elementsToAnimate.forEach(el => {
                el.style.transition = '';
                el.style.opacity = '';
            });
        }, 150);
    }, 150);
}
