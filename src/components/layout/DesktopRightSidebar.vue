<script setup>
import { ref, computed, watch, defineAsyncComponent } from 'vue';
import BottomSheet from '@/components/ui/BottomSheet.vue';
import MagicDrawer from '@/components/chat/MagicDrawer.vue';
import { useSidebarResizer } from '@/composables/ui/useSidebarResizer.js';
import { sidebarState } from '@/core/states/sidebarState.js';

const PresetView = defineAsyncComponent(() => import('@/views/PresetView.vue'));
const ApiView = defineAsyncComponent(() => import('@/views/ApiView.vue'));
const PersonasView = defineAsyncComponent(() => import('@/views/PersonasView.vue'));
const LorebookSheet = defineAsyncComponent(() => import('@/components/sheets/LorebookSheet.vue'));
const RegexSheet = defineAsyncComponent(() => import('@/components/sheets/RegexSheet.vue'));
const ToolsView = defineAsyncComponent(() => import('@/views/ToolsView.vue'));

const props = defineProps({
    bottomSheetState: Object,
    sidebarState: Object,
    activeChatCharObj: Object,
    currentView: { type: String, default: '' }
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
    'magic-memory-books',
    'magic-regex',
    'magic-image-gen',
    'magic-glossary'
]);

const { width: rightSidebarWidth, startResize: startRightResize } = useSidebarResizer('gz_right_sidebar_width', 300, 'right', 200, 800);

const isChat = computed(() => props.currentView === 'view-chat');
const hasSheet = computed(() => props.bottomSheetState.visible || props.sidebarState.isOccupied);

// Active tool tracking
const activeTool = ref(null);
const activeToolRef = ref(null);

const toolComponentMap = {
    'view-presets': PresetView,
    'view-api': ApiView,
    'view-personas': PersonasView,
    'view-lorebook': LorebookSheet,
    'view-regex': RegexSheet,
};

const activeToolComponent = computed(() =>
    activeTool.value ? toolComponentMap[activeTool.value] : null
);

// When the tool component mounts and ref becomes available, open it
watch(activeToolRef, (ref) => {
    if (ref && activeTool.value) {
        ref.open();
    }
});

let closeTimeout = null;

// When the sheet closes (back button inside tool), clear activeTool
watch(() => sidebarState.isOccupied, (occupied) => {
    if (closeTimeout) {
        clearTimeout(closeTimeout);
        closeTimeout = null;
    }
    if (!occupied) {
        closeTimeout = setTimeout(() => {
            activeTool.value = null;
        }, 300);
    }
});

// Clear activeTool when entering chat
watch(isChat, (val) => {
    if (val) activeTool.value = null;
});

function openTool(viewId) {
    if (!toolComponentMap[viewId]) return;
    if (activeTool.value === viewId) {
        // Toggle off
        if (activeToolRef.value && typeof activeToolRef.value.close === 'function') {
            activeToolRef.value.close();
        } else {
            activeTool.value = null;
        }
        return;
    }
    activeTool.value = viewId;
    // ref.open() will be called by the watch above when component mounts
}


</script>

<template>
  <div
      class="desktop-sidebar-right"
      id="desktop-sidebar-container"
      :class="{
          'has-sheet': hasSheet,
          'tools-mode': !isChat,
          'is-chat': isChat
      }"
      :style="{ width: rightSidebarWidth + 'px', minWidth: rightSidebarWidth + 'px', maxWidth: rightSidebarWidth + 'px' }"
  >
      <div class="sidebar-drag-handle right-handle" @mousedown="startRightResize"></div>

      <!-- ── Chat mode: MagicDrawer icon strip + BottomSheet ── -->
      <template v-if="isChat">
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
              @magic-memory-books="emit('magic-memory-books')"
              @magic-regex="emit('magic-regex')"
              @magic-image-gen="emit('magic-image-gen')"
              @magic-glossary="emit('magic-glossary')"
              @request-preview="() => {}"
               @close="() => {}"
          />

          <BottomSheet
               v-if="bottomSheetState.visible"
               v-bind="bottomSheetState"
               :sidebar-mode="true"
               @close="emit('closeBottomSheet')"
          />
      </template>

      <!-- ── Non-chat mode: Tools icon strip + ToolsView + tool sheets ── -->
      <template v-else>
          <!-- ToolsView background -->
          <div class="tools-view-bg">
              <ToolsView :sidebar-mode="true" @tool-select="openTool" />
          </div>

          <component
              :is="activeToolComponent"
              v-if="activeToolComponent"
              ref="activeToolRef"
          />
      </template>

      <!-- Unified Sidebar Content container (Teleport target) -->
      <div id="desktop-sidebar-content" :class="{ occupied: sidebarState.isOccupied }"></div>
  </div>
</template>

<style scoped>
.tools-view-bg {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    padding-left: 0;
    position: relative;
    z-index: 1;
    transition: transform 0.3s cubic-bezier(0.2, 0.8, 0.2, 1), opacity 0.3s cubic-bezier(0.2, 0.8, 0.2, 1);
    opacity: 1;
    transform: translateX(0);
}

.has-sheet .tools-view-bg {
    opacity: 0;
    transform: translateX(-30px);
    pointer-events: none;
}

.tools-view-bg :deep(.view) {
    padding-bottom: 8px !important;
}
</style>
