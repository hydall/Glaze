<template>
    <Transition name="fade" @after-leave="onAfterLeave">
        <div v-if="visible" class="holocards-overlay viewer-overlay visible" @click.self="close">
            <div class="holo-card-container" :class="{ 'is-resetting': isResetting }" id="holo-card" ref="cardContainer">
                <div class="holo-card-inner" @click="recalibrate">
                    <div class="holo-card-face holo-card-front">
                        <div class="holo-card" ref="card">
                            <div class="holo-card-bg-img" ref="bgImage" :style="{ backgroundImage: `url('${src}')` }"></div>
                            <div class="holo-card-pattern" ref="holoPattern"></div>
                            <div class="holo-card-sheen" ref="fullSheen"></div>
                            <div class="holo-card-border"></div>
                            <div class="holo-card-gradient"></div>
                            <div class="holo-card-info" ref="cardInfo">
                                <h2 class="holo-card-name">{{ name }}</h2>
                                <div class="holo-card-meta">
                                    <!-- <span class="holo-card-class">ULTRA RARE</span> -->
                                </div>
                            </div>
                        </div>
                        <div class="holo-overlay-layer" ref="overlayLayer">
                            <div class="holo-shard holo-shard-1"></div>
                            <div class="holo-shard holo-shard-2"></div>
                            <div class="holo-shard holo-shard-3"></div>
                            <div class="holo-shard holo-shard-4"></div>
                        </div>
                        <div class="holo-card-top-badge" ref="topBadge">
                            <span>G</span>
                        </div>
                        <div class="holo-glare" ref="glare"></div>
                        <div class="holo-casing"></div>
                    </div>
                </div>
            </div>
            <div id="holocards-close-btn" class="close-btn-trigger" @click="close" style="position: absolute; top: calc(20px + var(--sat)); right: 20px; z-index: 20020; width: 44px; height: 44px; cursor: pointer; background: rgba(0,0,0,0.5); border-radius: 50%; display: flex; align-items: center; justify-content: center;">
                <svg viewBox="0 0 24 24" style="width:24px;height:24px;fill:white;"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
            </div>
        </div>
    </Transition>
</template>

<script setup>
import { ref, onMounted, onUnmounted, nextTick, watch } from 'vue';
import { useViewer } from '@/composables/media/useViewer.js';

const { visible, src, name, description, close, onAfterLeave } = useViewer('open-holocards');

// Refs for DOM elements
const cardContainer = ref(null);
const card = ref(null);
const bgImage = ref(null);
const cardInfo = ref(null);
const topBadge = ref(null);
const fullSheen = ref(null);
const holoPattern = ref(null);
const overlayLayer = ref(null);
const glare = ref(null);

// Gyro State
let lastGamma = 0;
let lastBeta = 0;
let calGamma = 0;
let calBeta = 0;
let needsCalibration = true;
const isResetting = ref(false);
let resetTimeout = null;

const maxTilt = 10;

const updateCardTilt = (xNorm, yNorm) => {
    if (!cardContainer.value) return;
    
    const rotateY = xNorm * maxTilt * 2; 
    const rotateX = -yNorm * maxTilt * 2;

    cardContainer.value.style.transform = `rotateX(${rotateX}deg) rotateY(${rotateY}deg)`;

    const parallaxX = xNorm * 5;
    const parallaxY = yNorm * 5;
    if (bgImage.value) bgImage.value.style.transform = `scale(1.1) translateX(${parallaxX}px) translateY(${parallaxY}px)`;

    const textParallaxX = xNorm * 10;
    const textParallaxY = yNorm * 10;
    if (cardInfo.value) cardInfo.value.style.transform = `translateX(${textParallaxX}px) translateY(${textParallaxY}px)`;
    if (topBadge.value) topBadge.value.style.transform = `translateX(${textParallaxX}px) translateY(${textParallaxY}px)`;

    const sheenAngle = 115;
    const sheenPos = 50 + (xNorm * 40);
    const stop1 = sheenPos - 15;
    const stop2 = sheenPos;
    const stop3 = sheenPos + 15;

    const gradient = `linear-gradient(${sheenAngle}deg, transparent ${stop1}%, rgba(255,255,255,0.1) ${stop2}%, transparent ${stop3}%)`;
    const maskGradient = `linear-gradient(${sheenAngle}deg, transparent ${stop1}%, black ${stop2}%, transparent ${stop3}%)`;

    if (fullSheen.value) fullSheen.value.style.background = gradient;
    if (holoPattern.value) {
        holoPattern.value.style.webkitMaskImage = maskGradient;
        holoPattern.value.style.maskImage = maskGradient;
    }
    if (overlayLayer.value) {
        overlayLayer.value.style.webkitMaskImage = maskGradient;
        overlayLayer.value.style.maskImage = maskGradient;
    }
    
    if (glare.value) glare.value.style.opacity = Math.min(1, Math.abs(xNorm) + Math.abs(yNorm) * 0.5);
};

const resetTilt = () => {
    isResetting.value = true;
    if (resetTimeout) clearTimeout(resetTimeout);
    nextTick(() => {
        requestAnimationFrame(() => {
            updateCardTilt(0, 0);
            resetTimeout = setTimeout(() => {
                isResetting.value = false;
            }, 500);
        });
    });
};

const onMouseMove = (e) => {
    if (!visible.value) return;
    const xNorm = (e.clientX / window.innerWidth - 0.5) * 2;
    const yNorm = (e.clientY / window.innerHeight - 0.5) * 2;
    updateCardTilt(xNorm, yNorm);
};

const onDeviceOrientation = (e) => {
    if (!visible.value || e.gamma === null) return;
    
    if (isResetting.value) {
        calGamma = e.gamma;
        calBeta = e.beta;
        lastGamma = e.gamma;
        lastBeta = e.beta;
        return;
    }

    // Calibrate on the first event after opening
    if (needsCalibration) {
        calGamma = e.gamma;
        calBeta = e.beta;
        lastGamma = e.gamma;
        lastBeta = e.beta;
        needsCalibration = false;
    }

    lastGamma = e.gamma;
    lastBeta = e.beta;

    // Logic for "catching up" (drift) if tilted too far
    const limit = 30;
    const drift = 0.05; // Speed of calibration shift

    let rawX = lastGamma - calGamma;
    if (rawX > limit) calGamma += (rawX - limit) * drift;
    else if (rawX < -limit) calGamma += (rawX + limit) * drift;

    let rawY = lastBeta - calBeta;
    if (rawY > limit) calBeta += (rawY - limit) * drift;
    else if (rawY < -limit) calBeta += (rawY + limit) * drift;

    let tiltX = lastGamma - calGamma;
    let tiltY = lastBeta - calBeta;
    
    if (tiltX > limit) tiltX = limit; if (tiltX < -limit) tiltX = -limit;
    if (tiltY > limit) tiltY = limit; if (tiltY < -limit) tiltY = -limit;
    
    updateCardTilt(tiltX / limit, -tiltY / limit);
};

const recalibrate = (e) => {
    e.stopPropagation();
    resetTilt();
};

watch(visible, (newVal) => {
    if (newVal) {
        needsCalibration = true; // Request calibration on next sensor event
        nextTick(() => resetTilt());
    }
});

onMounted(() => {
    window.addEventListener('mousemove', onMouseMove);
    window.addEventListener('deviceorientation', onDeviceOrientation);
});

onUnmounted(() => {
    window.removeEventListener('mousemove', onMouseMove);
    window.removeEventListener('deviceorientation', onDeviceOrientation);
});
</script>

<style>
:root {
    --holo-card-width: 320px;
    --holo-card-height: 480px;
    --holo-purple: rgba(162, 127, 255, 0.85);
    --holo-cyan: rgba(100, 240, 255, 0.8);
    --holo-accent-green: #6feeb6;
}

.holocards-overlay {
    position: fixed;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background-color: rgba(0, 0, 0, 0.85);
    z-index: 20000;
    display: flex;
    align-items: center;
    justify-content: center;
    perspective: 1200px;
    overflow: hidden;
}

.holo-card-container {
    width: var(--holo-card-width);
    height: var(--holo-card-height);
    position: relative;
    transform-style: preserve-3d;
    transition: none;
    cursor: pointer;
    z-index: 1;
}

.holo-card-inner {
    width: 100%;
    height: 100%;
    position: relative;
    transition: transform 0.6s cubic-bezier(0.4, 0.2, 0.2, 1);
    transform-style: preserve-3d;
}

.holo-card-container.flipped .holo-card-inner {
    transform: rotateY(180deg);
}

.holo-card {
    width: 100%;
    height: 100%;
    background-color: #000;
    border-radius: 24px;
    position: relative;
    overflow: hidden;
    filter: drop-shadow(0 20px 40px rgba(0,0,0,0.6));
    transform: translateZ(0);
    -webkit-mask-image: -webkit-radial-gradient(white, black);
    mask-image: radial-gradient(white, black);
    backface-visibility: hidden;
}

.holo-card-bg-img {
    position: absolute;
    top: -10%; left: -10%; width: 120%; height: 120%;
    background-size: cover;
    background-position: center;
    z-index: 0;
}

.holo-card-pattern {
    position: absolute;
    top: 0; left: 0; width: 100%; height: 100%;
    background: 
        url("data:image/svg+xml,%3Csvg width='12' height='12' viewBox='0 0 12 12' xmlns='http://www.w3.org/2000/svg'%3E%3Cpath d='M6 0L12 12H0z' fill='%23ffffff' fill-opacity='0.2'/%3E%3C/svg%3E"),
        url("data:image/svg+xml,%3Csvg viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noiseFilter'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.8' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noiseFilter)' opacity='0.15'/%3E%3C/svg%3E"),
        linear-gradient(135deg, rgba(255,0,0,0.05) 0%, rgba(0,255,0,0.05) 50%, rgba(0,0,255,0.05) 100%);
    mix-blend-mode: color-dodge;
    opacity: 0.4;
    z-index: 2;
    pointer-events: none;
    -webkit-mask-repeat: no-repeat;
    mask-repeat: no-repeat;
    -webkit-mask-size: 100% 100%;
    mask-size: 100% 100%;
}

.holo-card-sheen {
    position: absolute;
    top: 0; left: 0; width: 100%; height: 100%;
    mix-blend-mode: hard-light;
    z-index: 3;
    pointer-events: none;
}

.holo-card-gradient {
    position: absolute;
    bottom: 0; left: 0; width: 100%; height: 180px;
    background: linear-gradient(to top, rgba(0,0,0,0.95) 0%, rgba(0,0,0,0.6) 50%, transparent 100%);
    z-index: 9;
    pointer-events: none;
}

.holo-card-info {
    position: absolute;
    bottom: 20px; 
    left: 20px;
    z-index: 110;
    display: flex;
    flex-direction: column;
    gap: 4px;
    transition: none;
}

.holo-card-name {
    font-size: 32px;
    font-weight: 900;
    text-transform: uppercase;
    letter-spacing: 2px;
    margin: 0;
    background: linear-gradient(135deg, #fff 0%, #e0e0e0 25%, #fff 50%, #e0e0e0 75%, #fff 100%), url("data:image/svg+xml,%3Csvg viewBox='0 0 512 512' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noiseFilter'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='1.5' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noiseFilter)' opacity='0.5'/%3E%3C/svg%3E");
    background-size: 200% 200%, 100px 100px;
    background-blend-mode: overlay;
    -webkit-background-clip: text;
    background-clip: text;
    color: transparent;
    -webkit-text-fill-color: transparent;
    filter: drop-shadow(0 2px 4px rgba(0,0,0,0.8));
}

.holo-card-border {
    position: absolute;
    top: 10px; left: 10px; right: 10px; bottom: 10px;
    border: 2px solid rgba(255,255,255,0.4);
    border-radius: 16px;
    z-index: 20;
    pointer-events: none;
}

.holo-card-meta {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-top: 2px;
}

.holo-card-top-badge {
    position: absolute;
    top: 20px;
    right: 20px;
    width: 36px;
    height: 36px;
    border-radius: 50%;
    background: rgba(0,0,0,0.6);
    border: 2px solid rgba(255,255,255,0.4);
    display: flex;
    align-items: center;
    justify-content: center;
    font-weight: 800;
    font-size: 14px;
    z-index: 55;
    box-shadow: 0 4px 8px rgba(0,0,0,0.4);
    backdrop-filter: blur(4px);
    transition: none;
}

.holo-card-top-badge span {
    background: linear-gradient(135deg, #fff, #ccc, #fff);
    -webkit-background-clip: text;
    background-clip: text;
    color: transparent;
    -webkit-text-fill-color: transparent;
    filter: drop-shadow(0 1px 2px rgba(0,0,0,0.8));
}

.holo-overlay-layer {
    position: absolute;
    top: 0; left: 0; width: 100%; height: 100%;
    pointer-events: none;
    z-index: 50;
    border-radius: 24px;
    overflow: hidden;
    -webkit-mask-repeat: no-repeat;
    mask-repeat: no-repeat;
    -webkit-mask-size: 100% 100%;
    mask-size: 100% 100%;
}

.holo-shard {
    position: absolute;
    background: linear-gradient(135deg, rgba(255,255,255,0.4), var(--holo-purple));
    mix-blend-mode: hard-light;
    opacity: 0.9;
    box-shadow: inset 0 0 10px rgba(255,255,255,0.5);
    backdrop-filter: brightness(1.1) contrast(1.1);
}

.holo-shard-1 {
    top: 0; left: 0; width: 100%; height: 100%;
    background: linear-gradient(120deg, transparent 30%, rgba(189, 147, 249, 0.6) 45%, rgba(139, 233, 253, 0.4) 60%);
    clip-path: polygon(0% 10%, 30% 0%, 45% 30%, 20% 60%, 0% 45%);
}
.holo-shard-2 {
    bottom: 0; right: 0; width: 100%; height: 100%;
    background: linear-gradient(to top left, rgba(255, 121, 198, 0.6), transparent 50%);
    clip-path: polygon(60% 100%, 100% 100%, 100% 60%, 80% 80%);
    mix-blend-mode: color-dodge;
}
.holo-shard-3 {
    bottom: 0; left: 0; width: 100%; height: 100%;
    background: linear-gradient(45deg, rgba(139, 233, 253, 0.6), transparent);
    clip-path: polygon(0% 60%, 20% 75%, 10% 100%, 0% 100%);
}
.holo-shard-4 {
    top: 0; right: 0; width: 100%; height: 100%;
    background: linear-gradient(to bottom left, #aeffd8 0%, transparent 40%);
    clip-path: polygon(80% 0%, 100% 0%, 100% 20%, 70% 30%);
    mix-blend-mode: overlay;
}

.holo-glare {
    position: absolute;
    top: 0; left: 0; width: 100%; height: 100%;
    border-radius: 16px;
    background: radial-gradient(circle at 50% 50%, rgba(255, 255, 255, 0.8) 0%, rgba(255, 255, 255, 0.2) 20%, transparent 60%);
    mix-blend-mode: overlay;
    opacity: 0;
    pointer-events: none;
    z-index: 60;
    transition: opacity 0.2s;
}

.holo-casing {
    position: absolute;
    top: -4px; left: -4px; right: -4px; bottom: -4px;
    border-radius: 28px;
    background: linear-gradient(135deg, rgba(255,255,255,0.15) 0%, transparent 40%, rgba(255,255,255,0.05) 100%);
    border: 1px solid rgba(255,255,255,0.2);
    box-shadow: 0 0 0 1px rgba(255,255,255,0.1), inset 0 0 20px rgba(255,255,255,0.1);
    pointer-events: none;
    z-index: 100;
}

.holo-card-face {
    position: absolute;
    width: 100%;
    height: 100%;
    -webkit-backface-visibility: hidden;
    backface-visibility: hidden;
    border-radius: 24px;
    top: 0; left: 0;
}

.holo-card-front { z-index: 2; }

.is-resetting,
.is-resetting .holo-card-bg-img,
.is-resetting .holo-card-info,
.is-resetting .holo-card-top-badge {
    transition: transform 0.5s ease-out !important;
}
.is-resetting .holo-glare {
    transition: opacity 0.5s ease-out !important;
}
</style>