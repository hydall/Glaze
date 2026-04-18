<script setup>
import { ref, computed } from 'vue';
import BottomSheet from '@/components/ui/BottomSheet.vue';
import MagicDrawer from '@/components/chat/MagicDrawer.vue';
import { useSidebarResizer } from '@/composables/ui/useSidebarResizer.js';

const props = defineProps({
    bottomSheetState: Object,
    sidebarState: Object,
    activeChatCharObj: Object
});

const emit = defineEmits([
    'closeBottomSheet',
    'magic-notes',
    'magic-context',
    'magic-summary',
    'magic-sessions',
    'magic-stats',
    'magic-impersonate',
    'magic-char-card',
    'magic-api',
    'magic-presets',
    'magic-lorebooks',
    'magic-regex',
    'magic-image-gen',
    'magic-glossary'
]);

const { width: rightSidebarWidth, startResize: startRightResize } = useSidebarResizer('gz_right_sidebar_width', 300, 'right', 200, 800);

const hasSheet = computed(() => props.bottomSheetState.visible || props.sidebarState.isOccupied);
</script>

<template>
  <div class="desktop-sidebar-right" id="desktop-sidebar-container" :class="{ 'has-sheet': hasSheet }" :style="{ width: rightSidebarWidth + 'px', minWidth: rightSidebarWidth + 'px', maxWidth: rightSidebarWidth + 'px' }">
      <div class="sidebar-drag-handle right-handle" @mousedown="startRightResize"></div>
      
      <MagicDrawer
          :visible="true"
          :sidebar-mode="true"
          :icon-only="hasSheet"
          :class="{ 'left-icon-strip': hasSheet }"
          :active-char="activeChatCharObj"
          @magic-notes="emit('magic-notes')"
          @magic-context="emit('magic-context')"
          @magic-summary="emit('magic-summary')"
          @magic-sessions="emit('magic-sessions')"
          @magic-stats="emit('magic-stats')"
          @magic-impersonate="emit('magic-impersonate')"
          @magic-char-card="emit('magic-char-card')"
          @magic-api="emit('magic-api')"
          @magic-presets="emit('magic-presets')"
          @magic-lorebooks="emit('magic-lorebooks')"
          @magic-regex="emit('magic-regex')"
          @magic-image-gen="emit('magic-image-gen')"
          @magic-glossary="emit('magic-glossary')"
          @request-preview="() => {}"
          @close="() => {}"
      />

      <div id="desktop-sidebar-content" v-show="hasSheet">
          <BottomSheet
              v-if="bottomSheetState.visible"
              v-bind="bottomSheetState"
              :sidebar-mode="true"
              @close="emit('closeBottomSheet')"
          />
      </div>
  </div>
</template>
