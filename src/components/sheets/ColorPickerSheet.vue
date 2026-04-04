<script setup>
import { ref, watch } from 'vue';
import BottomSheet from '@/components/ui/BottomSheet.vue';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';

const props = defineProps({
    visible: Boolean,
    title: String,
    modelValue: String, // Active color (e.g. '#ff0000' or null)
    presetColors: {
        type: Array,
        default: () => []
    },
    allowAuto: {
        type: Boolean,
        default: false
    },
    autoText: {
        type: String,
        default: 'Auto'
    }
});

const emit = defineEmits(['update:visible', 'update:modelValue', 'select']);
const t = (key) => translations[currentLang.value]?.[key] || key;

const localValue = ref(props.modelValue);

watch(() => props.modelValue, (newVal) => {
    localValue.value = newVal;
});

const isCustomMode = ref(false);

const activeHex = ref('#ffffff');
const h = ref(0);
const s = ref(0);
const l = ref(100);

// Helper functions for HSL <-> HEX
function hexToHsl(H) {
    if (!H || !H.startsWith('#')) return [0, 0, 100];
    let r = 0, g = 0, b = 0;
    if (H.length === 4) {
        r = "0x" + H[1] + H[1]; g = "0x" + H[2] + H[2]; b = "0x" + H[3] + H[3];
    } else if (H.length === 7) {
        r = "0x" + H[1] + H[2]; g = "0x" + H[3] + H[4]; b = "0x" + H[5] + H[6];
    }
    r /= 255; g /= 255; b /= 255;
    let cmin = Math.min(r,g,b), cmax = Math.max(r,g,b), delta = cmax - cmin;
    
    let hVal = 0, sVal = 0, lVal = 0;
    if (delta === 0) hVal = 0;
    else if (cmax === r) hVal = ((g - b) / delta) % 6;
    else if (cmax === g) hVal = (b - r) / delta + 2;
    else hVal = (r - g) / delta + 4;
    hVal = Math.round(hVal * 60);
    if (hVal < 0) hVal += 360;
    
    lVal = (cmax + cmin) / 2;
    sVal = delta === 0 ? 0 : delta / (1 - Math.abs(2 * lVal - 1));
    sVal = +(sVal * 100).toFixed(1);
    lVal = +(lVal * 100).toFixed(1);
    return [hVal, sVal, lVal];
}

function hslToHex(hVal, sVal, lVal) {
    sVal /= 100; lVal /= 100;
    let c = (1 - Math.abs(2 * lVal - 1)) * sVal,
        x = c * (1 - Math.abs((hVal / 60) % 2 - 1)),
        m = lVal - c/2,
        r = 0, g = 0, b = 0;
    
    if (0 <= hVal && hVal < 60) { r = c; g = x; b = 0; }
    else if (60 <= hVal && hVal < 120) { r = x; g = c; b = 0; }
    else if (120 <= hVal && hVal < 180) { r = 0; g = c; b = x; }
    else if (180 <= hVal && hVal < 240) { r = 0; g = x; b = c; }
    else if (240 <= hVal && hVal < 300) { r = x; g = 0; b = c; }
    else if (300 <= hVal && hVal < 360) { r = c; g = 0; b = x; }
    r = Math.round((r + m) * 255).toString(16);
    g = Math.round((g + m) * 255).toString(16);
    b = Math.round((b + m) * 255).toString(16);
    
    if (r.length === 1) r = "0" + r;
    if (g.length === 1) g = "0" + g;
    if (b.length === 1) b = "0" + b;
    return "#" + r + g + b;
}

watch(() => props.visible, (newVal) => {
    if (newVal) {
        if (props.presetColors && props.presetColors.length > 0) {
            const color = props.modelValue?.toLowerCase();
            const isPreset = props.presetColors.some(p => p.toLowerCase() === color);
            // If it's a preset or "Auto" (null), keep it collapsed. 
            // If it's a custom hex not in presets, expand it.
            isCustomMode.value = !!(color && !isPreset);
        } else {
            isCustomMode.value = true;
        }
        
        let c = props.modelValue || '#7996ce';
        if (!c.startsWith('#')) {
            c = '#7996ce'; 
        }
        activeHex.value = c;
        const [hh, ss, ll] = hexToHsl(c);
        h.value = hh;
        s.value = ss;
        l.value = ll;
    } else {
        // Reset custom mode when closing to prevent flash on next open
        isCustomMode.value = false;
    }
});

function onHexChange() {
    if (activeHex.value.match(/^#[0-9a-fA-F]{6}$/)) {
        const [hh, ss, ll] = hexToHsl(activeHex.value);
        h.value = hh;
        s.value = ss;
        l.value = ll;
        localValue.value = activeHex.value;
        emit('update:modelValue', activeHex.value);
        emit('select', activeHex.value);
    }
}

function onHslChange() {
    activeHex.value = hslToHex(h.value, s.value, l.value);
    localValue.value = activeHex.value;
    emit('update:modelValue', activeHex.value);
    emit('select', activeHex.value);
}

function selectColor(color) {
    localValue.value = color;
    emit('update:modelValue', color);
    emit('select', color);
    isCustomMode.value = false;
}

function closeSheet() {
    emit('update:visible', false);
}
</script>

<template>
    <BottomSheet :visible="visible" :title="title" @close="closeSheet">
        <div style="padding: 0 16px 16px;">
            <!-- Presets Grid (Now including Custom Button) -->
            <div v-if="presetColors && presetColors.length > 0" class="color-grid" style="padding: 16px 0;">
                <div v-if="allowAuto" class="color-circle" :class="{ 'active': !localValue && !isCustomMode }" :style="{ backgroundColor: !localValue ? 'var(--vk-blue)' : 'var(--bg-gray)' }" @click="selectColor(null)">
                    <svg v-if="!localValue && !isCustomMode" viewBox="0 0 24 24" style="fill: white;"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>
                    <span v-else style="font-size: 10px; color: var(--text-gray); font-weight: 500;">{{ autoText }}</span>
                </div>
                
                <div v-for="color in presetColors" :key="color" class="color-circle" :class="{ 'active': !isCustomMode && localValue && localValue.toLowerCase() === color.toLowerCase() }" :style="{ backgroundColor: color }" @click="selectColor(color)">
                     <svg v-if="!isCustomMode && localValue && localValue.toLowerCase() === color.toLowerCase()" viewBox="0 0 24 24" style="fill: white;"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>
                </div>

                <!-- Custom Button inside the grid -->
                <div class="color-circle custom-btn" :class="{ 'active': isCustomMode }" :style="{ background: 'conic-gradient(red, yellow, lime, aqua, blue, magenta, red)' }" @click="isCustomMode = true">
                </div>
            </div>

            <!-- Custom Picker Section -->
            <transition name="expand">
                <div v-if="isCustomMode" class="custom-color-picker-wrapper">
                    <div class="custom-color-picker">
                        <div class="color-preview" :style="{ backgroundColor: activeHex }"></div>
                        
                        <div class="hex-input-row">
                            <span style="font-weight: 500; font-size: 14px;">HEX</span>
                            <input type="text" v-model="activeHex" @input="onHexChange" class="cp-hex-input" maxlength="7">
                        </div>
                        
                        <div class="sliders">
                            <div class="slider-group">
                                <label>{{ t('theme_hue') || 'Hue' }} {{ h }}°</label>
                                <input type="range" min="0" max="360" v-model.number="h" @input="onHslChange" class="cp-slider hue-slider">
                            </div>
                            <div class="slider-group">
                                <label>{{ t('theme_saturation') || 'Saturation' }} {{ s }}%</label>
                                <input type="range" min="0" max="100" v-model.number="s" @input="onHslChange" class="cp-slider sat-slider" :style="{ '--sat-color': activeHex }">
                            </div>
                            <div class="slider-group">
                                <label>{{ t('theme_lightness') || 'Lightness' }} {{ l }}%</label>
                                <input type="range" min="0" max="100" v-model.number="l" @input="onHslChange" class="cp-slider light-slider">
                            </div>
                        </div>
                    </div>
                </div>
            </transition>
        </div>
    </BottomSheet>
</template>

<style scoped>
.color-grid {
    display: flex;
    flex-wrap: wrap;
    gap: 16px;
    justify-content: center;
    padding: 4px;
}
.color-circle {
    width: 44px;
    height: 44px;
    border-radius: 50%;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: transform 0.2s, box-shadow 0.2s;
    box-shadow: 0 1.5px 4px rgba(0,0,0,0.15);
    box-sizing: border-box;
    flex-shrink: 0;
    border: none;
}
.color-circle.active {
    box-shadow: 0 0 0 2px var(--text-black), 0 1.5px 4px rgba(0,0,0,0.15);
}
.color-circle:active {
    transform: scale(0.9);
}
.color-circle svg {
    width: 24px;
    height: 24px;
    filter: drop-shadow(0 1px 2px rgba(0,0,0,0.5));
}

.custom-btn {
    position: relative;
    box-sizing: border-box;
}

.custom-color-picker-wrapper {
    overflow: hidden;
}

.custom-color-picker {
    display: flex;
    flex-direction: column;
    padding-top: 8px;
}
.color-preview {
    width: 100%;
    height: 60px;
    border-radius: 12px;
    border: 1px solid rgba(0,0,0,0.1);
    box-shadow: inset 0 2px 4px rgba(0,0,0,0.05);
    margin-bottom: 20px;
    transition: background-color 0.1s;
}
.hex-input-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 24px;
}
.cp-hex-input {
    width: 120px;
    padding: 8px 12px;
    border-radius: 8px;
    border: 1px solid var(--border-color, rgba(0,0,0,0.1));
    background: var(--bg-gray);
    color: var(--text-black);
    text-align: center;
    font-family: monospace;
    font-size: 16px;
    font-weight: bold;
}
.slider-group {
    margin-bottom: 16px;
}
.slider-group label {
    display: block;
    font-size: 13px;
    font-weight: 500;
    color: var(--text-gray);
    margin-bottom: 6px;
}
.cp-slider {
    width: 100%;
    -webkit-appearance: none;
    height: 12px;
    border-radius: 6px;
    outline: none;
    margin: 0;
    padding: 0;
}
.cp-slider::-webkit-slider-thumb {
    -webkit-appearance: none;
    appearance: none;
    width: 24px;
    height: 24px;
    border-radius: 50%;
    background: white;
    box-shadow: 0 2px 6px rgba(0,0,0,0.3);
    cursor: pointer;
    border: 1px solid rgba(0,0,0,0.1);
}
.hue-slider {
    background: linear-gradient(to right, #f00 0%, #ff0 17%, #0f0 33%, #0ff 50%, #00f 67%, #f0f 83%, #f00 100%);
}
.sat-slider {
    background: linear-gradient(to right, #808080, var(--sat-color, var(--vk-blue)));
}
.light-slider {
    background: linear-gradient(to right, black, #808080, white);
}

/* Transitions */
.expand-enter-active, .expand-leave-active {
    transition: all 0.3s ease;
    max-height: 500px;
}
.expand-enter-from, .expand-leave-to {
    max-height: 0;
    opacity: 0;
    transform: translateY(-10px);
}
</style>
