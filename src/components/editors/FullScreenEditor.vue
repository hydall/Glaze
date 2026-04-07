<script setup>
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { isKeyboardOpen } from '@/core/services/keyboardHandler.js';
import { ref, watch } from 'vue';

defineProps({
    modelValue: {
        type: String,
        default: ''
    },
    visible: {
        type: Boolean,
        default: false
    }
});

const emit = defineEmits(['update:modelValue', 'save', 'close']);

const initialValue = ref('');

watch(() => props.visible, (newVal) => {
    if (newVal) {
        initialValue.value = props.modelValue;
    }
});

const handleClose = () => {
    if (props.modelValue !== initialValue.value) {
        const confirmMsg = translations[currentLang.value]?.confirm_discard_changes || 'Discard changes?';
        if (!confirm(confirmMsg)) {
            return;
        }
        emit('update:modelValue', initialValue.value);
        emit('save', initialValue.value);
    }
    emit('close');
};

const onInput = (e) => {
    emit('update:modelValue', e.target.value);
    emit('save', e.target.value);
};
</script>

<template>
  <div id="full-screen-editor" v-show="visible" :class="{ 'anim-fade-in': visible, 'keyboard-open': isKeyboardOpen }">
      <div class="fs-editor-body">
          <textarea id="fs-editor-textarea" :value="modelValue" @input="onInput"></textarea>
      </div>
      <div id="fs-editor-close" style="display: none" @click="handleClose"></div>
  </div>
</template>

<style scoped>
#full-screen-editor {
    position: fixed;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background-color: rgba(255, 255, 255, var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 12px));
    -webkit-backdrop-filter: blur(var(--element-blur, 12px));
    display: flex;
    flex-direction: column;
    z-index: 2000;
    overflow: hidden;
}

body.dark-theme #full-screen-editor {
    background-color: rgba(30, 30, 30, var(--element-opacity, 0.8));
}

.fs-editor-body {
    flex: 1;
    padding: 16px;
    display: flex;
    flex-direction: column;
    padding-top: calc(var(--header-height, 80px) + 10px);
    padding-bottom: calc(20px + var(--sab));
}

#full-screen-editor.keyboard-open .fs-editor-body {
    padding-bottom: calc(20px + var(--sab) + var(--keyboard-overlap, 0px));
}

#fs-editor-textarea {
    flex: 1;
    width: 100%;
    height: 100%;
    border: 1px solid rgba(0,0,0,0.05);
    background-color: rgba(255, 255, 255, var(--element-opacity, 0.8));
    background-image: url("data:image/svg+xml,%3Csvg viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noiseFilter'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.8' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noiseFilter)' opacity='0.05'/%3E%3C/svg%3E");
    border-radius: 20px;
    padding: 16px;
    color: var(--text-black);
    font-size: 16px;
    resize: none;
    outline: none;
    line-height: 1.5;
    box-sizing: border-box;
    overflow-y: auto;
    -webkit-overflow-scrolling: touch;
}

body.dark-theme #fs-editor-textarea {
    color: #e1e3e6;
    background-color: rgba(30, 30, 30, var(--element-opacity, 0.8));
}
</style>