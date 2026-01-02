import { currentLang } from './APPSettings.js';
import { translations } from './i18n.js';

export function formatDate(timestamp, format = 'short') {
    if (!timestamp) return "";
    
    const date = new Date(timestamp);
    const now = new Date();
    
    const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const startOfMsgDay = new Date(date.getFullYear(), date.getMonth(), date.getDate());
    
    const diff = startOfToday.getTime() - startOfMsgDay.getTime();
    const oneDay = 24 * 60 * 60 * 1000;
    
    const h = String(date.getHours()).padStart(2, '0');
    const min = String(date.getMinutes()).padStart(2, '0');
    const timeStr = `${h}:${min}`;
    
    const d = String(date.getDate()).padStart(2, '0');
    const m = String(date.getMonth() + 1).padStart(2, '0');
    const dateStr = `${d}.${m}`;

    const t = translations[currentLang] || {};
    const yesterdayText = t['date_yesterday'] || 'Yesterday';

    if (diff === 0) { // Today
        // Short: Time
        // Long: DD.MM HH:MM
        if (format === 'short') return timeStr;
        return `${dateStr} ${timeStr}`;
    }
    
    if (diff === oneDay) { // Yesterday
        // Short: Yesterday
        // Long: Yesterday HH:MM
        if (format === 'short') return yesterdayText;
        return `${yesterdayText} ${timeStr}`;
    }
    
    // Other days
    // Short: DD.MM
    // Long: HH:MM, DD.MM
    if (format === 'short') return dateStr;
    return `${timeStr}, ${dateStr}`;
}