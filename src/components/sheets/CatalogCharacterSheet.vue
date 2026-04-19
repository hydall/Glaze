<script setup>
import { ref, computed, watch } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';
import { formatText } from '@/utils/textFormatter.js';

const props = defineProps({
    visible: Boolean,
    item: Object,     // catalog item: { id, avatarUrl, stats, tokens, nsfw, source, slug, ... }
    charData: Object, // Glaze-normalized: { name, creator_notes, tags, creator, ... }
    avatarUrl: String,
});

const emit = defineEmits(['update:visible', 'import']);

const sheetRef = ref(null);

watch(() => props.visible, (v) => {
    if (v) sheetRef.value?.open();
    else sheetRef.value?.close();
});

const desc = computed(() => {
    const raw = props.charData?.creator_notes || props.charData?.description || '';
    return formatText(raw);
});

const allTags = computed(() => props.charData?.tags || []);

function formatNum(n) {
    if (!n) return '0';
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'kk';
    if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
    return String(n);
}

function close() {
    emit('update:visible', false);
}
</script>

<template>
    <SheetView ref="sheetRef" :showBack="true" @back="close" @close="close">
        <div v-if="charData" class="char-sheet">

            <!-- Hero image — pulled up behind the transparent header -->
            <div class="char-hero">
                <img
                    v-if="avatarUrl"
                    :src="avatarUrl"
                    class="hero-img"
                    :alt="charData.name"
                />
                <div v-else class="hero-placeholder">
                    {{ charData.name?.[0]?.toUpperCase() || '?' }}
                </div>
                <div class="hero-gradient"></div>
                <div class="hero-overlay">
                    <div class="hero-badges">
                        <span v-if="item?.nsfw" class="nsfw-badge">NSFW</span>
                    </div>
                    <div class="hero-tokens" v-if="item?.tokens">
                        {{ formatNum(item.tokens) }} tokens
                    </div>
                    <div class="hero-name">{{ charData.name }}</div>
                    <div v-if="charData.creator" class="hero-creator">
                        <a 
                            v-if="charData.creator_id" 
                            :href="'https://janitorai.com/profiles/' + charData.creator_id" 
                            target="_blank"
                            class="creator-link"
                        >@{{ charData.creator }}</a>
                        <span v-else>@{{ charData.creator }}</span>
                    </div>
                </div>

                <!-- Import FAB -->
                <button class="import-fab" @click="$emit('import')" title="Import Character">
                    <svg viewBox="0 0 24 24"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></svg>
                </button>
            </div>

            <!-- Stats -->
            <div class="char-stats" v-if="item?.stats?.chat || item?.stats?.message">
                <div class="stat-pill">
                    <svg viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z"/></svg>
                    <span>{{ formatNum(item.stats.chat) }}</span>
                    <span class="stat-sep" v-if="item.stats.chat && item.stats.message">|</span>
                    <span v-if="item.stats.message">{{ formatNum(item.stats.message) }}</span>
                </div>
            </div>

            <!-- Tags -->
            <div class="char-tags" v-if="allTags.length">
                <span v-for="tag in allTags" :key="tag" class="char-tag" :class="{
                    'char-tag-custom': tag.startsWith('#'),
                    'nsfw-indicator': tag === 'NSFW',
                    'sfw-indicator': tag === 'SFW'
                }">{{ tag }}</span>
            </div>

            <!-- Description -->
            <div class="char-desc-section" v-if="desc">
                <div class="section-label">Description</div>
                <div class="char-desc" v-html="desc"></div>
            </div>

        </div>
    </SheetView>
</template>

<style scoped>
.char-sheet {
    display: flex;
    flex-direction: column;
    padding-bottom: 12px;
}

/* ── Hero ──────────────────────────────────────────────────────────────────── */
.char-hero {
    position: relative;
    width: 100%;
    /* Total height: visible area (230px) + overlap with header (80px) */
    height: 310px;
    /* Pull up behind the SheetView's transparent header (padding-top: 80px on body) */
    margin-top: -80px;
    overflow: hidden;
    flex-shrink: 0;
    background: rgba(255, 255, 255, 0.04);
}

.hero-img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    object-position: center top;
    display: block;
}

.hero-placeholder {
    width: 100%;
    height: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 64px;
    font-weight: 700;
    color: rgba(255, 255, 255, 0.4);
    background: rgba(var(--vk-blue-rgb, 64, 128, 255), 0.08);
}

.hero-gradient {
    position: absolute;
    inset: 0;
    background: linear-gradient(
        to top,
        rgba(0, 0, 0, 0.92) 0%,
        rgba(0, 0, 0, 0.4) 40%,
        transparent 70%
    );
    pointer-events: none;
}

.hero-overlay {
    position: absolute;
    bottom: 0;
    left: 0;
    right: 0;
    padding: 12px 16px 16px;
    display: flex;
    flex-direction: column;
    gap: 2px;
}

.hero-badges {
    display: flex;
    gap: 6px;
    margin-bottom: 4px;
}

.nsfw-badge {
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.05em;
    padding: 2px 7px;
    border-radius: 6px;
    background: rgba(255, 80, 80, 0.25);
    color: #ff6b6b;
    border: 1px solid rgba(255, 80, 80, 0.35);
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
}

.hero-tokens {
    font-size: 11px;
    font-weight: 700;
    color: rgba(255, 255, 255, 0.5);
    text-shadow: 0 1px 2px rgba(0, 0, 0, 0.8);
    text-transform: uppercase;
    letter-spacing: 0.02em;
}

.hero-name {
    font-size: 20px;
    font-weight: 700;
    color: #fff;
    text-shadow: 0 2px 6px rgba(0, 0, 0, 0.8);
    line-height: 1.2;
}

.hero-creator {
    font-size: 13px;
    color: rgba(255, 255, 255, 0.6);
    text-shadow: 0 1px 3px rgba(0, 0, 0, 0.8);
}

.creator-link {
    color: inherit;
    text-decoration: none;
    transition: color 0.15s;
}

@media (hover: hover) {
    .creator-link:hover {
        color: #fff;
        text-decoration: underline;
    }
}

/* ── Stats ─────────────────────────────────────────────────────────────────── */
.char-stats {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 14px 16px 0;
    flex-wrap: wrap;
}

.stat-pill {
    display: flex;
    align-items: center;
    gap: 5px;
    padding: 5px 10px;
    border-radius: 20px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.09);
    font-size: 12px;
    font-weight: 600;
    color: rgba(255, 255, 255, 0.7);
}

.stat-pill svg {
    width: 13px;
    height: 13px;
    fill: currentColor;
    opacity: 0.75;
    flex-shrink: 0;
}

.stat-sep {
    margin: 0 2px;
    opacity: 0.3;
    font-weight: 400;
}

/* ── Tags ──────────────────────────────────────────────────────────────────── */
.char-tags {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    padding: 10px 16px 0;
}

.char-tag {
    font-size: 11px;
    padding: 3px 9px;
    border-radius: 10px;
    background: rgba(var(--vk-blue-rgb, 64, 128, 255), 0.12);
    color: var(--vk-blue, #4080ff);
    border: 1px solid rgba(var(--vk-blue-rgb, 64, 128, 255), 0.2);
    white-space: nowrap;
    font-weight: 600;
}

.nsfw-indicator {
    background: rgba(255, 68, 68, 0.2) !important;
    color: #ff4444 !important;
    border-color: rgba(255, 68, 68, 0.3) !important;
}

.sfw-indicator {
    background: rgba(76, 175, 80, 0.2) !important;
    color: #4caf50 !important;
    border-color: rgba(76, 175, 80, 0.3) !important;
}

.char-tag-custom {
    background: rgba(0, 255, 255, 0.1) !important;
    color: #00cccc !important;
    border-color: rgba(0, 255, 255, 0.2) !important;
}

/* Alternate custom tag color for variety */
.char-tag-custom:nth-child(3n) {
    background: rgba(255, 0, 255, 0.1) !important;
    color: #cc00cc !important;
    border-color: rgba(255, 0, 255, 0.2) !important;
}

/* ── Description ───────────────────────────────────────────────────────────── */
.char-desc-section {
    padding: 16px 16px 0;
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.section-label {
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.07em;
    color: rgba(255, 255, 255, 0.35);
}

.char-desc {
    font-size: 13.5px;
    line-height: 1.55;
    color: rgba(255, 255, 255, 0.75);
    word-break: break-word;
}

.char-desc :deep(p) { margin: 0 0 8px; }
.char-desc :deep(p:last-child) { margin-bottom: 0; }
.char-desc :deep(hr) { border: none; border-top: 1px solid rgba(255,255,255,0.1); margin: 12px 0; }
.char-desc :deep(strong) { color: rgba(255,255,255,0.95); }
.char-desc :deep(em) { color: rgba(255,255,255,0.85); }
.char-desc :deep(img) { max-width: 100%; border-radius: 8px; margin: 4px 0; }
.char-desc :deep(a) { color: var(--vk-blue, #4080ff); text-decoration: none; }

/* ── Import FAB ────────────────────────────────────────────────────────────── */
.import-fab {
    position: absolute;
    bottom: 14px;
    right: 14px;
    width: 48px;
    height: 48px;
    border-radius: 50%;
    background: var(--vk-blue, #4080ff);
    color: #fff;
    border: none;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    box-shadow: 0 4px 16px rgba(0, 0, 0, 0.5);
    transition: transform 0.15s, opacity 0.15s;
    z-index: 2;
}

.import-fab svg {
    width: 22px;
    height: 22px;
    fill: currentColor;
}

.import-fab:active {
    transform: scale(0.92);
    opacity: 0.85;
}
</style>
