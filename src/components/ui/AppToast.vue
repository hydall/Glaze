<script setup>
import { toastState } from '@/core/states/toastState.js';
</script>

<template>
    <Transition name="toast">
        <div v-if="toastState.visible" class="app-toast" @click="toastState.visible = false">
            <span>{{ toastState.text }}</span>
        </div>
    </Transition>
</template>

<style scoped>
.app-toast {
    position: fixed;
    bottom: calc(var(--footer-height, 80px) + 24px);
    left: 50%;
    transform: translateX(-50%);
    z-index: 10000;
    background: rgba(30, 30, 30, 0.92);
    color: #fff;
    padding: 10px 20px;
    border-radius: 24px;
    font-size: 13px;
    font-weight: 500;
    line-height: 1.3;
    max-width: calc(100% - 48px);
    text-align: center;
    pointer-events: auto;
    cursor: pointer;
    box-shadow: 0 4px 20px rgba(0, 0, 0, 0.25);
    backdrop-filter: blur(12px);
    -webkit-backdrop-filter: blur(12px);
    user-select: none;
    -webkit-user-select: none;
}



.toast-enter-active {
    transition: all 0.3s cubic-bezier(0.34, 1.56, 0.64, 1);
}
.toast-leave-active {
    transition: all 0.25s ease-in;
}
.toast-enter-from {
    opacity: 0;
    transform: translateX(-50%) translateY(20px) scale(0.85);
}
.toast-leave-to {
    opacity: 0;
    transform: translateX(-50%) translateY(10px) scale(0.95);
}
</style>
