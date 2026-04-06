<script setup>
import { hideHelpTips } from '@/core/config/APPSettings.js';

const props = defineProps({ term: { type: String, required: true } });
function click() {
    window.dispatchEvent(new CustomEvent('open-glossary', { detail: { term: props.term } }));
}
</script>

<template>
    <button v-if="!hideHelpTips" class="help-tip" @click.stop="click" type="button" tabindex="-1">
        <svg viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 17h-2v-2h2v2zm2.07-7.75l-.9.92C13.45 12.9 13 13.5 13 15h-2v-.5c0-1.1.45-2.1 1.17-2.83l1.24-1.26c.37-.36.59-.86.59-1.41 0-1.1-.9-2-2-2s-2 .9-2 2H8c0-2.21 1.79-4 4-4s4 1.79 4 4c0 .88-.36 1.68-.93 2.25z"/></svg>
    </button>
</template>

<style scoped>
.help-tip {
    width: 20px;
    height: 20px;
    padding: 0;
    border: none;
    background: none;
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    opacity: 0.7;
    color: var(--text-gray);
    vertical-align: middle;
    border-radius: 50%;
    transition: opacity 0.15s;
    -webkit-tap-highlight-color: transparent;
}
.help-tip:active { opacity: 0.85; }
.help-tip svg { width: 16px; height: 16px; fill: currentColor; }
</style>
