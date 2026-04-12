<script setup>
import { ref, onMounted, computed, watch } from 'vue';
import { themeState, setAccentColor, setUiColor, setBackgroundImage, setCustomFont, setBgOpacity, setBgBlur, setElementOpacity, setElementBlur, PRESET_COLORS, PRESET_UI_COLORS, createPreset, getPresets, deletePreset, switchPreset, setChatLayout, setUserBubbleColor, setCharBubbleColor, setUserQuoteColor, setCharQuoteColor, setUserTextColor, setCharTextColor, setUserItalicColor, setCharItalicColor, setUiFontSize, setUiLetterSpacing, setChatFontSize, setChatLetterSpacing, setChatFont, exportThemePreset, importThemePreset, updatePresetMeta, setBorderWidth, setBorderColor, setBorderOpacity, setNoiseOpacity, setNoiseIntensity, setBgNoiseOpacity, setBgNoiseIntensity, setUiTextColor, setUiTextGrayColor, setUiFontMode, setChatFontMode } from '@/core/states/themeState.js';
import { saveFile } from '@/core/services/fileSaver.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { updateAppColors } from '@/core/services/ui.js';
import ColorPickerSheet from '@/components/sheets/ColorPickerSheet.vue';

const colorPickerState = ref({
    visible: false,
    title: '',
    target: '',
    modelValue: '',
    presetColors: [],
    allowAuto: false,
    autoText: 'Auto'
});

const openColorPicker = (target, title, currentValue, presets = [], allowAuto = false, autoText = 'Auto') => {
    colorPickerState.value = { visible: true, title, target, modelValue: currentValue, presetColors: presets, allowAuto, autoText };
};

const openFontSizeSelector = (type) => {
    const isUI = type === 'ui';
    const currentValue = isUI ? themeState.uiFontSize : themeState.chatFontSize;
    const title = isUI ? t('theme_font_size') : t('theme_font_size');
    
    showBottomSheet({
        title: title || 'Font Size',
        items: [
            {
                label: t('theme_system_font_size') || 'System',
                icon: currentValue === 'system' ? '<svg viewBox="0 0 24 24" style="fill:currentColor"><path d="M9 16.2L4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4L9 16.2z"/></svg>' : null,
                onClick: () => {
                    if (isUI) setUiFontSize('system');
                    else setChatFontSize('system');
                    closeBottomSheet();
                }
            },
            {
                label: t('theme_custom_font_size') || 'Custom',
                icon: currentValue !== 'system' ? '<svg viewBox="0 0 24 24" style="fill:currentColor"><path d="M9 16.2L4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4L9 16.2z"/></svg>' : null,
                onClick: () => {
                    if (isUI && themeState.uiFontSize === 'system') setUiFontSize(15);
                    if (!isUI && themeState.chatFontSize === 'system') setChatFontSize(15);
                    closeBottomSheet();
                }
            }
        ]
    });
};

const onColorSelected = (color) => {
    switch(colorPickerState.value.target) {
        case 'accent': setAccentColor(color || PRESET_COLORS[0]); break;
        case 'ui': setUiColor(color); break;
        case 'userBubble': setUserBubbleColor(color); break;
        case 'charBubble': setCharBubbleColor(color); break;
        case 'userReply': setUserQuoteColor(color); break;
        case 'charReply': setCharQuoteColor(color); break;
        case 'userText': setUserTextColor(color); break;
        case 'charText': setCharTextColor(color); break;
        case 'userItalic': setUserItalicColor(color); break;
        case 'charItalic': setCharItalicColor(color); break;
        case 'borderColor': setBorderColor(color); break;
        case 'uiText': setUiTextColor(color); break;
        case 'uiTextGray': setUiTextGrayColor(color); break;
    }
};

const bgInput = ref(null);
const fontInput = ref(null);
const chatFontInput = ref(null);
const themeImportInput = ref(null);
const presets = ref([]);
const activeTab = ref('general');
const activeChatSubTab = ref('font');

const t = (key) => translations[currentLang.value]?.[key] || key;

const loadPresetsList = async () => {
    presets.value = await getPresets();
};

onMounted(() => {
    loadPresetsList();
});

const activePresetName = computed(() => {
    const p = presets.value.find(x => x.id === themeState.activePresetId);
    return p ? p.name : (t('theme_preset_unknown') || 'Unknown');
});

const activePresetAuthor = computed(() => {
    const p = presets.value.find(x => x.id === themeState.activePresetId);
    return p ? p.author : '';
});

watch(() => themeState.accentColor, (newVal) => {
    const index = presets.value.findIndex(p => p.id === themeState.activePresetId);
    if (index !== -1) {
        presets.value[index].accentColor = newVal;
    }
});
const getContrastColor = (hex) => {
    if (!hex) return 'white';
    hex = hex.replace('#', '');
    const r = parseInt(hex.substr(0, 2), 16);
    const g = parseInt(hex.substr(2, 2), 16);
    const b = parseInt(hex.substr(4, 2), 16);
    const yiq = ((r * 299) + (g * 587) + (b * 114)) / 1000;
    return (yiq >= 128) ? 'black' : 'white';
};

const getCustomColorStyle = (colorValue) => {
    return {
        background: colorValue || 'conic-gradient(red, yellow, lime, aqua, blue, magenta, red)',
        backgroundOrigin: 'border-box',
        backgroundClip: 'border-box'
    };
};

const handleSavePreset = () => {
    showBottomSheet({
        title: t('theme_save_preset'),
        input: {
            label: t('theme_preset_name_placeholder'),
            value: '',
            placeholder: t('theme_my_theme') || 'My Theme',
            confirmLabel: t('btn_save'),
            onConfirm: async (val) => {
                if (val) {
                    presets.value = await createPreset(val);
                    closeBottomSheet();
                }
            }
        }
    });
};

const handleDeletePreset = (id) => {
    showBottomSheet({
        title: t('theme_confirm_delete_preset'),
        items: [
            {
                label: t('btn_delete'),
                icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: async () => {
                    presets.value = await deletePreset(id);
                    closeBottomSheet();
                }
            },
            {
                label: t('btn_cancel'),
                icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                onClick: closeBottomSheet
            }
        ]
    });
};

const handleApplyPreset = async (preset) => {
    await switchPreset(preset.id);
    updateAppColors();
    await loadPresetsList();
};



const openPresetSelector = () => {
    const cardItems = presets.value.map(p => {
        const isActive = themeState.activePresetId === p.id;
        const sublabelParts = [];
        if (p.author) sublabelParts.push(`by ${p.author}`);
        if (isActive) sublabelParts.push(t('preset_active') || 'Active');

        const item = {
            label: p.name,
            sublabel: sublabelParts.join(' • ') || '',
            image: p.bgImage || null,
            icon: !p.bgImage ? '<svg viewBox="0 0 24 24" style="fill:currentColor;"><circle cx="12" cy="12" r="10" fill="' + (p.accentColor || '#7996ce') + '"/></svg>' : null,
            onClick: () => {
                handleApplyPreset(p);
                closeBottomSheet();
            }
        };

        if (p.id !== 'default') {
            item.actions = [
                {
                    icon: '<svg viewBox="0 0 24 24"><path d="M12 8c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm0 2c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm0 6c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z"/></svg>',
                    color: 'var(--text-gray)',
                    onClick: (e) => {
                        e.stopPropagation();
                        closeBottomSheet();
                        openThemePresetOptions(p);
                    }
                }
            ];
        }
        return item;
    });

    cardItems.push({
        label: t('btn_add') || 'Add / Import',
        sublabel: t('theme_create_import_desc') || 'Create or import a theme',
        icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
        onClick: () => {
            closeBottomSheet();
            openAddThemeSheet();
        }
    });

    showBottomSheet({
        title: t('theme_presets') || 'Presets',
        cardItems
    });
};

const openAddThemeSheet = () => {
    showBottomSheet({
        title: t('theme_presets') || 'Presets',
        items: [
            {
                label: t('action_create_new') || 'Create New',
                icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    handleSavePreset();
                }
            },
            {
                label: t('action_import') || 'Import from file',
                icon: '<svg viewBox="0 0 24 24"><path d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM14 13v4h-4v-4H7l5-5 5 5h-3z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    themeImportInput.value?.click();
                }
            }
        ]
    });
};

const openThemePresetOptions = (preset) => {
    const items = [];
    
    items.push({
        label: t('action_edit_name') || 'Change Name',
        icon: '<svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>',
        onClick: () => {
            closeBottomSheet();
            showBottomSheet({
                title: t('action_edit_name') || 'Change Name',
                input: {
                    placeholder: t('theme_preset_name_placeholder') || 'Enter name',
                    value: preset.name,
                    confirmLabel: t('btn_save') || 'Save',
                    onConfirm: async (val) => {
                        if (val) {
                            presets.value = await updatePresetMeta(preset.id, val, preset.author);
                            closeBottomSheet();
                        }
                    }
                }
            });
        }
    });

    items.push({
        label: t('change_author') || 'Change Author',
        icon: '<svg viewBox="0 0 24 24"><path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/></svg>',
        onClick: () => {
            closeBottomSheet();
            showBottomSheet({
                title: t('change_author') || 'Change Author',
                input: {
                    placeholder: t('placeholder_author_name') || 'Enter author',
                    value: preset.author || '',
                    confirmLabel: t('btn_save') || 'Save',
                    onConfirm: async (val) => {
                        presets.value = await updatePresetMeta(preset.id, preset.name, val);
                        closeBottomSheet();
                    }
                }
            });
        }
    });

    items.push({
        label: t('action_export') || 'Export',
        icon: '<svg viewBox="0 0 24 24"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></svg>',
        onClick: async () => {
            closeBottomSheet();
            await handleExportPreset(preset.id);
        }
    });

    items.push({
        label: t('btn_delete') || 'Delete',
        icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
        iconColor: '#ff4444',
        isDestructive: true,
        onClick: () => {
            closeBottomSheet();
            handleDeletePreset(preset.id);
        }
    });

    showBottomSheet({
        title: preset.name,
        items
    });
};

const handleExportPreset = async (presetId) => {
    try {
        const exportedData = await exportThemePreset(presetId);
        if (!exportedData) return;
        const fileName = (exportedData.name || 'Theme').replace(/[^a-z0-9а-яё]/gi, '_').toLowerCase();
        await saveFile(`${fileName}.json`, JSON.stringify(exportedData, null, 4), 'application/json', 'themes');
    } catch (e) {
        console.error('Export theme failed', e);
    }
};

const onThemeFileSelected = async (event) => {
    const file = event.target.files[0];
    if (!file) return;

    const reader = new FileReader();
    reader.onload = async (e) => {
        try {
            const json = JSON.parse(e.target.result);
            const newPreset = await importThemePreset(json, file.name.replace(/\.json$/i, ''));
            updateAppColors();
            await loadPresetsList();
        } catch (err) {
            console.error('Error importing theme:', err);
            alert(err.message || 'Invalid theme file');
        }
        event.target.value = '';
    };
    reader.readAsText(file);
};

const getPresetName = (id) => {
    if (!id) return t('theme_preset_none') || 'None';
    const p = presets.value.find(x => x.id === id);
    return p ? p.name : (t('theme_preset_unknown') || 'Unknown');
};



const onBackgroundImageSelected = (e) => {
    const file = e.target.files[0];
    if (!file) return;

    const reader = new FileReader();
    reader.onload = (re) => {
        const dataUrl = re.target.result;
        setBackgroundImage(file);
        
        // Update local presets list instantly for the dropdown/selector
        const index = presets.value.findIndex(p => p.id === themeState.activePresetId);
        if (index !== -1) {
            presets.value[index].bgImage = dataUrl;
        }
    };
    reader.readAsDataURL(file);
};

const handleResetBackground = async () => {
    await setBackgroundImage(null);
    if (bgInput.value) bgInput.value.value = '';
    
    // Update local presets list instantly for the dropdown/selector
    const index = presets.value.findIndex(p => p.id === themeState.activePresetId);
    if (index !== -1) {
        presets.value[index].bgImage = null;
    }
};

const handleResetFont = async () => {
    await setCustomFont(null);
    if (fontInput.value) fontInput.value.value = '';
};

const handleResetChatFont = async () => {
    await setChatFont(null);
    if (chatFontInput.value) chatFontInput.value.value = '';
};

const checkIcon = '<svg viewBox="0 0 24 24" style="fill:currentColor"><path d="M9 16.2L4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4L9 16.2z"/></svg>';

const uiFontModeLabel = computed(() => {
    switch (themeState.uiFontMode) {
        case 'system': return t('theme_font_system') || 'System';
        case 'custom': return themeState.customFontName || (t('theme_font_custom') || 'Custom');
        default: return 'Glaze (Inter)';
    }
});

const chatFontModeLabel = computed(() => {
    switch (themeState.chatFontMode) {
        case 'system': return t('theme_font_system') || 'System';
        case 'glaze': return 'Glaze (Inter)';
        case 'custom': return themeState.chatFontName || (t('theme_font_custom') || 'Custom');
        default: return t('theme_font_inherit_ui') || 'Same as UI';
    }
});

const openUiFontSelector = () => {
    showBottomSheet({
        title: t('theme_ui_font') || 'App Interface Font',
        items: [
            {
                label: t('theme_font_system') || 'System',
                icon: themeState.uiFontMode === 'system' ? checkIcon : null,
                onClick: () => { setUiFontMode('system'); closeBottomSheet(); }
            },
            {
                label: 'Glaze (Inter)',
                icon: themeState.uiFontMode === 'glaze' ? checkIcon : null,
                onClick: () => { setUiFontMode('glaze'); closeBottomSheet(); }
            },
            {
                label: t('theme_font_custom') || 'Custom...',
                icon: themeState.uiFontMode === 'custom' ? checkIcon : null,
                onClick: () => { closeBottomSheet(); fontInput.value.click(); }
            }
        ]
    });
};

const openChatFontSelector = () => {
    showBottomSheet({
        title: t('theme_chat_font') || 'Chat Messages Font',
        items: [
            {
                label: t('theme_font_inherit_ui') || 'Same as UI',
                icon: themeState.chatFontMode === 'ui' ? checkIcon : null,
                onClick: () => { setChatFontMode('ui'); closeBottomSheet(); }
            },
            {
                label: t('theme_font_system') || 'System',
                icon: themeState.chatFontMode === 'system' ? checkIcon : null,
                onClick: () => { setChatFontMode('system'); closeBottomSheet(); }
            },
            {
                label: 'Glaze (Inter)',
                icon: themeState.chatFontMode === 'glaze' ? checkIcon : null,
                onClick: () => { setChatFontMode('glaze'); closeBottomSheet(); }
            },
            {
                label: t('theme_font_custom') || 'Custom...',
                icon: themeState.chatFontMode === 'custom' ? checkIcon : null,
                onClick: () => { closeBottomSheet(); chatFontInput.value.click(); }
            }
        ]
    });
};

const viewStyle = computed(() => {
    if (!themeState.hasBackgroundImage) return {};
    
    return {
    };
});

// Preview Styles
const getContrastColorRGB = (hex) => {
    if (!hex) return '255, 255, 255';
    hex = hex.replace('#', '');
    const r = parseInt(hex.substr(0, 2), 16);
    const g = parseInt(hex.substr(2, 2), 16);
    const b = parseInt(hex.substr(4, 2), 16);
    return `${r}, ${g}, ${b}`;
};

const chatPreviewStyle = computed(() => ({
    '--chat-font-size': themeState.chatFontSize === 'system' ? '' : `${themeState.chatFontSize}px`,
    '--chat-letter-spacing': `${themeState.chatLetterSpacing}px`,
    '--user-bubble-color-rgb': getContrastColorRGB(themeState.userBubbleColor || themeState.accentColor),
    '--char-bubble-color-rgb': getContrastColorRGB(themeState.charBubbleColor || 'var(--bg-gray)'),
    '--user-reply-color': themeState.userQuoteColor || themeState.accentColor,
    '--char-reply-color': themeState.charQuoteColor || themeState.accentColor,
    fontFamily: themeState.chatFontMode === 'custom' && themeState.chatFontName ? 'GlazeChatFont' :
                themeState.chatFontMode === 'system' ? '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif' :
                themeState.chatFontMode === 'glaze' ? '"Inter", sans-serif' : 'inherit'
}));
</script>

<template>
    <div class="view active-view theme-settings-screen" :style="viewStyle">
        <!-- Persistent Presets Section -->
        <div class="menu-group">
            <div class="section-header">{{ t('theme_presets') }}</div>
            <div style="padding: 0 16px 16px;">
                 <div class="preset-selector" @click="openPresetSelector" style="display: flex; justify-content: space-between; padding: 12px; align-items: center;">
                    <div style="display: flex; flex-direction: column; gap: 2px; text-align: left;">
                        <span style="font-weight: 500;">{{ activePresetName }}</span>
                        <span v-if="activePresetAuthor" style="font-size: 11px; opacity: 0.7; font-weight: normal;">by {{ activePresetAuthor }}</span>
                    </div>
                    <svg viewBox="0 0 24 24" style="width: 20px; height: 20px; fill: currentColor;"><path d="M7 10l5 5 5-5z"/></svg>
                </div>
            </div>
            <input type="file" ref="themeImportInput" accept=".json" style="display: none;" @change="onThemeFileSelected">
        </div>

        <!-- Tab Switcher -->
        <div class="tabs-container">
            <div class="tab" :class="{ active: activeTab === 'general' }" @click="activeTab = 'general'">
                {{ t('tab_general') || 'General' }}
            </div>
            <div class="tab" :class="{ active: activeTab === 'chat' }" @click="activeTab = 'chat'">
                {{ t('tab_chat') || 'Chat' }}
            </div>
        </div>

        <div v-if="activeTab === 'general'">


            <div v-if="themeState.activePresetId !== 'default'">
                <div class="menu-group" style="display: block;">
                    <div class="section-header">{{ t('theme_accent_color') }}</div>
                    <div class="menu-item color-item" @click="openColorPicker('accent', t('theme_accent_color'), themeState.accentColor, PRESET_COLORS)">
                        <div class="menu-text" style="flex:1;">{{ t('theme_accent_color') }}</div>
                        <div class="color-pill" :style="{ backgroundColor: themeState.accentColor }"></div>
                    </div>
                </div>

                <div class="menu-group" style="display: block;">
                    <div class="section-header">{{ t('theme_ui_font') || 'App Interface Font' }}</div>
                    <div class="menu-item" @click="openUiFontSelector">
                        <svg class="menu-icon" viewBox="0 0 24 24"><path d="M9.93 13.5h4.14L12 7.98zM20 2H4c-1.1 0-2 .9-2 2v16c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-4.05 16.5l-1.14-3H9.17l-1.12 3H5.96l5.11-13h1.86l5.11 13h-2.09z"/></svg>
                        <div class="menu-text" style="flex:1;">{{ t('theme_font') || 'Font' }}</div>
                        <div style="font-size: 14px; opacity: 0.7;">{{ uiFontModeLabel }}</div>
                    </div>
                    <div v-if="themeState.uiFontMode === 'custom'" class="menu-item" @click="handleResetFont">
                        <svg class="menu-icon" viewBox="0 0 24 24" style="fill: #ff4444;"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>
                        <div class="menu-text" style="color: #ff4444;">{{ t('theme_reset_font') || 'Reset Font' }}</div>
                    </div>
                    <input type="file" ref="fontInput" accept=".ttf,.otf,.woff,.woff2" style="display: none;" @change="(e) => setCustomFont(e.target.files[0])">

                    <div class="menu-item color-item" @click="openColorPicker('uiText', t('theme_ui_text_color') || 'Text Color', themeState.uiTextColor, PRESET_UI_COLORS, true)">
                        <div class="menu-text" style="flex:1;">{{ t('theme_ui_text_color') || 'Text Color' }}</div>
                        <div class="color-pill" :style="{ backgroundColor: themeState.uiTextColor || 'var(--text-black)', border: !themeState.uiTextColor ? '1px solid var(--text-gray)' : 'none' }">
                            <span v-if="!themeState.uiTextColor" style="font-size: 10px; color: var(--text-gray); font-weight: 500;">Auto</span>
                        </div>
                    </div>
                    <div class="menu-item color-item" @click="openColorPicker('uiTextGray', t('theme_ui_text_gray_color') || 'Secondary Text Color', themeState.uiTextGrayColor, PRESET_UI_COLORS, true)">
                        <div class="menu-text" style="flex:1;">{{ t('theme_ui_text_gray_color') || 'Secondary Text Color' }}</div>
                        <div class="color-pill" :style="{ backgroundColor: themeState.uiTextGrayColor || 'var(--text-gray)', border: !themeState.uiTextGrayColor ? '1px solid var(--text-gray)' : 'none' }">
                            <span v-if="!themeState.uiTextGrayColor" style="font-size: 10px; color: var(--text-gray); font-weight: 500;">Auto</span>
                        </div>
                    </div>

                    <div style="height: 1px; background: rgba(128,128,128,0.1); margin: 0 16px;"></div>

                    <div class="menu-item" @click="openFontSizeSelector('ui')">
                        <svg class="menu-icon" viewBox="0 0 24 24"><path d="M2.5 4v3h5v12h3V7h5V4h-13zm19 5h-9v3h3v7h3v-7h3V9z"/></svg>
                        <div class="menu-text" style="flex:1;">{{ t('theme_font_size') || 'Font Size' }}</div>
                        <div style="font-size: 14px; opacity: 0.7;">
                            {{ themeState.uiFontSize === 'system' ? (t('theme_system_font_size') || 'System') : themeState.uiFontSize + 'px' }}
                        </div>
                    </div>
                    
                    <div v-if="themeState.uiFontSize !== 'system'" style="padding: 0 16px; margin-bottom: 20px;">
                        <input type="range" min="12" max="20" step="1" :value="themeState.uiFontSize" @input="(e) => setUiFontSize(parseInt(e.target.value))">
                    </div>

                    <div style="padding: 0 16px 16px 16px;">
                        <div>
                            <div style="display:flex; justify-content:space-between; margin-bottom:8px; font-size: 14px;">
                                <label>{{ t('theme_letter_spacing') || 'Letter Spacing' }}</label>
                                <span>{{ themeState.uiLetterSpacing }}px</span>
                            </div>
                            <input type="range" min="-1" max="3" step="0.5" :value="themeState.uiLetterSpacing" @input="(e) => setUiLetterSpacing(parseFloat(e.target.value))">
                        </div>
                    </div>
                </div>

                <div class="menu-group" style="display: block;">
                    <div class="section-header">{{ t('theme_ui_effects') }}</div>
                    <div class="menu-item color-item" @click="openColorPicker('ui', t('theme_ui_color') || 'UI Color', themeState.uiColor, PRESET_UI_COLORS, true)">
                        <div class="menu-text" style="flex:1;">{{ t('theme_ui_color') || 'UI Color' }}</div>
                        <div class="color-pill" :style="{ backgroundColor: themeState.uiColor || 'var(--bg-gray)', border: !themeState.uiColor ? '1px solid var(--text-gray)' : 'none' }">
                            <span v-if="!themeState.uiColor" style="font-size: 10px; color: var(--text-gray); font-weight: 500;">Accent</span>
                        </div>
                    </div>
                    <div style="height: 1px; background: rgba(128,128,128,0.1); margin: 8px 16px;"></div>
                    <div style="padding: 16px; padding-top: 8px;">
                        <div style="margin-bottom: 20px;">
                            <div style="display:flex; justify-content:space-between; margin-bottom:8px; font-size: 14px;">
                                <label>{{ t('theme_opacity') }}</label>
                                <span>{{ Math.round(themeState.elementOpacity * 100) }}%</span>
                            </div>
                            <input type="range" min="0.1" max="1" step="0.05" :value="themeState.elementOpacity" @input="(e) => setElementOpacity(parseFloat(e.target.value))">
                        </div>
                        <div>
                            <div style="display:flex; justify-content:space-between; margin-bottom:8px; font-size: 14px;">
                                <label>{{ t('theme_blur') }}</label>
                                <span>{{ themeState.elementBlur }}px</span>
                            </div>
                            <input type="range" min="0" max="40" step="1" :value="themeState.elementBlur" @input="(e) => setElementBlur(parseInt(e.target.value))">
                        </div>
                    </div>
                </div>

                <div class="menu-group" style="display: block;">
                    <div class="section-header">{{ t('theme_border') || 'Border' }}</div>
                    <div class="menu-item color-item" @click="openColorPicker('borderColor', t('theme_border_color') || 'Border Color', themeState.borderColor, PRESET_UI_COLORS, true, 'Auto')">
                        <div class="menu-text" style="flex:1;">{{ t('theme_border_color') || 'Border Color' }}</div>
                        <div class="color-pill" :style="{ backgroundColor: themeState.borderColor || 'var(--bg-gray)', border: !themeState.borderColor ? '1px solid var(--text-gray)' : 'none' }">
                            <span v-if="!themeState.borderColor" style="font-size: 10px; color: var(--text-gray); font-weight: 500;">Auto</span>
                        </div>
                    </div>
                    <div style="height: 1px; background: rgba(128,128,128,0.1); margin: 8px 16px;"></div>
                    <div style="padding: 16px; padding-top: 8px;">
                        <div style="margin-bottom: 20px;">
                            <div style="display:flex; justify-content:space-between; margin-bottom:8px; font-size: 14px;">
                                <label>{{ t('theme_border_width') || 'Border Width' }}</label>
                                <span>{{ themeState.borderWidth }}px</span>
                            </div>
                            <input type="range" min="0" max="5" step="0.5" :value="themeState.borderWidth" @input="(e) => setBorderWidth(parseFloat(e.target.value))">
                        </div>
                        <div>
                            <div style="display:flex; justify-content:space-between; margin-bottom:8px; font-size: 14px;">
                                <label>{{ t('theme_border_opacity') || 'Border Opacity' }}</label>
                                <span>{{ Math.round(themeState.borderOpacity * 100) }}%</span>
                            </div>
                            <input type="range" min="0" max="1" step="0.05" :value="themeState.borderOpacity" @input="(e) => setBorderOpacity(parseFloat(e.target.value))">
                        </div>
                    </div>
                </div>

                <div class="menu-group" style="display: block;">
                    <div class="section-header">{{ t('theme_noise') || 'Noise Texture' }}</div>
                    <div style="padding: 16px;">
                        <div style="margin-bottom: 20px;">
                            <div style="display:flex; justify-content:space-between; margin-bottom:8px; font-size: 14px;">
                                <label>{{ t('theme_noise_opacity') || 'Noise Opacity' }}</label>
                                <span>{{ Math.round(themeState.noiseOpacity * 100) }}%</span>
                            </div>
                            <input type="range" min="0" max="0.15" step="0.005" :value="themeState.noiseOpacity" @input="(e) => setNoiseOpacity(parseFloat(e.target.value))">
                        </div>
                        <div>
                            <div style="display:flex; justify-content:space-between; margin-bottom:8px; font-size: 14px;">
                                <label>{{ t('theme_noise_intensity') || 'Noise Intensity' }}</label>
                                <span>{{ themeState.noiseIntensity.toFixed(1) }}</span>
                            </div>
                            <input type="range" min="0.1" max="2" step="0.1" :value="themeState.noiseIntensity" @input="(e) => setNoiseIntensity(parseFloat(e.target.value))">
                        </div>
                    </div>
                </div>

                <div class="menu-group" style="display: block;">
                    <div class="section-header">{{ t('theme_background_image') }}</div>
                    <div class="menu-item" @click="bgInput.click()">
                        <svg class="menu-icon" viewBox="0 0 24 24"><path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z"/></svg>
                        <div class="menu-text">{{ t('theme_select_image') }}</div>
                    </div>
                    <div v-if="themeState.hasBackgroundImage" class="menu-item" @click="handleResetBackground">
                        <svg class="menu-icon" viewBox="0 0 24 24" style="fill: #ff4444;"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>
                        <div class="menu-text" style="color: #ff4444;">{{ t('theme_reset_background') }}</div>
                    </div>
                    <input type="file" ref="bgInput" accept="image/*" style="display: none;" @change="onBackgroundImageSelected">
                    <div v-if="themeState.hasBackgroundImage">
                        <div style="height: 1px; background: rgba(128,128,128,0.1); margin: 0 16px;"></div>
                        <div style="padding: 16px;">
                            <div style="margin-bottom: 20px;">
                                <div style="display:flex; justify-content:space-between; margin-bottom:8px; font-size: 14px;">
                                    <label>{{ t('theme_dimming') || 'Background Dimming' }}</label>
                                    <span>{{ Math.round(themeState.bgOpacity * 100) }}%</span>
                                </div>
                                <input type="range" min="0" max="1" step="0.05" :value="themeState.bgOpacity" @input="(e) => setBgOpacity(parseFloat(e.target.value))">
                            </div>
                            <div>
                                <div style="display:flex; justify-content:space-between; margin-bottom:8px; font-size: 14px;">
                                    <label>{{ t('theme_blur') }}</label>
                                    <span>{{ themeState.bgBlur }}px</span>
                                </div>
                                <input type="range" min="0" max="20" step="1" :value="themeState.bgBlur" @input="(e) => setBgBlur(parseInt(e.target.value))">
                            </div>
                        </div>
                    </div>
                    <div style="height: 1px; background: rgba(128,128,128,0.1); margin: 0 16px;"></div>
                    <div style="padding: 16px;">
                        <div style="margin-bottom: 20px;">
                            <div style="display:flex; justify-content:space-between; margin-bottom:8px; font-size: 14px;">
                                <label>{{ t('theme_bg_noise_opacity') || 'Background Noise Opacity' }}</label>
                                <span>{{ Math.round(themeState.bgNoiseOpacity * 100) }}%</span>
                            </div>
                            <input type="range" min="0" max="0.2" step="0.005" :value="themeState.bgNoiseOpacity" @input="(e) => setBgNoiseOpacity(parseFloat(e.target.value))">
                        </div>
                        <div>
                            <div style="display:flex; justify-content:space-between; margin-bottom:8px; font-size: 14px;">
                                <label>{{ t('theme_bg_noise_intensity') || 'Background Noise Intensity' }}</label>
                                <span>{{ themeState.bgNoiseIntensity.toFixed(1) }}</span>
                            </div>
                            <input type="range" min="0.1" max="2" step="0.1" :value="themeState.bgNoiseIntensity" @input="(e) => setBgNoiseIntensity(parseFloat(e.target.value))">
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <div v-if="activeTab === 'chat'">
            <!-- Live Preview -->
            <div class="menu-group preview-group">
                <div class="section-header">{{ t('theme_preview_title') || 'Preview' }}</div>
                <div class="chat-preview-container" :style="chatPreviewStyle">
                    <!-- User Message -->
                    <div class="message-section user" :class="[`layout-${themeState.chatLayout}`]">
                        <div v-if="themeState.chatLayout !== 'bubble'" class="msg-header">
                            <div class="msg-avatar" style="background-color: var(--vk-blue)">U</div>
                            <span class="msg-name">{{ t('role_user') || 'User' }}</span>
                            <span class="msg-time">12:00</span>
                        </div>
                        <div class="msg-body">
                            <div v-html="t('theme_preview_msg1') || 'Hello! How does this look?<br><br><span class=\'chat-quote\'>This is a reply to test the reply colors!</span><br>And here are some <span class=\'chat-italic\'>italic thoughts</span>.'"></div>
                            <div v-if="themeState.chatLayout === 'bubble'" class="bubble-meta">
                                <span class="msg-index">#1</span>
                                <span class="bubble-time">12:00</span>
                            </div>
                        </div>
                        <div class="msg-footer">
                            <div v-if="themeState.chatLayout !== 'bubble'" class="msg-meta">
                                <span class="msg-index">#1</span>
                            </div>
                            <div class="msg-regenerate">
                                <svg viewBox="0 0 24 24"><path d="M17.65 6.35C16.2 4.9 14.21 4 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08c-.82 2.33-3.04 4-5.65 4-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>
                                <span>{{ t('magic_regenerate') }}</span>
                            </div>
                            <div v-if="themeState.chatLayout !== 'bubble'" class="msg-actions-btn">
                                <svg viewBox="0 0 24 24"><path d="M3 18h18v-2H3v2zm0-5h18v-2H3v2zm0-7v2h18V6H3z"/></svg>
                            </div>
                        </div>
                    </div>

                    <!-- Character Message -->
                    <div class="message-section char" :class="[`layout-${themeState.chatLayout}`]">
                        <div v-if="themeState.chatLayout !== 'bubble'" class="msg-header">
                            <div class="msg-avatar" :style="{ backgroundColor: themeState.accentColor }">C</div>
                            <span class="msg-name">{{ t('level_character') || 'Character' }}</span>
                            <span class="msg-time">12:01</span>
                        </div>
                        <div class="msg-body">
                            <div v-html="t('theme_preview_msg2') || '<span class=\'chat-quote\'>Hello! How does this look?</span><br>It looks great! The styling is perfect.<br><span class=\'chat-italic\'>I\'m so glad it works!</span>'"></div>
                            <div v-if="themeState.chatLayout === 'bubble'" class="bubble-meta">
                                <span class="msg-index">#2</span>
                                <span class="bubble-time">12:01</span>
                            </div>
                        </div>
                        <div class="msg-footer">
                            <div v-if="themeState.chatLayout !== 'bubble'" class="msg-meta">
                                <span class="msg-index">#2</span>
                            </div>
                            <div class="msg-switcher">
                                <div class="msg-switcher-btn prev">
                                    <svg viewBox="0 0 24 24"><path d="M15.41 7.41L14 6l-6 6 6 6 1.41-1.41L10.83 12z"/></svg>
                                </div>
                                <div class="msg-switcher-count">
                                    <span>2/3</span>
                                </div>
                                <div class="msg-switcher-btn next">
                                    <svg viewBox="0 0 24 24"><path d="M10 6L8.59 7.41 13.17 12l-4.58 4.59L10 18l6-6z"/></svg>
                                </div>
                            </div>
                            <div v-if="themeState.chatLayout !== 'bubble'" class="msg-actions-btn">
                                <svg viewBox="0 0 24 24"><path d="M3 18h18v-2H3v2zm0-5h18v-2H3v2zm0-7v2h18V6H3z"/></svg>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <!-- Sub-Tab Switcher -->
            <div class="tabs-container sub-tabs">
                <div class="tab" :class="{ active: activeChatSubTab === 'font' }" @click="activeChatSubTab = 'font'">
                    {{ t('tab_font') || 'Font' }}
                </div>
                <div class="tab" :class="{ active: activeChatSubTab === 'colors' }" @click="activeChatSubTab = 'colors'">
                    {{ t('tab_colors') || 'Colors' }}
                </div>
            </div>

            <div v-if="activeChatSubTab === 'font'">
                <div v-if="themeState.activePresetId !== 'default'">
                    <div class="menu-group" style="display: block;">
                        <div class="section-header">{{ t('theme_chat_font') || 'Chat Messages Font' }}</div>
                        <div class="menu-item" @click="openChatFontSelector">
                            <svg class="menu-icon" viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-3 12H7v-2h10v2zm0-3H7V9h10v2zm0-3H7V6h10v2z"/></svg>
                            <div class="menu-text" style="flex:1;">{{ t('theme_font') || 'Font' }}</div>
                            <div style="font-size: 14px; opacity: 0.7;">{{ chatFontModeLabel }}</div>
                        </div>
                        <div v-if="themeState.chatFontMode === 'custom'" class="menu-item" @click="handleResetChatFont">
                            <svg class="menu-icon" viewBox="0 0 24 24" style="fill: #ff4444;"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>
                            <div class="menu-text" style="color: #ff4444;">{{ t('theme_reset_font') || 'Reset Font' }}</div>
                        </div>
                        <input type="file" ref="chatFontInput" accept=".ttf,.otf,.woff,.woff2" style="display: none;" @change="(e) => setChatFont(e.target.files[0])">

                        <div style="height: 1px; background: rgba(128,128,128,0.1); margin: 0 16px;"></div>

                        <div class="menu-item" @click="openFontSizeSelector('chat')">
                            <svg class="menu-icon" viewBox="0 0 24 24"><path d="M2.5 4v3h5v12h3V7h5V4h-13zm19 5h-9v3h3v7h3v-7h3V9z"/></svg>
                            <div class="menu-text" style="flex:1;">{{ t('theme_font_size') || 'Font Size' }}</div>
                            <div style="font-size: 14px; opacity: 0.7;">
                                {{ themeState.chatFontSize === 'system' ? (t('theme_system_font_size') || 'System') : themeState.chatFontSize + 'px' }}
                            </div>
                        </div>

                        <div v-if="themeState.chatFontSize !== 'system'" style="padding: 0 16px; margin-bottom: 20px;">
                            <input type="range" min="12" max="24" step="1" :value="themeState.chatFontSize" @input="(e) => setChatFontSize(parseInt(e.target.value))">
                        </div>

                        <div style="padding: 0 16px 16px 16px;">
                            <div style="margin-bottom: 20px;">
                                <div style="display:flex; justify-content:space-between; margin-bottom:8px; font-size: 14px;">
                                    <label>{{ t('theme_letter_spacing') || 'Letter Spacing' }}</label>
                                    <span>{{ themeState.chatLetterSpacing }}px</span>
                                </div>
                                <input type="range" min="-1" max="3" step="0.5" :value="themeState.chatLetterSpacing" @input="(e) => setChatLetterSpacing(parseFloat(e.target.value))">
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <div v-if="activeChatSubTab === 'colors'">
                <div v-if="themeState.activePresetId !== 'default'">
                    <div class="menu-group" style="display: block;">
                        <div class="section-header">{{ t('theme_bubble_colors') || 'Bubble Colors' }}</div>
                        <div v-if="themeState.chatLayout === 'bubble'">
                            <div class="menu-item color-item" @click="openColorPicker('userBubble', t('theme_user_bubble') || 'User Bubble Color', themeState.userBubbleColor, PRESET_COLORS, true)">
                                <div class="menu-text" style="flex:1;">{{ t('theme_user_bubble') || 'User Bubble Color' }}</div>
                                <div class="color-pill" :style="{ backgroundColor: themeState.userBubbleColor || themeState.accentColor }">
                                    <span v-if="!themeState.userBubbleColor" :style="{ color: getContrastColor(themeState.accentColor) }" style="font-size: 10px; font-weight: 600;">Accent</span>
                                </div>
                            </div>
                            <div class="menu-item color-item" @click="openColorPicker('charBubble', t('theme_char_bubble') || 'Character Bubble Color', themeState.charBubbleColor, PRESET_COLORS, true)">
                                <div class="menu-text" style="flex:1;">{{ t('theme_char_bubble') || 'Character Bubble Color' }}</div>
                                <div class="color-pill" :style="{ backgroundColor: themeState.charBubbleColor || 'var(--bg-gray)', border: !themeState.charBubbleColor ? '1px solid var(--text-gray)' : 'none' }">
                                    <span v-if="!themeState.charBubbleColor" style="font-size: 10px; color: var(--text-gray); font-weight: 500;">Accent</span>
                                </div>
                            </div>
                        </div>
                        <div v-else style="color: var(--text-gray); font-size: 14px; text-align: center; padding: 12px;">
                            Bubble colors are only available for "Bubbles" layout.
                        </div>
                    </div>

                    <div class="menu-group" style="display: block;">
                        <div class="section-header">{{ t('theme_reply_colors') || 'Reply Colors' }}</div>
                        <div class="menu-item color-item" @click="openColorPicker('userReply', t('theme_user_reply') || 'User Reply Color', themeState.userQuoteColor, PRESET_COLORS, true)">
                            <div class="menu-text" style="flex:1;">{{ t('theme_user_reply') || 'User Reply Color' }}</div>
                            <div class="color-pill" :style="{ backgroundColor: themeState.userQuoteColor || themeState.accentColor }">
                                <span v-if="!themeState.userQuoteColor" :style="{ color: getContrastColor(themeState.accentColor) }" style="font-size: 10px; font-weight: 600;">Accent</span>
                            </div>
                        </div>
                        <div class="menu-item color-item" @click="openColorPicker('charReply', t('theme_char_reply') || 'Character Reply Color', themeState.charQuoteColor, PRESET_COLORS, true)">
                            <div class="menu-text" style="flex:1;">{{ t('theme_char_reply') || 'Character Reply Color' }}</div>
                            <div class="color-pill" :style="{ backgroundColor: themeState.charQuoteColor || themeState.accentColor }">
                                <span v-if="!themeState.charQuoteColor" :style="{ color: getContrastColor(themeState.accentColor) }" style="font-size: 10px; font-weight: 600;">Accent</span>
                            </div>
                        </div>
                    </div>

                    <div class="menu-group" style="display: block;">
                        <div class="section-header">{{ t('theme_text_colors') || 'Text Colors' }}</div>
                        <div class="menu-item color-item" @click="openColorPicker('userText', t('theme_user_text') || 'User Text Color', themeState.userTextColor, PRESET_COLORS, true)">
                            <div class="menu-text" style="flex:1;">{{ t('theme_user_text') || 'User Text Color' }}</div>
                            <div class="color-pill" :style="{ backgroundColor: themeState.userTextColor || 'var(--text-black)', border: !themeState.userTextColor ? '1px solid var(--text-gray)' : 'none' }">
                                <span v-if="!themeState.userTextColor" style="font-size: 10px; color: var(--text-gray); font-weight: 500;">Accent</span>
                            </div>
                        </div>
                        <div class="menu-item color-item" @click="openColorPicker('charText', t('theme_char_text') || 'Character Text Color', themeState.charTextColor, PRESET_COLORS, true)">
                            <div class="menu-text" style="flex:1;">{{ t('theme_char_text') || 'Character Text Color' }}</div>
                            <div class="color-pill" :style="{ backgroundColor: themeState.charTextColor || 'var(--text-black)', border: !themeState.charTextColor ? '1px solid var(--text-gray)' : 'none' }">
                                <span v-if="!themeState.charTextColor" style="font-size: 10px; color: var(--text-gray); font-weight: 500;">Accent</span>
                            </div>
                        </div>
                    </div>

                    <div class="menu-group" style="display: block;">
                        <div class="section-header">{{ t('theme_italic_colors') || 'Italic (Thoughts) Colors' }}</div>
                        <div class="menu-item color-item" @click="openColorPicker('userItalic', t('theme_user_italic') || 'User Italic Color', themeState.userItalicColor, PRESET_COLORS, true)">
                            <div class="menu-text" style="flex:1;">{{ t('theme_user_italic') || 'User Italic Color' }}</div>
                            <div class="color-pill" :style="{ backgroundColor: themeState.userItalicColor || 'var(--text-gray)', border: !themeState.userItalicColor ? '1px solid var(--text-gray)' : 'none' }">
                                <span v-if="!themeState.userItalicColor" style="font-size: 10px; color: var(--text-gray); font-weight: 500;">Accent</span>
                            </div>
                        </div>
                        <div class="menu-item color-item" @click="openColorPicker('charItalic', t('theme_char_italic') || 'Character Italic Color', themeState.charItalicColor, PRESET_COLORS, true)">
                            <div class="menu-text" style="flex:1;">{{ t('theme_char_italic') || 'Character Italic Color' }}</div>
                            <div class="color-pill" :style="{ backgroundColor: themeState.charItalicColor || 'var(--text-gray)', border: !themeState.charItalicColor ? '1px solid var(--text-gray)' : 'none' }">
                                <span v-if="!themeState.charItalicColor" style="font-size: 10px; color: var(--text-gray); font-weight: 500;">Accent</span>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <!-- Custom Color Picker Sheet -->
        <ColorPickerSheet 
            :visible="colorPickerState.visible"
            @update:visible="colorPickerState.visible = $event"
            :title="colorPickerState.title"
            :model-value="colorPickerState.modelValue"
            :preset-colors="colorPickerState.presetColors"
            :allow-auto="colorPickerState.allowAuto"
            :auto-text="colorPickerState.autoText"
            @select="onColorSelected"
        />
    </div>
</template>

<style scoped>
.color-item {
    padding: 12px 16px;
    margin-bottom: 4px;
    min-height: 48px;
}

/* Tabs */
.tabs-container {
    display: flex;
    padding: 4px;
    margin: 8px 16px;
    background: rgba(128, 128, 128, 0.1);
    border-radius: 10px;
}

.tab {
    flex: 1;
    padding: 8px;
    text-align: center;
    font-size: 14px;
    font-weight: 500;
    color: var(--text-gray);
    cursor: pointer;
    border-radius: 8px;
    transition: all 0.2s;
}

.tab.active {
    background: rgba(255,255,255,0.1);
    color: var(--text-black);
}

/* Sub-tabs */
.sub-tabs {
    margin: 8px 32px;
    background: rgba(128, 128, 128, 0.05);
}

.sub-tabs .tab {
    padding: 6px;
    font-size: 13px;
}

/* Preview */
.preview-group {
    background: transparent !important;
}

.chat-preview-container {
    padding: 12px 0;
    display: flex;
    flex-direction: column;
    gap: 4px;
    background: rgba(128, 128, 128, 0.05);
    border-radius: 16px;
    margin: 0 16px;
    overflow: hidden;
}

/* Base Message Section Styling (Classic) */
.message-section {
    padding: 12px 16px;
    display: flex;
    flex-direction: column;
    position: relative;
    --current-quote-color: var(--char-quote-color, var(--vk-blue));
    --current-text-color: var(--char-text-color, var(--text-black));
    --current-italic-color: var(--char-italic-color, #888);
}

.message-section.user {
    --current-quote-color: var(--user-quote-color, var(--vk-blue));
    --current-text-color: var(--user-text-color, var(--text-black));
    --current-italic-color: var(--user-italic-color, #888);
}

.msg-header {
    display: flex;
    align-items: center;
    margin-bottom: 6px;
}

.msg-avatar {
    width: 24px;
    height: 24px;
    border-radius: 50%;
    margin-right: 10px;
    display: flex;
    align-items: center;
    justify-content: center;
    color: white;
    font-weight: bold;
    font-size: 12px;
}

.msg-name {
    font-weight: 500;
    font-size: 14px;
    color: var(--text-dark-gray);
}

.msg-time {
    margin-left: auto;
    font-size: 12px;
    color: var(--text-gray);
}

.msg-body {
    font-size: var(--chat-font-size, 15px);
    letter-spacing: var(--chat-letter-spacing, 0px);
    line-height: 1.5;
    color: var(--current-text-color, var(--text-black));
    width: 100%;
}

:deep(.chat-quote) {
    color: var(--current-quote-color, var(--vk-blue)) !important;
}

:deep(.chat-italic) {
    color: var(--current-italic-color, #888);
    font-style: italic;
}

.msg-footer {
    display: grid;
    grid-template-columns: 1fr auto 1fr;
    align-items: center;
    min-height: 28px;
    margin-top: 4px;
}

.msg-meta {
    display: flex;
    align-items: center;
    gap: 6px;
}

.msg-index {
    font-size: 11px;
    color: var(--text-gray);
    display: flex;
    align-items: center;
}

.msg-switcher {
    display: flex;
    align-items: center;
    background-color: rgba(var(--ui-bg-rgb, 255, 255, 255), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 12px));
    -webkit-backdrop-filter: blur(var(--element-blur, 12px));
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.05));
    border-radius: 12px;
    padding: 2px 6px;
    font-size: 11px;
    color: var(--text-gray);
    gap: 4px;
    height: 22px;
}

.msg-switcher-btn {
    width: 20px;
    height: 20px;
    display: flex;
    align-items: center;
    justify-content: center;
}
.msg-switcher-btn svg { width: 16px; height: 16px; fill: currentColor; }

.msg-regenerate {
    display: flex;
    align-items: center;
    justify-content: center;
    background-color: rgba(var(--ui-bg-rgb, 255, 255, 255), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 12px));
    -webkit-backdrop-filter: blur(var(--element-blur, 12px));
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.05));
    border-radius: 12px;
    padding: 2px 8px;
    font-size: 11px;
    color: var(--text-gray);
    gap: 4px;
    height: 22px;
}
.msg-regenerate svg { width: 14px; height: 14px; fill: currentColor; }

.msg-actions-btn {
    justify-self: end;
    padding: 4px;
    color: var(--text-gray);
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    grid-column: 3;
    background-color: rgba(var(--ui-bg-rgb, 255, 255, 255), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 12px));
    -webkit-backdrop-filter: blur(var(--element-blur, 12px));
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.05));
    border-radius: 50%;
}
.msg-actions-btn svg { width: 20px; height: 20px; fill: currentColor; }

/* Reply Block Styling (Optional, keep if system messages use it, otherwise remove) */
.reply-block {
    display: none; /* User said it doesn't exist */
}

.message-section.layout-bubble {
    padding: 6px 16px;
}

.message-section.layout-bubble .msg-footer {
    display: flex;
    flex-wrap: wrap;
    justify-content: flex-start;
    margin-left: 0;
    gap: 8px;
}

.message-section.layout-bubble.user .msg-footer {
    justify-content: flex-end;
    margin-left: 0;
    margin-right: 0;
}

.message-section.layout-bubble .msg-body {
    background-color: rgba(var(--char-bubble-color-rgb, 82, 139, 204), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 12px));
    -webkit-backdrop-filter: blur(var(--element-blur, 12px));
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.05));
    border-radius: 18px;
    border-top-left-radius: 4px;
    padding: 10px 14px 6px 14px;
    width: fit-content;
    max-width: 88%;
}

.message-section.layout-bubble.user .msg-body {
    background-color: rgba(var(--user-bubble-color-rgb, 255, 255, 255), var(--element-opacity, 0.8));
    border-top-left-radius: 18px;
    border-top-right-radius: 4px;
    margin-left: auto;
}

.message-section.layout-bubble .bubble-meta {
    display: flex;
    justify-content: flex-start;
    align-items: center;
    gap: 8px;
    margin-top: 4px;
    font-size: 11px;
    color: var(--text-gray);
    opacity: 0.8;
}

.message-section.layout-bubble.user .bubble-meta {
    justify-content: flex-end;
}

.color-grid {
    display: flex;
    flex-wrap: wrap;
    gap: 16px;
    justify-content: center;
}
.color-pill {
    min-width: 48px;
    height: 24px;
    border-radius: 12px;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 0 8px;
    flex-shrink: 0;
    transition: background 0.2s;
    border: 1px solid rgba(128, 128, 128, 0.2);
    box-sizing: border-box;
}
.color-circle {
    width: 40px;
    height: 40px;
    border-radius: 50%;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: transform 0.2s;
    border: 2px solid transparent;
}
.color-circle.active {
    border-color: var(--text-black);
}
.color-circle svg {
    width: 24px;
    height: 24px;
    fill: white;
}
.custom-picker {
    position: relative;
    overflow: hidden;
    border-radius: 50%;
    -webkit-mask-image: -webkit-radial-gradient(white, black);
    mask-image: radial-gradient(white, black);
}
.custom-picker input {
    position: absolute;
    opacity: 0;
    width: 200%;
    height: 200%;
    top: 50%;
    left: 50%;
    transform: translate(-50%, -50%);
    cursor: pointer;
    padding: 0;
    margin: 0;
    border: none;
    -webkit-appearance: none;
    appearance: none;
}
.preset-color-preview {
    width: 24px;
    height: 24px;
    border-radius: 50%;
    margin-right: 12px;
    border: 1px solid rgba(0,0,0,0.1);
}
.preset-actions {
    display: flex;
    gap: 8px;
}
.preset-btn {
    padding: 8px;
    cursor: pointer;
    opacity: 0.6;
}
.preset-btn svg {
    width: 24px;
    height: 24px;
}
.preset-btn.delete svg {
    fill: #ff4444;
}
.active-preset {
    background-color: rgba(var(--vk-blue-rgb), 0.1);
    border-radius: 12px;
}
</style>