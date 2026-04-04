import { reactive } from 'vue';
import { db, queueDbWrite } from '@/utils/db.js';
import { setThemeMode } from '@/core/config/APPSettings.js';

export const themeState = reactive({
    accentColor: '#7996ce',
    lastCustomColor: '#ff0000', // Default fallback
    hasBackgroundImage: false,
    bgOpacity: 0.85,
    bgBlur: 0,
    elementOpacity: 0.8,
    elementBlur: 12,
    uiColor: null,
    customFontName: null,
    activePresetId: null,
    themeMode: 'dark',
    chatLayout: 'default',
    userBubbleColor: null,
    charBubbleColor: null,
    userQuoteColor: null,
    charQuoteColor: null,
    userTextColor: null,
    charTextColor: null,
    userItalicColor: null,
    charItalicColor: null,
    uiFontSize: 15,
    uiLetterSpacing: 0,
    chatFontSize: 15,
    chatLetterSpacing: 0,
    chatFontName: null,
    borderWidth: 1,
    borderColor: null,
    borderOpacity: 0.1,
    noiseOpacity: 0.03,
    noiseIntensity: 0.8,
    bgNoiseOpacity: 0.03,
    bgNoiseIntensity: 0.4
});

export const PRESET_COLORS = [
    '#7996ce', // Default
    '#E0555D', // Red
    '#4BB34B', // Green
    '#FFA000', // Orange
    '#8858c9', // Purple
    '#333333', // Black/Dark
    '#007AFF', // iOS Blue
    '#FF2D55', // iOS Pink
];

export const PRESET_UI_COLORS = [
    '#ffffff', // White
    '#19191a', // Dark
    '#7996ce', // Default
    '#E0555D', // Red
    '#4BB34B', // Green
    '#FFA000', // Orange
    '#8858c9', // Purple
];

export const DEFAULT_PRESET = {
    id: 'default',
    name: 'Default',
    author: '',
    themeMode: 'dark',
    accentColor: '#7996ce',
    bgOpacity: 0.85,
    bgBlur: 0,
    elementOpacity: 0.8,
    elementBlur: 12,
    uiColor: null,
    bgImage: null,
    customFont: null,
    customFontName: null,
    chatLayout: 'default',
    userBubbleColor: null,
    charBubbleColor: null,
    userQuoteColor: null,
    charQuoteColor: null,
    userTextColor: null,
    charTextColor: null,
    userItalicColor: null,
    charItalicColor: null,
    uiFontSize: 15,
    uiLetterSpacing: 0,
    chatFontSize: 15,
    chatLetterSpacing: 0,
    chatFont: null,
    chatFontName: null,
    borderWidth: 1,
    borderColor: null,
    borderOpacity: 0.1,
    noiseOpacity: 0.03,
    noiseIntensity: 0.8,
    bgNoiseOpacity: 0.03,
    bgNoiseIntensity: 0.4
};

let saveTimeout = null;
let isApplyingPreset = false;

function scheduleSave() {
    if (isApplyingPreset) return;
    if (saveTimeout) clearTimeout(saveTimeout);
    saveTimeout = setTimeout(() => {
        queueDbWrite(() => saveStateToActivePreset());
    }, 500);
}

async function saveStateToActivePreset() {
    if (!themeState.activePresetId) return;
    const presets = (await db.get('gz_theme_presets')) || [];
    const index = presets.findIndex(p => p.id === themeState.activePresetId);
    if (index === -1) return;

    if (themeState.activePresetId === 'default') {
        presets[index] = {
            ...presets[index],
            themeMode: themeState.themeMode
        };
    } else {
        const bgImage = themeState.hasBackgroundImage ? await db.get('gz_theme_bg') : null;
        const font = themeState.customFontName ? await db.get('gz_theme_font') : null;
        const fontName = themeState.customFontName ? await db.get('gz_theme_font_name') : null;

        const chatFontData = themeState.chatFontName ? await db.get('gz_theme_chat_font') : null;
        const chatFontNameData = themeState.chatFontName ? await db.get('gz_theme_chat_font_name') : null;

        presets[index] = {
            ...presets[index],
            themeMode: themeState.themeMode,
            accentColor: themeState.accentColor,
            bgOpacity: themeState.bgOpacity,
            bgBlur: themeState.bgBlur,
            elementOpacity: themeState.elementOpacity,
            elementBlur: themeState.elementBlur,
            uiColor: themeState.uiColor,
            bgImage: bgImage,
            customFont: font,
            customFontName: fontName,
            chatLayout: themeState.chatLayout,
            userBubbleColor: themeState.userBubbleColor,
            charBubbleColor: themeState.charBubbleColor,
            userQuoteColor: themeState.userQuoteColor,
            charQuoteColor: themeState.charQuoteColor,
            userTextColor: themeState.userTextColor,
            charTextColor: themeState.charTextColor,
            userItalicColor: themeState.userItalicColor,
            charItalicColor: themeState.charItalicColor,
            uiFontSize: themeState.uiFontSize,
            uiLetterSpacing: themeState.uiLetterSpacing,
            chatFontSize: themeState.chatFontSize,
            chatLetterSpacing: themeState.chatLetterSpacing,
            chatFont: chatFontData,
            chatFontName: chatFontNameData,
            borderWidth: themeState.borderWidth,
            borderColor: themeState.borderColor,
            borderOpacity: themeState.borderOpacity,
            noiseOpacity: themeState.noiseOpacity,
            noiseIntensity: themeState.noiseIntensity,
            bgNoiseOpacity: themeState.bgNoiseOpacity,
            bgNoiseIntensity: themeState.bgNoiseIntensity
        };
    }

    await db.set('gz_theme_presets', presets);
}

export async function initTheme() {
    let presets = (await db.get('gz_theme_presets')) || [];
    const hadPresets = presets.length > 0;

    if (!presets.find(p => p.id === 'default')) {
        presets.unshift(DEFAULT_PRESET);
        await db.set('gz_theme_presets', presets);
    }

    if (hadPresets) {
        let activeId = await db.get('gz_theme_active_preset');
        let activePreset = presets.find(p => p.id === activeId);
        if (!activePreset) {
            activePreset = presets[0];
            activeId = activePreset.id;
            await db.set('gz_theme_active_preset', activeId);
        }
        themeState.activePresetId = activeId;
        await applyPreset(activePreset);
        return;
    }

    // Load accent color (with migration from localStorage)
    let savedAccent = await db.get('gz_theme_accent');
    if (!savedAccent) {
        savedAccent = localStorage.getItem('gz_theme_accent');
        if (savedAccent) await db.set('gz_theme_accent', savedAccent);
    }
    if (savedAccent) {
        setAccentColor(savedAccent);
    }

    // Load the last custom color
    let savedLastCustom = await db.get('gz_theme_last_custom');
    if (savedLastCustom) {
        themeState.lastCustomColor = savedLastCustom;
    } else if (!PRESET_COLORS.some(c => c.toLowerCase() === themeState.accentColor.toLowerCase())) {
        // If the current color is custom, remember it as the last custom
        themeState.lastCustomColor = themeState.accentColor;
    }

    // Load opacity (with migration from localStorage)
    let savedOpacity = await db.get('gz_theme_opacity');
    if (savedOpacity === undefined || savedOpacity === null) {
        const local = localStorage.getItem('gz_theme_opacity');
        if (local) {
            savedOpacity = parseFloat(local);
            await db.set('gz_theme_opacity', savedOpacity);
        }
    }
    if (savedOpacity !== undefined) themeState.bgOpacity = parseFloat(savedOpacity);

    // Load blur (with migration from localStorage)
    let savedBlur = await db.get('gz_theme_blur');
    if (savedBlur === undefined || savedBlur === null) {
        const local = localStorage.getItem('gz_theme_blur');
        if (local) {
            savedBlur = parseInt(local);
            await db.set('gz_theme_blur', savedBlur);
        }
    }
    if (savedBlur !== undefined) themeState.bgBlur = parseInt(savedBlur);

    // Load element opacity
    let savedElemOpacity = await db.get('gz_theme_elem_opacity');
    if (savedElemOpacity === undefined || savedElemOpacity === null) {
        const local = localStorage.getItem('gz_theme_elem_opacity');
        if (local) {
            savedElemOpacity = parseFloat(local);
            await db.set('gz_theme_elem_opacity', savedElemOpacity);
        }
    }
    if (savedElemOpacity !== undefined) themeState.elementOpacity = parseFloat(savedElemOpacity);

    // Load element blur
    let savedElemBlur = await db.get('gz_theme_elem_blur');
    if (savedElemBlur === undefined || savedElemBlur === null) {
        const local = localStorage.getItem('gz_theme_elem_blur');
        if (local) {
            savedElemBlur = parseInt(local);
            await db.set('gz_theme_elem_blur', savedElemBlur);
        }
    }
    if (savedElemBlur !== undefined) themeState.elementBlur = parseInt(savedElemBlur);

    // Load UI color
    let savedUiColor = await db.get('gz_theme_ui_color');
    if (savedUiColor) {
        setUiColor(savedUiColor);
    }

    const savedThemeMode = localStorage.getItem('gz_theme');
    if (savedThemeMode) {
        themeState.themeMode = savedThemeMode;
    }

    const savedLayout = localStorage.getItem('gz_chat_layout');
    if (savedLayout) {
        themeState.chatLayout = savedLayout;
        localStorage.removeItem('gz_chat_layout');
    }

    const savedBg = await db.get('gz_theme_bg');
    if (savedBg) {
        applyBackgroundImage(savedBg);
    }

    // Load font
    const savedFont = await db.get('gz_theme_font');
    const savedFontName = await db.get('gz_theme_font_name');
    if (savedFont) {
        applyCustomFont(savedFont, savedFontName);
    }
    updateThemeStyles();

    // Create initial preset from current state
    const newPreset = {
        id: Date.now().toString(),
        name: 'My Theme',
        author: '',
        themeMode: themeState.themeMode,
        accentColor: themeState.accentColor,
        bgOpacity: themeState.bgOpacity,
        bgBlur: themeState.bgBlur,
        elementOpacity: themeState.elementOpacity,
        elementBlur: themeState.elementBlur,
        uiColor: themeState.uiColor,
        bgImage: themeState.hasBackgroundImage ? await db.get('gz_theme_bg') : null,
        customFont: themeState.customFontName ? await db.get('gz_theme_font') : null,
        customFontName: themeState.customFontName,
        chatLayout: themeState.chatLayout,
        userBubbleColor: themeState.userBubbleColor,
        charBubbleColor: themeState.charBubbleColor,
        userQuoteColor: themeState.userQuoteColor,
        charQuoteColor: themeState.charQuoteColor,
        userTextColor: themeState.userTextColor,
        charTextColor: themeState.charTextColor,
        userItalicColor: themeState.userItalicColor,
        charItalicColor: themeState.charItalicColor,
        uiFontSize: themeState.uiFontSize,
        uiLetterSpacing: themeState.uiLetterSpacing,
        chatFontSize: themeState.chatFontSize,
        chatLetterSpacing: themeState.chatLetterSpacing,
        chatFont: null,
        chatFontName: null,
        borderWidth: themeState.borderWidth,
        borderColor: themeState.borderColor,
        borderOpacity: themeState.borderOpacity,
        noiseOpacity: themeState.noiseOpacity,
        noiseIntensity: themeState.noiseIntensity,
        bgNoiseOpacity: themeState.bgNoiseOpacity,
        bgNoiseIntensity: themeState.bgNoiseIntensity
    };
    await db.set('gz_theme_presets', [newPreset]);
    await db.set('gz_theme_active_preset', newPreset.id);
    themeState.activePresetId = newPreset.id;
}

export function setAccentColor(color) {
    themeState.accentColor = color;
    db.set('gz_theme_accent', color).catch(e => console.error('Failed to save accent', e));
    document.documentElement.style.setProperty('--vk-blue', color);
    const rgb = hexToRgb(color);
    document.documentElement.style.setProperty('--vk-blue-rgb', rgb);

    // If the color is not a preset, save it as the last custom color
    if (!PRESET_COLORS.some(c => c.toLowerCase() === color.toLowerCase())) {
        themeState.lastCustomColor = color;
        db.set('gz_theme_last_custom', color).catch(e => console.error('Failed to save last custom', e));
    }
    scheduleSave();
}

export function setThemeModeState(mode) {
    themeState.themeMode = mode;
    scheduleSave();
}

export function setUiColor(color) {
    themeState.uiColor = color;
    if (color) {
        db.set('gz_theme_ui_color', color).catch(e => console.error('Failed to save ui color', e));
    } else {
        db.set('gz_theme_ui_color', null).catch(e => console.error('Failed to delete ui color', e));
    }
    updateThemeStyles();
    scheduleSave();
}

export function setBgOpacity(val) {
    themeState.bgOpacity = val;
    db.set('gz_theme_opacity', val).catch(e => console.error('Failed to save opacity', e));
    updateThemeStyles();
    scheduleSave();
}

export function setBgBlur(val) {
    themeState.bgBlur = val;
    db.set('gz_theme_blur', val).catch(e => console.error('Failed to save blur', e));
    updateThemeStyles();
    scheduleSave();
}

export function setElementOpacity(val) {
    themeState.elementOpacity = val;
    db.set('gz_theme_elem_opacity', val).catch(e => console.error('Failed to save elem opacity', e));
    localStorage.setItem('gz_theme_elem_opacity', val);
    updateThemeStyles();
    scheduleSave();
}

export function setElementBlur(val) {
    themeState.elementBlur = val;
    db.set('gz_theme_elem_blur', val).catch(e => console.error('Failed to save elem blur', e));
    localStorage.setItem('gz_theme_elem_blur', val);
    updateThemeStyles();
    scheduleSave();
}

export async function setBackgroundImage(file) {
    if (!file) {
        try {
            await db.set('gz_theme_bg', null);
        } catch (e) {
            console.error("Failed to delete background from db", e);
        }
        applyBackgroundImage(null);
        scheduleSave();
        return;
    }

    const reader = new FileReader();
    reader.onload = async (e) => {
        const result = e.target.result;
        try {
            await db.set('gz_theme_bg', result);
        } catch (e) {
            console.error("Failed to save background to db", e);
        }
        applyBackgroundImage(result);
        scheduleSave();
    };
    reader.readAsDataURL(file);
}

function applyBackgroundImage(dataUrl) {
    let bgEl = document.getElementById('app-background-layer');

    if (!bgEl) {
        bgEl = document.createElement('div');
        bgEl.id = 'app-background-layer';
        Object.assign(bgEl.style, {
            position: 'fixed', top: '-50px', left: '-50px', width: 'calc(100% + 100px)', height: 'calc(100% + 100px)',
            zIndex: '-1', backgroundSize: 'cover', backgroundPosition: 'center',
            pointerEvents: 'none',
            transition: 'filter 0.3s ease'
        });

        const noiseLayer = document.createElement('div');
        noiseLayer.className = 'bg-noise-overlay';
        Object.assign(noiseLayer.style, {
            position: 'absolute', top: 0, left: 0, width: '100%', height: '100%',
            pointerEvents: 'none',
            zIndex: 1
        });
        bgEl.appendChild(noiseLayer);

        const overlay = document.createElement('div');
        Object.assign(overlay.style, {
            position: 'absolute', top: 0, left: 0, width: '100%', height: '100%',
            backgroundColor: '#000',
            opacity: 'var(--theme-bg-opacity, 0)',
            transition: 'opacity 0.3s ease'
        });
        bgEl.appendChild(overlay);

        document.body.appendChild(bgEl);
    }

    if (dataUrl) {
        themeState.hasBackgroundImage = true;
        bgEl.style.backgroundImage = `url('${dataUrl}')`;
        document.body.classList.add('has-custom-background');
        updateThemeStyles();
    } else {
        themeState.hasBackgroundImage = false;
        bgEl.style.backgroundImage = '';
        document.body.classList.remove('has-custom-background');
        const styleEl = document.getElementById('theme-overrides');
        if (styleEl) styleEl.remove();
    }
}

export async function setCustomFont(file) {
    if (!file) {
        try {
            await db.set('gz_theme_font', null);
            await db.set('gz_theme_font_name', null);
        } catch (e) {
            console.error("Failed to delete font from db", e);
        }
        applyCustomFont(null, null);
        scheduleSave();
        return;
    }

    const reader = new FileReader();
    reader.onload = async (e) => {
        const result = e.target.result;
        try {
            await db.set('gz_theme_font', result);
            await db.set('gz_theme_font_name', file.name);
        } catch (e) {
            console.error("Failed to save font to db", e);
        }
        applyCustomFont(result, file.name);
        scheduleSave();
    };
    reader.readAsDataURL(file);
}

function applyCustomFont(dataUrl, name) {
    let styleEl = document.getElementById('theme-custom-font');
    if (dataUrl) {
        if (!styleEl) {
            styleEl = document.createElement('style');
            styleEl.id = 'theme-custom-font';
            document.head.appendChild(styleEl);
        }
        styleEl.textContent = `
            @font-face {
                font-family: 'GlazeCustomFont';
                src: url('${dataUrl}');
                font-display: swap;
            }
            body, button, input, textarea, select, .menu-text, .section-header, .item-title, .item-subtitle {
                font-family: 'GlazeCustomFont', 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif !important;
                font-weight: 450;
            }
        `;
        themeState.customFontName = name;
    } else {
        if (styleEl) styleEl.remove();
        themeState.customFontName = null;
    }
}

function applyChatFont(dataUrl, name) {
    let styleEl = document.getElementById('theme-chat-font');
    if (dataUrl) {
        if (!styleEl) {
            styleEl = document.createElement('style');
            styleEl.id = 'theme-chat-font';
            document.head.appendChild(styleEl);
        }
        styleEl.textContent = `
            @font-face {
                font-family: 'GlazeChatFont';
                src: url('${dataUrl}');
                font-display: swap;
            }
            .msg-body {
                font-family: 'GlazeChatFont', 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif !important;
                font-weight: 450;
            }
        `;
        themeState.chatFontName = name;
    } else {
        if (styleEl) styleEl.remove();
        themeState.chatFontName = null;
    }
}

export async function createPreset(name) {
    const presets = (await db.get('gz_theme_presets')) || [];

    // Create clean preset (defaults)
    const newPreset = {
        id: Date.now().toString(),
        name,
        author: '',
        themeMode: themeState.themeMode,
        accentColor: PRESET_COLORS[0],
        bgOpacity: 0.85,
        bgBlur: 0,
        elementOpacity: 0.8,
        elementBlur: 12,
        bgImage: null,
        uiColor: null,
        customFont: null,
        customFontName: null,
        chatLayout: themeState.chatLayout,
        userBubbleColor: null,
        charBubbleColor: null,
        userQuoteColor: null,
        charQuoteColor: null,
        userTextColor: null,
        charTextColor: null,
        userItalicColor: null,
        charItalicColor: null,
        uiFontSize: 15,
        uiLetterSpacing: 0,
        chatFontSize: 15,
        chatLetterSpacing: 0,
        chatFont: null,
        chatFontName: null,
        borderWidth: 1,
        borderColor: null,
        borderOpacity: 0.1,
        noiseOpacity: 0.03,
        noiseIntensity: 0.8,
        bgNoiseOpacity: 0.03,
        bgNoiseIntensity: 0.4
    };

    presets.push(newPreset);
    await db.set('gz_theme_presets', presets);
    await switchPreset(newPreset.id);
    return presets;
}

export async function getPresets() {
    return (await db.get('gz_theme_presets')) || [];
}

export async function deletePreset(id) {
    if (id === 'default') return (await db.get('gz_theme_presets'));
    let presets = (await db.get('gz_theme_presets')) || [];
    presets = presets.filter(p => p.id !== id);
    await db.set('gz_theme_presets', presets);

    if (themeState.activePresetId === id) {
        const next = presets[0];
        if (next) {
            await switchPreset(next.id);
        }
    }
    return presets;
}

export async function updatePresetMeta(id, name, author) {
    const presets = (await db.get('gz_theme_presets')) || [];
    const index = presets.findIndex(p => p.id === id);
    if (index !== -1) {
        if (name !== undefined) presets[index].name = name;
        if (author !== undefined) presets[index].author = author;
        await db.set('gz_theme_presets', presets);
        return presets;
    }
    return presets;
}

export async function switchPreset(id) {
    if (themeState.activePresetId && themeState.activePresetId !== id) {
        if (saveTimeout) {
            clearTimeout(saveTimeout);
            saveTimeout = null;
        }
        await saveStateToActivePreset();
    }

    const presets = (await db.get('gz_theme_presets')) || [];
    const preset = presets.find(p => p.id === id);
    if (preset) {
        themeState.activePresetId = id;
        await db.set('gz_theme_active_preset', id);
        await applyPreset(preset);
    }
}

export async function applyPreset(preset) {
    isApplyingPreset = true;
    try {
        if (preset.themeMode) {
            themeState.themeMode = preset.themeMode;
            localStorage.setItem('gz_theme', preset.themeMode);
            setThemeMode(preset.themeMode);
            if (preset.themeMode === 'dark') {
                document.body.classList.add('dark-theme');
            } else {
                document.body.classList.remove('dark-theme');
            }
        }
        setAccentColor(preset.accentColor);
        setBgOpacity(preset.bgOpacity);
        setBgBlur(preset.bgBlur);
        setElementOpacity(preset.elementOpacity !== undefined ? preset.elementOpacity : 0.8);
        setElementBlur(preset.elementBlur !== undefined ? preset.elementBlur : 12);
        setUiColor(preset.uiColor || null);
        setChatLayout(preset.chatLayout || 'default');
        setUserBubbleColor(preset.userBubbleColor || null);
        setCharBubbleColor(preset.charBubbleColor || null);
        setUserQuoteColor(preset.userQuoteColor || null);
        setCharQuoteColor(preset.charQuoteColor || null);
        setUserTextColor(preset.userTextColor || null);
        setCharTextColor(preset.charTextColor || null);
        setUserItalicColor(preset.userItalicColor || null);
        setCharItalicColor(preset.charItalicColor || null);
        setUiFontSize(preset.uiFontSize !== undefined ? preset.uiFontSize : 15);
        setUiLetterSpacing(preset.uiLetterSpacing !== undefined ? preset.uiLetterSpacing : 0);
        setChatFontSize(preset.chatFontSize !== undefined ? preset.chatFontSize : 15);
        setChatLetterSpacing(preset.chatLetterSpacing !== undefined ? preset.chatLetterSpacing : 0);
        setBorderWidth(preset.borderWidth !== undefined ? preset.borderWidth : 1);
        setBorderColor(preset.borderColor || null);
        setBorderOpacity(preset.borderOpacity !== undefined ? preset.borderOpacity : 0.1);
        setNoiseOpacity(preset.noiseOpacity !== undefined ? preset.noiseOpacity : 0.03);
        setNoiseIntensity(preset.noiseIntensity !== undefined ? preset.noiseIntensity : 0.8);
        setBgNoiseOpacity(preset.bgNoiseOpacity !== undefined ? preset.bgNoiseOpacity : 0.03);
        setBgNoiseIntensity(preset.bgNoiseIntensity !== undefined ? preset.bgNoiseIntensity : 0.4);

        if (preset.customFont) {
            try {
                await db.set('gz_theme_font', preset.customFont);
                await db.set('gz_theme_font_name', preset.customFontName);
            } catch (e) {
                console.error('Failed to save font preset', e);
            }
            applyCustomFont(preset.customFont, preset.customFontName);
        } else {
            try {
                await db.set('gz_theme_font', null);
                await db.set('gz_theme_font_name', null);
            } catch (e) {
                console.error('Failed to delete font preset', e);
            }
            applyCustomFont(null, null);
        }

        if (preset.bgImage) {
            try {
                await db.set('gz_theme_bg', preset.bgImage);
            } catch (e) {
                console.error('Failed to save bg preset', e);
            }
            applyBackgroundImage(preset.bgImage);
        } else {
            try {
                await db.set('gz_theme_bg', null);
            } catch (e) {
                console.error('Failed to delete bg preset', e);
            }
            applyBackgroundImage(null);
        }

        // Chat font
        if (preset.chatFont) {
            try {
                await db.set('gz_theme_chat_font', preset.chatFont);
                await db.set('gz_theme_chat_font_name', preset.chatFontName);
            } catch (e) {
                console.error('Failed to save chat font preset', e);
            }
            applyChatFont(preset.chatFont, preset.chatFontName);
        } else {
            try {
                await db.set('gz_theme_chat_font', null);
                await db.set('gz_theme_chat_font_name', null);
            } catch (e) {
                console.error('Failed to delete chat font preset', e);
            }
            applyChatFont(null, null);
        }
    } finally {
        isApplyingPreset = false;
    }
}

function updateThemeStyles() {
    document.documentElement.style.setProperty('--theme-bg-opacity', themeState.bgOpacity);
    document.documentElement.style.setProperty('--theme-bg-blur', themeState.bgBlur + 'px');
    document.documentElement.style.setProperty('--element-opacity', themeState.elementOpacity);
    document.documentElement.style.setProperty('--element-blur', themeState.elementBlur + 'px');

    const bgEl = document.getElementById('app-background-layer');
    if (bgEl) {
        bgEl.style.filter = `blur(${themeState.bgBlur}px)`;
    }

    // UI Color Overrides
    if (themeState.uiColor) {
        const rgb = hexToRgb(themeState.uiColor);
        document.documentElement.style.setProperty('--theme-ui-color-rgb', rgb);
    } else {
        document.documentElement.style.removeProperty('--theme-ui-color-rgb');
    }

    if (themeState.userBubbleColor) {
        document.documentElement.style.setProperty('--user-bubble-color', themeState.userBubbleColor);
        document.documentElement.style.setProperty('--user-bubble-color-rgb', hexToRgb(themeState.userBubbleColor));
    } else {
        document.documentElement.style.removeProperty('--user-bubble-color');
        document.documentElement.style.removeProperty('--user-bubble-color-rgb');
    }

    if (themeState.charBubbleColor) {
        document.documentElement.style.setProperty('--char-bubble-color', themeState.charBubbleColor);
        document.documentElement.style.setProperty('--char-bubble-color-rgb', hexToRgb(themeState.charBubbleColor));
    } else {
        document.documentElement.style.removeProperty('--char-bubble-color');
        document.documentElement.style.removeProperty('--char-bubble-color-rgb');
    }

    if (themeState.userQuoteColor) {
        document.documentElement.style.setProperty('--user-quote-color', themeState.userQuoteColor);
    } else {
        document.documentElement.style.removeProperty('--user-quote-color');
    }

    if (themeState.charQuoteColor) {
        document.documentElement.style.setProperty('--char-quote-color', themeState.charQuoteColor);
    } else {
        document.documentElement.style.removeProperty('--char-quote-color');
    }

    if (themeState.userTextColor) {
        document.documentElement.style.setProperty('--user-text-color', themeState.userTextColor);
    } else {
        document.documentElement.style.removeProperty('--user-text-color');
    }

    if (themeState.charTextColor) {
        document.documentElement.style.setProperty('--char-text-color', themeState.charTextColor);
    } else {
        document.documentElement.style.removeProperty('--char-text-color');
    }

    if (themeState.userItalicColor) {
        document.documentElement.style.setProperty('--user-italic-color', themeState.userItalicColor);
    } else {
        document.documentElement.style.removeProperty('--user-italic-color');
    }

    if (themeState.charItalicColor) {
        document.documentElement.style.setProperty('--char-italic-color', themeState.charItalicColor);
    } else {
        document.documentElement.style.removeProperty('--char-italic-color');
    }

    // Remove legacy style injection if exists
    const uiStyle = document.getElementById('theme-ui-overrides');
    if (uiStyle) uiStyle.remove();

    // Font size & letter spacing
    document.documentElement.style.setProperty('--ui-font-size', themeState.uiFontSize + 'px');
    document.documentElement.style.setProperty('--ui-letter-spacing', themeState.uiLetterSpacing + 'px');
    document.documentElement.style.setProperty('--chat-font-size', themeState.chatFontSize + 'px');
    document.documentElement.style.setProperty('--chat-letter-spacing', themeState.chatLetterSpacing + 'px');

    // Border
    document.documentElement.style.setProperty('--border-width', themeState.borderWidth + 'px');
    document.documentElement.style.setProperty('--border-opacity', themeState.borderOpacity);
    if (themeState.borderColor) {
        const brgb = hexToRgb(themeState.borderColor);
        document.documentElement.style.setProperty('--border-color', `rgba(${brgb}, ${themeState.borderOpacity})`);
    } else {
        // Use theme-aware default: white for dark, black for light
        const isDark = document.body.classList.contains('dark-theme');
        const defaultRgb = isDark ? '255, 255, 255' : '0, 0, 0';
        document.documentElement.style.setProperty('--border-color', `rgba(${defaultRgb}, ${themeState.borderOpacity})`);
    }

    // Noise texture (SVG data-URI can't use CSS vars, so inject via style tag)
    let noiseStyle = document.getElementById('theme-noise-style');
    if (!noiseStyle) {
        noiseStyle = document.createElement('style');
        noiseStyle.id = 'theme-noise-style';
        document.head.appendChild(noiseStyle);
    }
    const noiseOpacity = themeState.noiseOpacity;
    const noiseFreq = themeState.noiseIntensity;
    const noiseSvg = `url("data:image/svg+xml,%3Csvg width='200' height='200' viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noiseFilter'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='${noiseFreq}' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noiseFilter)' opacity='${noiseOpacity}'/%3E%3C/svg%3E")`;
    noiseStyle.textContent = `
        .menu-group,
        .preset-selector,
        .api-status {
            background-image: ${noiseSvg} !important;
        }

        .bg-noise-overlay {
            background-image: url("data:image/svg+xml,%3Csvg width='200' height='200' viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='bgNoiseFilter'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='${themeState.bgNoiseIntensity}' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23bgNoiseFilter)' opacity='${themeState.bgNoiseOpacity}'/%3E%3C/svg%3E") !important;
        }
    `;
}

export function setChatLayout(val) {
    themeState.chatLayout = val;
    scheduleSave();
}

export function setUserBubbleColor(val) {
    themeState.userBubbleColor = val;
    updateThemeStyles();
    scheduleSave();
}

export function setCharBubbleColor(val) {
    themeState.charBubbleColor = val;
    updateThemeStyles();
    scheduleSave();
}

export function setUserQuoteColor(val) {
    themeState.userQuoteColor = val;
    updateThemeStyles();
    scheduleSave();
}

export function setCharQuoteColor(val) {
    themeState.charQuoteColor = val;
    updateThemeStyles();
    scheduleSave();
}

export function setUserTextColor(val) {
    themeState.userTextColor = val;
    updateThemeStyles();
    scheduleSave();
}

export function setCharTextColor(val) {
    themeState.charTextColor = val;
    updateThemeStyles();
    scheduleSave();
}

export function setUserItalicColor(val) {
    themeState.userItalicColor = val;
    updateThemeStyles();
    scheduleSave();
}

export function setCharItalicColor(val) {
    themeState.charItalicColor = val;
    updateThemeStyles();
    scheduleSave();
}

export function setUiFontSize(val) {
    themeState.uiFontSize = val;
    updateThemeStyles();
    scheduleSave();
}

export function setUiLetterSpacing(val) {
    themeState.uiLetterSpacing = val;
    updateThemeStyles();
    scheduleSave();
}

export function setChatFontSize(val) {
    themeState.chatFontSize = val;
    updateThemeStyles();
    scheduleSave();
}

export function setChatLetterSpacing(val) {
    themeState.chatLetterSpacing = val;
    updateThemeStyles();
    scheduleSave();
}

export async function setChatFont(file) {
    if (!file) {
        try {
            await db.set('gz_theme_chat_font', null);
            await db.set('gz_theme_chat_font_name', null);
        } catch (e) {
            console.error('Failed to delete chat font from db', e);
        }
        applyChatFont(null, null);
        scheduleSave();
        return;
    }

    const reader = new FileReader();
    reader.onload = async (e) => {
        const result = e.target.result;
        try {
            await db.set('gz_theme_chat_font', result);
            await db.set('gz_theme_chat_font_name', file.name);
        } catch (e) {
            console.error('Failed to save chat font to db', e);
        }
        applyChatFont(result, file.name);
        scheduleSave();
    };
    reader.readAsDataURL(file);
}

export function setBorderWidth(val) {
    themeState.borderWidth = val;
    updateThemeStyles();
    scheduleSave();
}

export function setBorderColor(val) {
    themeState.borderColor = val;
    updateThemeStyles();
    scheduleSave();
}

export function setBorderOpacity(val) {
    themeState.borderOpacity = val;
    updateThemeStyles();
    scheduleSave();
}

export function setNoiseOpacity(val) {
    themeState.noiseOpacity = val;
    updateThemeStyles();
    scheduleSave();
}

export function setNoiseIntensity(val) {
    themeState.noiseIntensity = val;
    updateThemeStyles();
    scheduleSave();
}

export function setBgNoiseOpacity(val) {
    themeState.bgNoiseOpacity = val;
    updateThemeStyles();
    scheduleSave();
}

export function setBgNoiseIntensity(val) {
    themeState.bgNoiseIntensity = val;
    updateThemeStyles();
    scheduleSave();
}

export async function exportThemePreset(presetId) {
    const presets = (await db.get('gz_theme_presets')) || [];
    const preset = presets.find(p => p.id === presetId);
    if (!preset) return null;

    const exportData = {
        _type: 'silly_cradle_theme',
        name: preset.name,
        author: preset.author || '',
        themeMode: preset.themeMode,
        accentColor: preset.accentColor,
        bgOpacity: preset.bgOpacity,
        bgBlur: preset.bgBlur,
        elementOpacity: preset.elementOpacity,
        elementBlur: preset.elementBlur,
        uiColor: preset.uiColor,
        chatLayout: preset.chatLayout,
        userBubbleColor: preset.userBubbleColor,
        charBubbleColor: preset.charBubbleColor,
        userQuoteColor: preset.userQuoteColor,
        charQuoteColor: preset.charQuoteColor,
        userTextColor: preset.userTextColor,
        charTextColor: preset.charTextColor,
        userItalicColor: preset.userItalicColor,
        charItalicColor: preset.charItalicColor,
        uiFontSize: preset.uiFontSize,
        uiLetterSpacing: preset.uiLetterSpacing,
        chatFontSize: preset.chatFontSize,
        chatLetterSpacing: preset.chatLetterSpacing,
        borderWidth: preset.borderWidth,
        borderColor: preset.borderColor,
        borderOpacity: preset.borderOpacity,
        noiseOpacity: preset.noiseOpacity,
        noiseIntensity: preset.noiseIntensity,
        bgNoiseOpacity: preset.bgNoiseOpacity,
        bgNoiseIntensity: preset.bgNoiseIntensity,
        bgImage: preset.bgImage || null,
        customFont: preset.customFont || null,
        customFontName: preset.customFontName || null,
        chatFont: preset.chatFont || null,
        chatFontName: preset.chatFontName || null
    };

    return exportData;
}

export async function importThemePreset(jsonData, defaultName) {
    if (!jsonData || jsonData._type !== 'silly_cradle_theme') {
        throw new Error('Invalid theme file format');
    }

    const newPreset = {
        id: Date.now().toString(),
        name: jsonData.name || defaultName || 'Imported Theme',
        author: jsonData.author || '',
        themeMode: jsonData.themeMode || 'dark',
        accentColor: jsonData.accentColor || PRESET_COLORS[0],
        bgOpacity: jsonData.bgOpacity !== undefined ? jsonData.bgOpacity : 0.85,
        bgBlur: jsonData.bgBlur !== undefined ? jsonData.bgBlur : 0,
        elementOpacity: jsonData.elementOpacity !== undefined ? jsonData.elementOpacity : 0.8,
        elementBlur: jsonData.elementBlur !== undefined ? jsonData.elementBlur : 12,
        uiColor: jsonData.uiColor || null,
        bgImage: jsonData.bgImage || null,
        customFont: jsonData.customFont || null,
        customFontName: jsonData.customFontName || null,
        chatLayout: jsonData.chatLayout || 'default',
        userBubbleColor: jsonData.userBubbleColor || null,
        charBubbleColor: jsonData.charBubbleColor || null,
        userQuoteColor: jsonData.userQuoteColor || null,
        charQuoteColor: jsonData.charQuoteColor || null,
        userTextColor: jsonData.userTextColor || null,
        charTextColor: jsonData.charTextColor || null,
        userItalicColor: jsonData.userItalicColor || null,
        charItalicColor: jsonData.charItalicColor || null,
        uiFontSize: jsonData.uiFontSize !== undefined ? jsonData.uiFontSize : 15,
        uiLetterSpacing: jsonData.uiLetterSpacing !== undefined ? jsonData.uiLetterSpacing : 0,
        chatFontSize: jsonData.chatFontSize !== undefined ? jsonData.chatFontSize : 15,
        chatLetterSpacing: jsonData.chatLetterSpacing !== undefined ? jsonData.chatLetterSpacing : 0,
        chatFont: jsonData.chatFont || null,
        chatFontName: jsonData.chatFontName || null,
        borderWidth: jsonData.borderWidth !== undefined ? jsonData.borderWidth : 1,
        borderColor: jsonData.borderColor || null,
        borderOpacity: jsonData.borderOpacity !== undefined ? jsonData.borderOpacity : 0.1,
        noiseOpacity: jsonData.noiseOpacity !== undefined ? jsonData.noiseOpacity : 0.03,
        noiseIntensity: jsonData.noiseIntensity !== undefined ? jsonData.noiseIntensity : 0.8,
        bgNoiseOpacity: jsonData.bgNoiseOpacity !== undefined ? jsonData.bgNoiseOpacity : 0.03,
        bgNoiseIntensity: jsonData.bgNoiseIntensity !== undefined ? jsonData.bgNoiseIntensity : 0.4
    };

    const presets = (await db.get('gz_theme_presets')) || [];
    presets.push(newPreset);
    await db.set('gz_theme_presets', presets);
    await switchPreset(newPreset.id);

    return newPreset;
}

function hexToRgb(hex) {
    const result = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex);
    return result ? `${parseInt(result[1], 16)}, ${parseInt(result[2], 16)}, ${parseInt(result[3], 16)}` : '255, 255, 255';
}