import { db, queueDbWrite } from '@/utils/db.js';
import { PRESET_COLORS } from '@/core/states/themeConstants.js';

const PRESET_FIELDS = [
    'accentColor', 'bgOpacity', 'bgBlur', 'elementOpacity', 'elementBlur',
    'uiColor', 'chatLayout', 'userBubbleColor', 'charBubbleColor',
    'userQuoteColor', 'charQuoteColor', 'userTextColor', 'charTextColor',
    'userItalicColor', 'charItalicColor', 'uiFontSize', 'uiLetterSpacing',
    'chatFontSize', 'chatLetterSpacing', 'uiFontMode', 'chatFontMode',
    'uiTextColor', 'uiTextGrayColor', 'borderWidth', 'borderColor',
    'borderOpacity', 'noiseOpacity', 'noiseIntensity', 'bgNoiseOpacity',
    'bgNoiseIntensity'
];

const BLOB_FIELDS = ['bgImage', 'customFont', 'customFontName', 'chatFont', 'chatFontName'];

export function presetFromState(state) {
    const preset = {};
    for (const key of PRESET_FIELDS) {
        preset[key] = state[key];
    }
    return preset;
}

export async function presetFromStateWithBlobs(state) {
    const preset = presetFromState(state);
    if (state.hasBackgroundImage) {
        preset.bgImage = await db.get('gz_theme_bg');
    } else {
        preset.bgImage = null;
    }
    if (state.customFontName) {
        preset.customFont = await db.get('gz_theme_font');
        preset.customFontName = await db.get('gz_theme_font_name');
    } else {
        preset.customFont = null;
        preset.customFontName = null;
    }
    if (state.chatFontName) {
        preset.chatFont = await db.get('gz_theme_chat_font');
        preset.chatFontName = await db.get('gz_theme_chat_font_name');
    } else {
        preset.chatFont = null;
        preset.chatFontName = null;
    }
    return preset;
}

export function presetToExport(preset) {
    const data = {
        _type: 'silly_cradle_theme',
        name: preset.name,
        author: preset.author || ''
    };
    for (const key of [...PRESET_FIELDS, ...BLOB_FIELDS]) {
        data[key] = preset[key] ?? null;
    }
    data.uiFontMode = preset.uiFontMode || 'glaze';
    data.chatFontMode = preset.chatFontMode || 'ui';
    return data;
}

export function presetFromImport(jsonData, defaultName) {
    if (!jsonData || jsonData._type !== 'silly_cradle_theme') {
        throw new Error('Invalid theme file format');
    }
    const p = {
        id: Date.now().toString(),
        name: jsonData.name || defaultName || 'Imported Theme',
        author: jsonData.author || ''
    };
    for (const key of PRESET_FIELDS) {
        p[key] = jsonData[key] !== undefined ? jsonData[key] : null;
    }
    p.accentColor = jsonData.accentColor || PRESET_COLORS[0];
    p.bgOpacity = jsonData.bgOpacity !== undefined ? jsonData.bgOpacity : 0.85;
    p.bgBlur = jsonData.bgBlur !== undefined ? jsonData.bgBlur : 0;
    p.elementOpacity = jsonData.elementOpacity !== undefined ? jsonData.elementOpacity : 0.8;
    p.elementBlur = jsonData.elementBlur !== undefined ? jsonData.elementBlur : 12;
    p.chatLayout = jsonData.chatLayout || 'default';
    p.uiFontSize = jsonData.uiFontSize !== undefined ? jsonData.uiFontSize : 'system';
    p.uiLetterSpacing = jsonData.uiLetterSpacing !== undefined ? jsonData.uiLetterSpacing : 0;
    p.chatFontSize = jsonData.chatFontSize !== undefined ? jsonData.chatFontSize : 'system';
    p.chatLetterSpacing = jsonData.chatLetterSpacing !== undefined ? jsonData.chatLetterSpacing : 0;
    p.uiFontMode = jsonData.uiFontMode || (jsonData.customFont ? 'custom' : 'glaze');
    p.chatFontMode = jsonData.chatFontMode || (jsonData.chatFont ? 'custom' : 'ui');
    p.borderWidth = jsonData.borderWidth !== undefined ? jsonData.borderWidth : 1;
    p.borderOpacity = jsonData.borderOpacity !== undefined ? jsonData.borderOpacity : 0.1;
    p.noiseOpacity = jsonData.noiseOpacity !== undefined ? jsonData.noiseOpacity : 0.03;
    p.noiseIntensity = jsonData.noiseIntensity !== undefined ? jsonData.noiseIntensity : 0.8;
    p.bgNoiseOpacity = jsonData.bgNoiseOpacity !== undefined ? jsonData.bgNoiseOpacity : 0.03;
    p.bgNoiseIntensity = jsonData.bgNoiseIntensity !== undefined ? jsonData.bgNoiseIntensity : 0.4;
    for (const key of BLOB_FIELDS) {
        p[key] = jsonData[key] || null;
    }
    return p;
}

export function newPresetObject(name, chatLayout) {
    return {
        id: Date.now().toString(),
        name,
        author: '',
        accentColor: PRESET_COLORS[0],
        bgOpacity: 0.85,
        bgBlur: 0,
        elementOpacity: 0.8,
        elementBlur: 12,
        bgImage: null,
        uiColor: null,
        customFont: null,
        customFontName: null,
        chatLayout: chatLayout || 'default',
        uiTextColor: null,
        uiTextGrayColor: null,
        userBubbleColor: null,
        charBubbleColor: null,
        userQuoteColor: null,
        charQuoteColor: null,
        userTextColor: null,
        charTextColor: null,
        userItalicColor: null,
        charItalicColor: null,
        uiFontSize: 'system',
        uiLetterSpacing: 0,
        chatFontSize: 'system',
        chatLetterSpacing: 0,
        chatFont: null,
        chatFontName: null,
        uiFontMode: 'glaze',
        chatFontMode: 'ui',
        borderWidth: 1,
        borderColor: null,
        borderOpacity: 0.1,
        noiseOpacity: 0.03,
        noiseIntensity: 0.8,
        bgNoiseOpacity: 0.03,
        bgNoiseIntensity: 0.4
    };
}

export async function getPresetsFromDb() {
    return (await db.get('gz_theme_presets')) || [];
}

export async function savePresetsToDb(presets) {
    await db.set('gz_theme_presets', presets);
}

export async function getActivePresetId() {
    return db.get('gz_theme_active_preset');
}

export async function setActivePresetId(id) {
    await db.set('gz_theme_active_preset', id);
}

export async function saveBlobKeys(fontDataUrl, fontName, chatFontDataUrl, chatFontName, bgImageDataUrl) {
    if (fontDataUrl !== undefined) {
        await db.set('gz_theme_font', fontDataUrl);
        await db.set('gz_theme_font_name', fontName || null);
    }
    if (chatFontDataUrl !== undefined) {
        await db.set('gz_theme_chat_font', chatFontDataUrl);
        await db.set('gz_theme_chat_font_name', chatFontName || null);
    }
    if (bgImageDataUrl !== undefined) {
        await db.set('gz_theme_bg', bgImageDataUrl);
    }
}

export function scheduleDbSave(state, isApplyingPreset, getSaveTimeout, setSaveTimeout) {
    if (isApplyingPreset) return;
    const current = getSaveTimeout();
    if (current) clearTimeout(current);
    setSaveTimeout(setTimeout(() => {
        queueDbWrite(() => saveStateToActivePreset(state));
    }, 500));
}

async function saveStateToActivePreset(state) {
    if (!state.activePresetId) return;
    const presets = (await db.get('gz_theme_presets')) || [];
    const index = presets.findIndex(p => p.id === state.activePresetId);
    if (index === -1) return;

    if (state.activePresetId === 'default') {
        // Default preset stays same
    } else {
        const fullPreset = await presetFromStateWithBlobs(state);
        presets[index] = { ...presets[index], ...fullPreset };
    }

    await db.set('gz_theme_presets', presets);
}
