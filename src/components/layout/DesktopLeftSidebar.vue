<script setup>
import { ref } from 'vue';
import DialogList from '@/views/DialogList.vue';
import { currentLang } from '@/core/config/APPSettings.js';
import { translations } from '@/utils/i18n.js';
import { useSidebarResizer } from '@/composables/ui/useSidebarResizer.js';
import { attachHoverGlow } from '@/core/services/ui.js';

const props = defineProps({
    currentView: String,
    activeCategories: Object,
    isDesktopFloating: Boolean,
    isGlossaryOpen: Boolean
});

const emit = defineEmits(['update:currentView', 'openChat']);

function handleGlossaryToggle() {
    window.dispatchEvent(new CustomEvent('toggle-glossary'));
}

const t = (key) => translations[currentLang.value]?.[key] || key;

const { width: leftSidebarWidth, startResize: startLeftResize } = useSidebarResizer('gz_left_sidebar_width', 280, 'left', 200, 600);

const vHoverGlow = {
    mounted: (el) => {
        attachHoverGlow(el);
    }
};
</script>

<template>
  <div class="desktop-sidebar-left" :style="{ width: leftSidebarWidth + 'px', minWidth: leftSidebarWidth + 'px', maxWidth: leftSidebarWidth + 'px' }">
      <div class="sidebar-drag-handle left-handle" @mousedown="startLeftResize"></div>
      
      <div class="desktop-chars-btn" :class="{ active: currentView === 'view-characters' }" v-hover-glow @click="emit('update:currentView', 'view-characters')">
          <svg viewBox="0 0 24 24"><path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/></svg>
          <span>{{ t('tab_characters') }}</span>
      </div>
      
      <div class="desktop-dialogs-wrapper">
          <DialogList
              :active-category="activeCategories['view-dialogs']"
              @open-chat="emit('openChat', $event)"
          />
      </div>
      
      <div class="desktop-sidebar-nav">
          <div class="desktop-more-btn" :class="{ active: isGlossaryOpen }" v-hover-glow @click="handleGlossaryToggle">
              <svg viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z"/></svg>
              <span>{{ t('menu_glossary') }}</span>
          </div>
          <div class="desktop-more-btn" :class="{ active: isDesktopFloating && currentView !== 'view-glossary' }" v-hover-glow @click="emit('update:currentView', 'view-menu')">
              <svg viewBox="0 0 24 24"><path d="M3 18h18v-2H3v2zm0-5h18v-2H3v2zm0-7v2h18V6H3z"/></svg>
              <span>{{ t('tab_more') }}</span>
          </div>
      </div>
  </div>
</template>
