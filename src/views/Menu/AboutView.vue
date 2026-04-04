<script setup>
import { ref, watch } from 'vue';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { Browser } from '@capacitor/browser';
import bmcLogo from '@/assets/logos/bmc-logo.svg';
import boostyLogo from '@/assets/logos/boosty.svg';

const visible = ref(false);
const version = `${__APP_VERSION__}\nCaramel Apple`;

const open = () => {
    visible.value = true;
};

const close = () => {
    visible.value = false;
};

const openLink = async (url) => {
    await Browser.open({ url });
};

// Hide/show the rest of the app with blur + opacity
watch(visible, (val) => {
    const appEl = document.getElementById('app');
    if (!appEl) return;
    if (val) {
        appEl.style.transition = 'opacity 0.4s ease, filter 0.4s ease';
        appEl.style.opacity = '0';
        // If we want a blur effect on the app itself while it fades:
        // appEl.style.filter = 'blur(10px)'; 
        appEl.style.pointerEvents = 'none';
        
        // Ensure body background is visible
        document.body.style.backgroundColor = 'transparent';
    } else {
        appEl.style.opacity = '1';
        appEl.style.filter = '';
        appEl.style.pointerEvents = '';
    }
});

const t = (key) => translations[currentLang.value]?.[key] || key;

defineExpose({ open });
</script>

<template>
    <Teleport to="body">
        <Transition name="about">
            <div v-if="visible" class="about-overlay">
                <!-- Content card -->
                <div class="menu-group about-card">
                    <!-- Close X inside the card -->
                    <div class="about-close-btn" @click="close">
                        <svg viewBox="0 0 24 24" fill="currentColor"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                    </div>

                    <!-- Logo & Brand -->
                    <div class="about-header">
                        <div class="about-logo-wrapper">
                            <svg class="about-logo" viewBox="0 0 600 600" fill="currentColor">
                                <g transform="translate(0.000000,600.000000) scale(0.100000,-0.100000)">
                                    <path d="M2799 4916 c-2 -2 -33 -7 -69 -10 -36 -3 -76 -8 -90 -11 -14 -2 -65 -12 -115 -21 -49 -9 -116 -25 -147 -35 -32 -11 -63 -19 -71 -19 -7 0 -31 -8 -53 -19 -21 -10 -55 -22 -74 -26 -38 -8 -146 -60 -285 -136 -43 -23 -118 -79 -123 -91 -2 -5 -10 -8 -18 -8 -8 0 -14 -4 -14 -10 0 -5 -6 -10 -13 -10 -8 0 -27 -13 -43 -30 -16 -16 -34 -30 -40 -30 -7 0 -30 -20 -52 -45 -23 -25 -45 -47 -49 -48 -12 -3 -133 -139 -133 -149 0 -5 -5 -6 -10 -3 -6 3 -10 1 -10 -6 0 -6 -36 -59 -80 -117 -44 -58 -80 -111 -80 -119 0 -7 -4 -13 -9 -13 -5 0 -12 -11 -15 -24 -3 -14 -12 -31 -19 -38 -6 -7 -17 -24 -24 -38 -6 -14 -30 -64 -52 -111 -23 -48 -41 -93 -41 -101 0 -8 -4 -18 -9 -23 -4 -6 -14 -32 -20 -60 -7 -27 -21 -72 -31 -100 -17 -43 -27 -94 -55 -255 -17 -100 -27 -293 -22 -435 6 -160 38 -417 56 -439 7 -9 17 -42 26 -86 11 -56 30 -120 41 -137 8 -12 14 -31 14 -41 0 -10 4 -22 8 -28 5 -5 17 -29 26 -54 36 -92 154 -293 216 -367 5 -7 10 -16 10 -22 0 -5 7 -11 15 -15 8 -3 15 -12 15 -20 0 -9 38 -54 85 -101 47 -47 85 -90 85 -96 0 -5 4 -9 9 -9 5 0 16 -6 23 -13 7 -6 38 -32 67 -57 30 -25 65 -54 77 -65 49 -43 92 -75 102 -75 5 0 15 -7 22 -15 7 -9 15 -13 18 -11 3 3 18 -4 34 -15 36 -26 190 -103 201 -101 4 1 7 -3 7 -8 0 -6 9 -10 19 -10 11 0 21 -4 23 -8 2 -6 140 -56 183 -67 6 -1 23 -7 38 -13 15 -7 51 -16 80 -21 29 -6 72 -14 97 -19 25 -6 68 -13 95 -16 28 -4 82 -11 120 -17 46 -7 343 -9 855 -7 725 3 787 4 815 20 17 10 37 18 46 18 20 0 95 36 119 58 11 9 32 28 47 42 15 14 31 24 35 23 5 -2 8 3 8 11 0 7 11 24 23 37 51 52 100 169 108 254 2 28 4 399 4 825 0 774 0 775 -23 858 -32 115 -48 143 -140 238 -63 65 -171 122 -272 143 -37 8 -1228 5 -1278 -3 -23 -4 -61 -14 -84 -22 -47 -16 -154 -86 -181 -118 -10 -11 -15 -15 -11 -7 5 9 3 12 -4 7 -7 -4 -12 -13 -12 -21 0 -7 -6 -20 -13 -27 -7 -7 -27 -37 -45 -66 -58 -94 -77 -226 -52 -362 10 -55 38 -144 40 -125 0 6 7 -3 15 -20 7 -16 27 -45 44 -64 17 -18 31 -37 31 -40 0 -4 15 -15 33 -26 17 -10 37 -23 42 -27 100 -81 181 -96 545 -97 266 -2 296 -3 308 -19 18 -24 13 -435 -6 -454 -9 -9 -112 -12 -460 -10 -246 1 -472 6 -502 11 -30 5 -58 7 -62 4 -5 -2 -8 -1 -8 4 0 4 -13 9 -30 10 -16 1 -51 11 -77 22 -26 10 -63 25 -82 32 -18 7 -49 23 -68 36 -19 13 -38 21 -43 18 -4 -3 -10 -2 -12 3 -1 4 -25 23 -53 42 -60 42 -181 163 -201 202 -8 15 -19 28 -23 28 -5 0 -12 13 -16 30 -4 16 -11 30 -16 30 -5 0 -9 6 -9 14 0 8 -3 16 -7 18 -13 5 -43 68 -43 88 0 10 -4 20 -9 22 -22 7 -70 238 -76 366 -9 172 11 297 68 432 5 14 12 36 14 49 2 13 11 30 19 38 7 8 14 23 14 34 0 11 5 17 10 14 6 -3 10 1 10 9 0 8 6 21 13 28 8 7 26 32 40 55 14 23 49 65 76 95 28 29 51 56 51 61 0 4 4 7 10 7 10 0 38 21 76 58 13 13 28 21 33 18 4 -3 16 3 26 14 10 11 24 20 32 20 7 0 13 5 13 11 0 6 7 9 15 6 8 -4 17 -2 20 3 4 6 15 10 26 10 10 0 19 4 19 8 0 8 81 37 165 58 74 20 230 24 910 27 704 2 775 4 823 20 94 32 208 99 218 130 3 9 12 17 20 17 8 0 14 4 14 8 0 5 8 17 18 28 36 42 70 110 88 177 26 100 8 307 -32 358 -6 8 -17 29 -25 47 -8 17 -17 32 -21 32 -5 0 -8 4 -8 9 0 11 -77 91 -88 91 -4 0 -19 11 -34 25 -15 14 -29 25 -30 26 -19 0 -48 14 -48 22 0 6 -3 8 -6 4 -3 -3 -27 4 -52 16 -47 22 -50 22 -842 25 -438 2 -798 1 -801 -2z" />
                                </g>
                            </svg>
                        </div>
                        <h2 class="app-name">Glaze</h2>
                        <p class="app-version">{{ version }}</p>
                    </div>

                    <!-- Telegram & Donate pill buttons -->
                    <div class="about-actions">
                        <!-- Discord button (EN) -->
                        <button v-if="currentLang === 'en'" class="action-btn discord" @click="openLink('https://discord.gg/jnGhd7p6Ht')">
                            <svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M20.317 4.37a19.791 19.791 0 0 0-4.885-1.515a.074.074 0 0 0-.079.037c-.21.375-.444.864-.608 1.25a18.27 18.27 0 0 0-5.487 0a12.64 12.64 0 0 0-.617-1.25a.077.077 0 0 0-.079-.037A19.736 19.736 0 0 0 3.677 4.37a.07.07 0 0 0-.032.027C.533 9.046-.32 13.58.099 18.057a.082.082 0 0 0 .031.057a19.9 19.9 0 0 0 5.993 3.03a.078.078 0 0 0 .084-.028a14.09 14.09 0 0 0 1.226-1.994a.076.076 0 0 0-.041-.106a13.107 13.107 0 0 1-1.872-.892a.077.077 0 0 1-.008-.128a10.2 10.2 0 0 0 .372-.292a.074.074 0 0 1 .077-.01c3.928 1.793 8.18 1.793 12.062 0a.074.074 0 0 1 .078.01c.12.098.246.198.373.292a.077.077 0 0 1-.006.127a12.299 12.299 0 0 1-1.873.892a.077.077 0 0 0-.041.107c.36.698.772 1.362 1.225 1.993a.076.076 0 0 0 .084.028a19.839 19.839 0 0 0 6.002-3.03a.077.077 0 0 0 .032-.054c.5-5.177-.838-9.674-3.549-13.66a.061.061 0 0 0-.031-.028zM8.02 15.33c-1.183 0-2.157-1.085-2.157-2.419c0-1.333.956-2.419 2.157-2.419c1.21 0 2.176 1.096 2.157 2.42c0 1.333-.956 2.418-2.157 2.418zm7.975 0c-1.183 0-2.157-1.085-2.157-2.419c0-1.333.955-2.419 2.157-2.419c1.21 0 2.176 1.096 2.157 2.42c0 1.333-.946 2.418-2.157 2.418z"/></svg>
                            <span>Discord</span>
                        </button>
                        <button v-else class="action-btn telegram" @click="openLink('https://t.me/glazeapp')">
                            <svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z"/></svg>
                            <span>Telegram</span>
                        </button>

                        <!-- GitHub button -->
                        <button class="action-btn github" @click="openLink('https://github.com/hydall/Glaze')">
                            <svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/></svg>
                            <span>{{ t('btn_github') }}</span>
                        </button>
                        
                        <!-- Boosty button (RU) -->
                        <button v-if="currentLang === 'ru'" class="action-btn boosty" @click="openLink('https://boosty.to/hydall')">
                            <img :src="boostyLogo" width="22" height="22" class="boosty-icon" />
                            <span>Boosty</span>
                        </button>

                        <!-- BuyMeACoffee button (non-RU) -->
                        <button v-else class="action-btn bmc" @click="openLink('https://buymeacoffee.com/hydall')">
                            <img :src="bmcLogo" width="22" height="22" />
                            <span>Buy Me a Coffee</span>
                        </button>
                    </div>
                </div>
            </div>
        </Transition>
    </Teleport>
</template>

<style scoped>
/* — Overlay: transparent, shows bg image — */
.about-overlay {
    position: fixed;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background: transparent;
    z-index: 30000;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--text-black, #000);
}

/* — Card — */
.about-card {
    width: calc(100% - 32px);
    max-width: 400px;
    text-align: center;
    padding: 0;
    overflow: hidden;
    position: relative;
    will-change: transform, opacity;
    transform: translateZ(0); /* Hardware acceleration to help preserve blur */
}

/* — Close X inside card — */
.about-close-btn {
    position: absolute;
    top: 14px;
    right: 14px;
    width: 36px;
    height: 36px;
    border-radius: 50%;
    background: rgba(0, 0, 0, 0.06);
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    z-index: 10;
    transition: all 0.2s ease;
    border: 1px solid rgba(0, 0, 0, 0.03);
}

body.dark-theme .about-close-btn {
    background: rgba(255, 255, 255, 0.1);
    border-color: rgba(255, 255, 255, 0.05);
}

.about-close-btn:active {
    transform: scale(0.9) translateZ(0);
    background-color: rgba(0, 0, 0, 0.1);
}

body.dark-theme .about-close-btn:active {
    background-color: rgba(255, 255, 255, 0.15);
}

.about-close-btn svg {
    width: 20px;
    height: 20px;
    fill: var(--text-light-gray, #99a2ad);
}

/* — Header — */
.about-header {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 8px;
    padding: 28px 20px 16px;
}

.about-logo-wrapper {
    width: 72px;
    height: 72px;
    border-radius: 22px;
    background: var(--white, #fff);
    display: flex;
    align-items: center;
    justify-content: center;
    box-shadow: 0 4px 15px rgba(0, 0, 0, 0.08);
    margin-bottom: 4px;
}

body.dark-theme .about-logo-wrapper {
    background: rgba(255, 255, 255, 0.05);
    box-shadow: none;
}

.about-logo {
    width: 48px;
    height: 48px;
    color: var(--vk-blue, #7996ce);
}

.app-name {
    font-size: 1.5rem;
    font-weight: 700;
    margin: 0;
    color: var(--text-dark-gray, #222);
}

.app-version {
    font-size: 0.82rem;
    color: var(--text-gray, #818c99);
    margin: 0;
    white-space: pre-line;
    line-height: 1.4;
}

/* — Telegram & Donate pill buttons — */
.about-actions {
    padding: 4px 16px 20px;
    display: flex;
    flex-direction: column;
    gap: 12px;
}

.action-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 10px;
    width: 100%;
    padding: 14px;
    border-radius: 16px;
    border: none;
    font-size: 1rem;
    font-weight: 600;
    cursor: pointer;
    transition: transform 0.15s ease;
    color: white;
    text-decoration: none;
    font-family: inherit;
}

.action-btn:active {
    transform: scale(0.96);
}

.action-btn svg,
.action-btn img {
    flex-shrink: 0;
}

.action-btn.discord {
    background: #5865F2;
}

.action-btn.telegram {
    background: #2AABEE;
}

.action-btn.boosty {
    background: #F15F2C;
}

.action-btn.boosty .boosty-icon {
    filter: brightness(0) invert(1);
}

.action-btn.github {
    background: #24292e;
}

.action-btn.bmc {
    background: #FFDD00;
    color: #0D0C22;
}

/* — Transition — */
.about-enter-active,
.about-leave-active {
    transition: opacity 0.3s ease;
}

.about-enter-active .about-card,
.about-leave-active .about-card {
    transition: transform 0.3s cubic-bezier(0.34, 1.56, 0.64, 1), opacity 0.3s ease;
}

.about-enter-from,
.about-leave-to {
    opacity: 0;
}

.about-enter-from .about-card {
    transform: scale(0.92) translateZ(0);
    opacity: 0;
}

.about-leave-to .about-card {
    transform: scale(0.92) translateZ(0);
    opacity: 0;
}
</style>