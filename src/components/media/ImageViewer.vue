<script setup>
import { ref, computed, nextTick, watch } from 'vue';
import { useViewer } from '@/composables/media/useViewer.js';

const { visible, src: imgSrc, description, close, onAfterLeave } = useViewer('open-image-viewer');
const containerRef = ref(null);
const imgRef = ref(null);

const promptVisible = ref(true);
const promptText = computed(() => description.value || '');

// Zoom & Pan State
let scale = 1;
let pointX = 0;
let pointY = 0;
let startX = 0;
let startY = 0;
let isDragging = false;
let startDist = 0;
let startScale = 1;
let startPinchX = 0;
let startPinchY = 0;
let startPointX = 0;
let startPointY = 0;
let isInteracting = false;
let lastTap = 0;

const updateTransform = () => {
    if (imgRef.value) {
        imgRef.value.style.transform = `translate(${pointX}px, ${pointY}px) scale(${scale})`;
    }
};

const resetZoom = () => {
    scale = 1;
    pointX = 0;
    pointY = 0;
    if (imgRef.value) {
        imgRef.value.style.transition = 'transform 0.3s ease';
        updateTransform();
        setTimeout(() => { 
            if (imgRef.value) imgRef.value.style.transition = 'transform 0.1s ease-out'; 
        }, 300);
    }
};

const closeViewer = () => {
    close();
};

const handleCloseClick = (e) => {
    e.stopPropagation();
    closeViewer();
};

const handleOverlayClick = () => {
    if (isInteracting) { isInteracting = false; return; }
    if (scale > 1.1) return; // Don't close if zoomed in
    closeViewer();
};

// Touch Handlers
const onTouchStart = (e) => {
    if (e.touches.length === 2) {
        isDragging = false;
        startDist = Math.hypot(
            e.touches[0].clientX - e.touches[1].clientX,
            e.touches[0].clientY - e.touches[1].clientY
        );
        startScale = scale;
        startPointX = pointX;
        startPointY = pointY;

        if (containerRef.value) {
            const rect = containerRef.value.getBoundingClientRect();
            const cx = (e.touches[0].clientX + e.touches[1].clientX) / 2;
            const cy = (e.touches[0].clientY + e.touches[1].clientY) / 2;
            startPinchX = cx - rect.left - rect.width / 2;
            startPinchY = cy - rect.top - rect.height / 2;
        }
    } else if (e.touches.length === 1) {
        isDragging = true;
        startX = e.touches[0].clientX - pointX;
        startY = e.touches[0].clientY - pointY;
    }
};

const onTouchMove = (e) => {
    isInteracting = true;

    if (e.touches.length === 2) {
        const dist = Math.hypot(
            e.touches[0].clientX - e.touches[1].clientX,
            e.touches[0].clientY - e.touches[1].clientY
        );
        if (startDist > 0) {
            const newScale = Math.max(1, Math.min(startScale * (dist / startDist), 5));
            
            if (containerRef.value) {
                const rect = containerRef.value.getBoundingClientRect();
                const cx = (e.touches[0].clientX + e.touches[1].clientX) / 2;
                const cy = (e.touches[0].clientY + e.touches[1].clientY) / 2;
                const currentPinchX = cx - rect.left - rect.width / 2;
                const currentPinchY = cy - rect.top - rect.height / 2;

                const scaleRatio = newScale / startScale;
                pointX = currentPinchX - (startPinchX - startPointX) * scaleRatio;
                pointY = currentPinchY - (startPinchY - startPointY) * scaleRatio;
                scale = newScale;
                
                updateTransform();
            }
        }
    } else if (e.touches.length === 1 && isDragging && scale > 1) {
        pointX = e.touches[0].clientX - startX;
        pointY = e.touches[0].clientY - startY;
        updateTransform();
    }
};

const onTouchEnd = (e) => {
    isDragging = false;
    if (e.touches.length < 2) startDist = 0;
    if (e.touches.length === 1) {
        isDragging = true;
        startX = e.touches[0].clientX - pointX;
        startY = e.touches[0].clientY - pointY;
    }
    if (scale < 1) resetZoom();
};

const onContainerClick = (e) => {
    const cur = new Date().getTime();
    const tapLen = cur - lastTap;
    if (tapLen < 300 && tapLen > 0) {
        e.preventDefault();
        e.stopPropagation();
        if (scale > 1) resetZoom();
        else if (containerRef.value) {
            scale = 2.5;
            const rect = containerRef.value.getBoundingClientRect();
            const tapX = e.clientX - rect.left - rect.width / 2;
            const tapY = e.clientY - rect.top - rect.height / 2;
            pointX = -1.5 * tapX;
            pointY = -1.5 * tapY;

            if (imgRef.value) {
                imgRef.value.style.transition = 'transform 0.3s ease';
                updateTransform();
                setTimeout(() => { if(imgRef.value) imgRef.value.style.transition = 'transform 0.1s ease-out'; }, 300);
            }
        }
    } else if (promptText.value) {
        e.stopPropagation();
        promptVisible.value = !promptVisible.value;
    }
    lastTap = cur;
};

// Reset zoom when opening
watch(visible, (newVal) => {
    if (newVal) {
        nextTick(() => {
            resetZoom();
            promptVisible.value = true;
        });
    }
});
</script>

<template>
    <Teleport to="body">
        <Transition name="fade" @after-leave="onAfterLeave">
            <div v-if="visible" id="image-viewer-overlay" class="image-viewer-overlay viewer-overlay visible" @click="handleOverlayClick">
                <div 
                    ref="containerRef"
                    class="image-viewer-container"
                    @touchstart="onTouchStart"
                    @touchmove.prevent="onTouchMove"
                    @touchend="onTouchEnd"
                    @click="onContainerClick"
                >
                    <img ref="imgRef" class="image-viewer-img" :src="imgSrc" alt="Full view">
                </div>
                <Transition name="prompt-fade">
                    <div v-if="promptText && promptVisible" class="image-viewer-prompt" @click.stop>{{ promptText }}</div>
                </Transition>
                <div id="image-viewer-close-btn" class="close-btn-trigger" @click="handleCloseClick" style="position: absolute; top: calc(20px + var(--sat)); right: 20px; z-index: 20020; width: 44px; height: 44px; cursor: pointer; background: rgba(0,0,0,0.5); border-radius: 50%; display: flex; align-items: center; justify-content: center;">
                    <svg viewBox="0 0 24 24" style="width:24px;height:24px;fill:white;"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                </div>
            </div>
        </Transition>
    </Teleport>
</template>

<style scoped>
.image-viewer-prompt {
    position: absolute;
    bottom: calc(20px + var(--sab, 0px));
    left: 16px;
    right: 16px;
    background: rgba(0, 0, 0, 0.55);
    backdrop-filter: blur(8px);
    -webkit-backdrop-filter: blur(8px);
    border-radius: 12px;
    padding: 12px 14px;
    color: rgba(255, 255, 255, 0.9);
    font-size: 13px;
    line-height: 1.5;
    max-height: 30vh;
    overflow-y: auto;
    z-index: 20010;
    white-space: pre-wrap;
    word-break: break-word;
}
.prompt-fade-enter-active,
.prompt-fade-leave-active {
    transition: opacity 0.2s ease, transform 0.2s ease;
}
.prompt-fade-enter-from,
.prompt-fade-leave-to {
    opacity: 0;
    transform: translateY(8px);
}
</style>