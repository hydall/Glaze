<script setup>
import { ref, computed, onUnmounted } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';
import RollingNumber from '@/components/ui/RollingNumber.vue';
import { db } from '@/utils/db.js';
import { getGlobalStats, getCharStats, getChatStats, migrateStatsIfNeeded } from '@/core/services/statsService.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';

const t = (key) => translations[currentLang.value]?.[key] || key;

const sheet = ref(null);
const currentTab = ref('chat');
const activeChar = ref(null);
const allCharacters = ref([]);
const selectedCharId = ref(null);
const showCharDropdown = ref(false);
const chatHistory = ref([]);

const getAvatarUrl = (avatar) => {
    if (!avatar) return '';
    if (avatar.startsWith('http') || avatar.startsWith('blob') || avatar.startsWith('data:')) return avatar;
    return `/characters/${avatar}`;
};

const selectedChar = computed(() => allCharacters.value.find(c => c.id === selectedCharId.value));
const selectedCharName = computed(() => selectedChar.value?.name || '');
const selectedCharAvatar = computed(() => {
    const src = selectedChar.value?.thumbnail || selectedChar.value?.avatar;
    return src ? getAvatarUrl(src) : '';
});
const selectedCharColor = computed(() => selectedChar.value?.color || '#66ccff');

const statsData = ref({
    chat: { tokens: 0, characters: 0, messages: 0, regenerations: 0, deleted: 0, timeSpent: 0, firstMessage: '' },
    char: { tokens: 0, characters: 0, messages: 0, regenerations: 0, deleted: 0, timeSpent: 0, firstMessage: '' },
    general: { tokens: 0, characters: 0, messages: 0, regenerations: 0, deleted: 0, timeSpent: 0, firstMessage: '' }
});

const formatTime = (seconds) => {
    if (!seconds) return '0s';
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = seconds % 60;
    if (h > 0) return `${h}h ${m}m`;
    if (m > 0) return `${m}m ${s}s`;
    return `${s}s`;
};

const formatDate = (timestamp) => {
    if (!timestamp) return '-';
    return new Date(timestamp).toLocaleString();
};

const calculateStats = async (charId, currentSessionId, history) => {
    // Only calculate chat stats if we have a charId
    if (charId && currentSessionId) {
        const cStats = getChatStats(charId, currentSessionId);
        if (cStats) {
            statsData.value.chat = cStats;
            if (cStats.firstMessage !== '-') {
                statsData.value.chat.firstMessage = formatDate(parseInt(cStats.firstMessage, 10));
            }
        }
    }

    await calculateCharStats(selectedCharId.value);
    await calculateGlobalStats();
};

const calculateCharStats = async (charId) => {
    if (!charId) return;
    const cStats = getCharStats(charId);
    if (cStats) {
        statsData.value.char = cStats;
        if (cStats.firstMessage !== '-') {
            statsData.value.char.firstMessage = formatDate(parseInt(cStats.firstMessage, 10));
        }
    }
};

const calculateGlobalStats = async () => {
    const gStats = getGlobalStats();
    statsData.value.general = gStats;
    if (gStats.firstMessage !== '-') {
        statsData.value.general.firstMessage = formatDate(parseInt(gStats.firstMessage, 10));
    }
};

let updateInterval = null;

const open = async (char, history) => {
    activeChar.value = char;
    selectedCharId.value = char?.id || null;
    chatHistory.value = history || [];
    
    await migrateStatsIfNeeded();
    
    // Fetch all characters for the selector
    allCharacters.value = await db.getAll('characters');

    const sid = char?.sessionId || '1';
    await calculateStats(char?.id, sid, chatHistory.value);
    
    if (updateInterval) clearInterval(updateInterval);
    updateInterval = setInterval(() => {
        // App time
        statsData.value.general.timeSpent = parseInt(localStorage.getItem('gz_time_app') || '0', 10);
        
        // Selected Character time
        if (selectedCharId.value) {
            statsData.value.char.timeSpent = parseInt(localStorage.getItem(`gz_time_char_${selectedCharId.value}`) || '0', 10);
        }
        
        // Current Chat time (only if it matches selected char)
        if (activeChar.value && selectedCharId.value === activeChar.value.id) {
            statsData.value.chat.timeSpent = parseInt(localStorage.getItem(`gz_time_chat_${activeChar.value.id}_${sid}`) || '0', 10);
        }
    }, 1000);

    currentTab.value = 'chat';
    sheet.value?.open();
};

const selectChar = async (id) => {
    selectedCharId.value = id;
    showCharDropdown.value = false;
    await calculateCharStats(id);
};

const close = () => {
    if (updateInterval) clearInterval(updateInterval);
    sheet.value?.close();
};

onUnmounted(() => {
    if (updateInterval) clearInterval(updateInterval);
});

defineExpose({ open, close });

const statsTabs = computed(() => [
    { key: 'chat', label: t('tab_chat') || 'Chat', icon: 'M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z' },
    { key: 'char', label: t('menu_characters') || 'Character', icon: 'M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 3c1.66 0 3 1.34 3 3s-1.34 3-3 3-3-1.34-3-3 1.34-3 3-3zm0 14.2c-2.5 0-4.71-1.28-6-3.22.03-1.99 4-3.08 6-3.08 1.99 0 5.97 1.09 6 3.08-1.29 1.94-3.5 3.22-6 3.22z' },
    { key: 'general', label: t('tab_global') || 'General', icon: 'M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z' }
]);

const currentStats = computed(() => statsData.value[currentTab.value] || statsData.value.chat);

const setTab = (tab) => {
    currentTab.value = tab;
};
</script>

<template>
    <SheetView ref="sheet" :z-index="1005" :title="t('action_chat_stats') || 'Statistics'" :tabs="statsTabs" :active-tab="currentTab" @update:activeTab="setTab">
        <div class="stats-body">
            <!-- Character selector (char tab only) — above hero -->
            <div v-if="currentTab === 'char'" class="char-picker" @click="showCharDropdown = !showCharDropdown">
                <div class="char-picker-avatar">
                    <img v-if="selectedCharAvatar" :src="selectedCharAvatar" alt="">
                    <div v-else class="char-picker-avatar-placeholder" :style="{ background: selectedCharColor }">
                        {{ selectedCharName?.charAt(0) || '?' }}
                    </div>
                </div>
                <span class="char-picker-name">{{ selectedCharName || '—' }}</span>
                <svg class="char-picker-chevron" :class="{ flipped: showCharDropdown }" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="6 9 12 15 18 9"/></svg>
            </div>
            <transition name="dropdown">
                <div v-if="showCharDropdown" class="char-dropdown">
                    <div
                        v-for="char in allCharacters"
                        :key="char.id"
                        class="char-dropdown-item"
                        :class="{ active: char.id === selectedCharId }"
                        @click="selectChar(char.id)"
                    >
                        <div class="char-dropdown-avatar">
                            <img v-if="char.thumbnail || char.avatar" :src="getAvatarUrl(char.thumbnail || char.avatar)" alt="">
                            <div v-else class="char-dropdown-avatar-ph" :style="{ background: char.color || '#66ccff' }">
                                {{ char.name?.charAt(0) || '?' }}
                            </div>
                        </div>
                        <span class="char-dropdown-name">{{ char.name }}</span>
                        <svg v-if="char.id === selectedCharId" class="char-dropdown-check" viewBox="0 0 24 24" fill="currentColor"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41L9 16.17z"/></svg>
                    </div>
                </div>
            </transition>

            <!-- Hero card -->
            <div class="stats-hero">
                <div class="hero-main">
                    <span class="hero-value">
                        <RollingNumber :value="currentStats.messages.toLocaleString()" />
                    </span>
                    <span class="hero-label">{{ t('stats_messages') || 'Messages' }}</span>
                </div>
                <div class="hero-row">
                    <div class="hero-mini">
                        <span class="hero-mini-value">
                            <RollingNumber :value="currentStats.tokens.toLocaleString()" />
                        </span>
                        <span class="hero-mini-label">{{ t('stats_tokens') || 'Tokens' }}</span>
                    </div>
                    <div class="hero-divider" />
                    <div class="hero-mini">
                        <span class="hero-mini-value">
                            <RollingNumber :value="currentStats.characters.toLocaleString()" />
                        </span>
                        <span class="hero-mini-label">{{ t('stats_characters') || 'Characters' }}</span>
                    </div>
                </div>
            </div>

            <!-- Stat items -->
            <div class="stats-card">
                <div class="stat-item">
                    <div class="stat-icon" style="--icon-bg: rgba(76, 175, 80, 0.12); --icon-color: #4CAF50;">
                        <svg viewBox="0 0 24 24" fill="currentColor"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm0 14H5.17L4 17.17V4h16v12zM7 9h2v2H7zm4 0h2v2h-2zm4 0h2v2h-2z"/></svg>
                    </div>
                    <span class="stat-label">{{ t('stats_swipes') || 'Regenerations' }}</span>
                    <span class="stat-value"><RollingNumber :value="currentStats.regenerations.toLocaleString()" /></span>
                </div>
                <div class="stat-separator" />
                <div class="stat-item">
                    <div class="stat-icon" style="--icon-bg: rgba(244, 67, 54, 0.12); --icon-color: #F44336;">
                        <svg viewBox="0 0 24 24" fill="currentColor"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM8 9h8v10H8V9zm7.5-5l-1-1h-5l-1 1H5v2h14V4h-3.5z"/></svg>
                    </div>
                    <span class="stat-label">{{ t('stats_deleted') || 'Deleted' }}</span>
                    <span class="stat-value"><RollingNumber :value="currentStats.deleted.toLocaleString()" /></span>
                </div>
                <div class="stat-separator" />
                <div class="stat-item">
                    <div class="stat-icon" style="--icon-bg: rgba(33, 150, 243, 0.12); --icon-color: #2196F3;">
                        <svg viewBox="0 0 24 24" fill="currentColor"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67V7z"/></svg>
                    </div>
                    <span class="stat-label">{{ currentTab === 'general' ? (t('stats_time_app') || 'App Time') : (t('stats_time') || 'Time Spent') }}</span>
                    <span class="stat-value"><RollingNumber :value="formatTime(currentStats.timeSpent)" /></span>
                </div>
                <div class="stat-separator" />
                <div class="stat-item">
                    <div class="stat-icon" style="--icon-bg: rgba(255, 152, 0, 0.12); --icon-color: #FF9800;">
                        <svg viewBox="0 0 24 24" fill="currentColor"><path d="M9 11H7v2h2v-2zm4 0h-2v2h2v-2zm4 0h-2v2h2v-2zm2-7h-1V2h-2v2H8V2H6v2H5c-1.11 0-1.99.9-1.99 2L3 20c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zm0 16H5V9h14v11z"/></svg>
                    </div>
                    <span class="stat-label">{{ t('stats_first_msg') || 'First Message' }}</span>
                    <span class="stat-value stat-value-date">{{ currentStats.firstMessage }}</span>
                </div>
            </div>
        </div>
    </SheetView>
</template>

<style scoped>
.stats-body {
    padding: 12px 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
}

/* Hero card */
.stats-hero {
    background: linear-gradient(135deg, var(--vk-blue, #7996ce), color-mix(in srgb, var(--vk-blue, #7996ce), #000 20%));
    border-radius: 16px;
    padding: 24px 20px 20px;
    color: #fff;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 16px;
}
.hero-main {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 4px;
}
.hero-value {
    font-size: 40px;
    font-weight: 700;
    line-height: 1.1;
    letter-spacing: -0.5px;
}
.hero-label {
    font-size: 13px;
    font-weight: 500;
    opacity: 0.75;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}
.hero-row {
    display: flex;
    align-items: center;
    gap: 0;
    width: 100%;
    background: rgba(255, 255, 255, 0.12);
    border-radius: 12px;
    padding: 12px 0;
}
.hero-mini {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 2px;
}
.hero-mini-value {
    font-size: 18px;
    font-weight: 600;
}
.hero-mini-label {
    font-size: 11px;
    font-weight: 500;
    opacity: 0.65;
    text-transform: uppercase;
    letter-spacing: 0.3px;
}
.hero-divider {
    width: 1px;
    height: 28px;
    background: rgba(255, 255, 255, 0.2);
    flex-shrink: 0;
}

/* Stats card */
.stats-card {
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 16px;
    overflow: hidden;
}
.stat-item {
    display: flex;
    align-items: center;
    padding: 14px 16px;
    gap: 12px;
}
.stat-icon {
    width: 36px;
    height: 36px;
    border-radius: 10px;
    background: var(--icon-bg);
    color: var(--icon-color);
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
}
.stat-icon svg {
    width: 20px;
    height: 20px;
}
.stat-label {
    font-size: 15px;
    color: var(--text-black);
    font-weight: 500;
    flex: 1;
    min-width: 0;
}
.stat-value {
    font-size: 15px;
    color: var(--text-gray);
    font-weight: 500;
    font-variant-numeric: tabular-nums;
    flex-shrink: 0;
}
.stat-value-date {
    font-size: 13px;
    max-width: 55%;
    text-align: right;
}
.stat-separator {
    height: 0.5px;
    background: rgba(255, 255, 255, 0.06);
    margin-left: 64px;
}

/* Character picker */
.char-picker {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 12px;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 14px;
    cursor: pointer;
    transition: background 0.15s ease;
    -webkit-tap-highlight-color: transparent;
}
.char-picker:active {
    background: rgba(255, 255, 255, 0.1);
}
.char-picker-avatar {
    width: 36px;
    height: 36px;
    border-radius: 50%;
    overflow: hidden;
    flex-shrink: 0;
}
.char-picker-avatar img {
    width: 100%;
    height: 100%;
    object-fit: cover;
}
.char-picker-avatar-placeholder {
    width: 100%;
    height: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    color: #fff;
    font-weight: 600;
    font-size: 16px;
    text-transform: uppercase;
}
.char-picker-name {
    flex: 1;
    font-size: 15px;
    font-weight: 600;
    color: var(--text-black);
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}
.char-picker-chevron {
    width: 20px;
    height: 20px;
    color: var(--text-gray, #99a2ad);
    flex-shrink: 0;
    transition: transform 0.2s ease;
}
.char-picker-chevron.flipped {
    transform: rotate(180deg);
}

/* Dropdown */
.char-dropdown {
    background: rgba(40, 40, 40, 0.9);
    backdrop-filter: blur(20px);
    -webkit-backdrop-filter: blur(20px);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 14px;
    overflow: hidden;
    max-height: 240px;
    overflow-y: auto;
}
.char-dropdown-item {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 10px 14px;
    cursor: pointer;
    transition: background 0.12s ease;
    -webkit-tap-highlight-color: transparent;
}
.char-dropdown-item:active {
    background: rgba(255, 255, 255, 0.06);
}
.char-dropdown-item.active {
    background: rgba(var(--vk-blue-rgb, 81, 129, 184), 0.08);
}
.char-dropdown-item + .char-dropdown-item {
    border-top: 0.5px solid rgba(255, 255, 255, 0.06);
}
.char-dropdown-avatar {
    width: 32px;
    height: 32px;
    border-radius: 50%;
    overflow: hidden;
    flex-shrink: 0;
}
.char-dropdown-avatar img {
    width: 100%;
    height: 100%;
    object-fit: cover;
}
.char-dropdown-avatar-ph {
    width: 100%;
    height: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    color: #fff;
    font-weight: 600;
    font-size: 14px;
    text-transform: uppercase;
}
.char-dropdown-name {
    flex: 1;
    font-size: 15px;
    font-weight: 500;
    color: var(--text-black);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}
.char-dropdown-check {
    width: 20px;
    height: 20px;
    color: var(--vk-blue, #7996ce);
    flex-shrink: 0;
}

/* Dropdown transition */
.dropdown-enter-active,
.dropdown-leave-active {
    transition: opacity 0.15s ease, transform 0.15s ease;
    transform-origin: top center;
}
.dropdown-enter-from,
.dropdown-leave-to {
    opacity: 0;
    transform: scaleY(0.95) translateY(-4px);
}
</style>
