<script setup>
import { ref, onMounted, onUnmounted } from 'vue';
import { currentLang } from '@/core/config/APPSettings.js';
import { translations } from '@/utils/i18n.js';

defineProps({
  currentView: String
});

defineEmits(['update:currentView']);

const tabbarRef = ref(null);
let resizeObserver = null;

const t = (key) => translations[currentLang.value]?.[key] || key;

const updateTabBarHeight = () => {
  if (tabbarRef.value) {
    const height = tabbarRef.value.offsetHeight;
    document.documentElement.style.setProperty('--tab-bar-height', `${height}px`);
  }
};

onMounted(() => {
  updateTabBarHeight();
  // Safe-area insets may be applied with a delay on first load, force a refresh
  setTimeout(updateTabBarHeight, 200);

  if (tabbarRef.value) {
    resizeObserver = new ResizeObserver(updateTabBarHeight);
    resizeObserver.observe(tabbarRef.value, { box: 'border-box' });
  }
});

onUnmounted(() => {
  if (resizeObserver) {
    resizeObserver.disconnect();
  }
});
</script>

<template>
  <nav class="tabbar" ref="tabbarRef">
      <div class="tab-btn" :class="{ active: currentView === 'view-dialogs' }" @click="$emit('update:currentView', 'view-dialogs')">
          <svg class="tab-icon" viewBox="0 0 24 24">
              <path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z"/>
          </svg>
          <span class="tab-label">{{ t('tab_dialogs') }}</span>
      </div>
      
      <div class="tab-btn" :class="{ active: currentView === 'view-characters' }" @click="$emit('update:currentView', 'view-characters')">
          <svg class="tab-icon" viewBox="0 0 24 24">
              <path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/>
          </svg>
          <span class="tab-label">{{ t('tab_characters') }}</span>
      </div>


      <div class="tab-btn" :class="{ active: ['view-menu', 'view-settings', 'view-theme-settings', 'view-glossary'].includes(currentView) }" @click="$emit('update:currentView', 'view-menu')">
          <svg class="tab-icon" viewBox="0 0 24 24">
              <path d="M3 18h18v-2H3v2zm0-5h18v-2H3v2zm0-7v2h18V6H3z"/>
          </svg>
          <span class="tab-label">{{ t('tab_more') }}</span>
      </div>
  </nav>
</template>

<style>
/* Tabbar Layout & Glass Effect */
.tabbar {
    padding: 7px 0;
    display: flex;
    justify-content: space-around;
    position: relative;
    width: auto;
    margin: 0 16px 16px 16px;
    margin-bottom: calc(16px + var(--sab));
    border-radius: 20px;
    z-index: 100;
    overflow: hidden;
    flex-shrink: 0;
    transition: background-color 0.3s ease, border-top-color 0.3s ease;

    /* Glass Effect */
    background-color: rgba(30, 30, 30, var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 20px));
    -webkit-backdrop-filter: blur(var(--element-blur, 20px));
    background-image: url("data:image/svg+xml,%3Csvg width='200' height='200' viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noiseFilter'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.8' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noiseFilter)' opacity='0.03'/%3E%3C/svg%3E");
    border: 1px solid var(--border-color, rgba(255, 255, 255, 0.1));
}

.tab-btn {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    color: var(--inactive-tab);
    cursor: pointer;
    transition: color 0.3s ease;
}

.tab-btn.active {
    color: var(--vk-blue);
}

.tab-icon {
    width: 28px;
    height: 28px;
    fill: currentColor;
    margin-bottom: 2px;
    transition: fill 0.3s ease;
}

.tab-label {
    font-size: 10px;
    font-weight: 500;
}

/* Ripple Animation */
span.ripple {
    position: absolute;
    border-radius: 50%;
    transform: scale(0);
    animation: ripple 600ms linear;
    background-color: rgba(255, 255, 255, 0.1);
    pointer-events: none;
}

@keyframes ripple {
    to {
        transform: scale(4);
        opacity: 0;
    }
}
</style>