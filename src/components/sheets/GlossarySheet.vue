<script setup>
import { ref, computed, watch, onMounted, onBeforeUnmount } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';
import { translations, t } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';

const props = defineProps({
    viewMode: { type: Boolean, default: false },
});

const sheet = ref(null);
const view = ref('categories'); // 'categories' | 'terms' | 'article'
const selectedCategory = ref(null);
const selectedTerm = ref(null);
const searchQuery = ref('');
const navDirection = ref('forward'); // 'forward' | 'back'
const navStack = ref([]); // [{ view, selectedCategory, selectedTerm }]

const CATEGORY_ICONS = {
    basics:     'M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5',
    characters: 'M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z',
    chat:       'M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 0 1-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z',
    presets:    'M4 6h16M4 10h16M4 14h10',
    lorebooks:  'M4 19.5A2.5 2.5 0 0 1 6.5 17H20M4 19.5A2.5 2.5 0 0 0 6.5 22H20V2H6.5A2.5 2.5 0 0 0 4 4.5v15z',
    regex:      'M10 20l4-16m4 4l4 4-4 4M6 16l-4-4 4-4',
    interface:  'M12 20h9M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z',
    faq:        'M8 9a4 4 0 0 1 8 0c0 2.67-4 4-4 4M12 17h.01',
    advanced:   'M12 2a10 10 0 1 0 0 20A10 10 0 0 0 12 2zm0 4v4l3 3',
};

const CATEGORY_COLORS = {
    basics:     { light: 'rgba(100,149,237,0.12)', dark: 'rgba(100,149,237,0.18)', icon: 'var(--vk-blue)' },
    characters: { light: 'rgba(237,137,54,0.12)',  dark: 'rgba(237,137,54,0.18)',  icon: '#ed8936' },
    chat:       { light: 'rgba(236,201,75,0.12)',  dark: 'rgba(236,201,75,0.18)',  icon: '#ecc94b' },
    presets:    { light: 'rgba(159,122,234,0.12)', dark: 'rgba(159,122,234,0.18)', icon: '#9f7aea' },
    lorebooks:  { light: 'rgba(237,100,100,0.12)', dark: 'rgba(237,100,100,0.18)', icon: '#ed6464' },
    regex:      { light: 'rgba(56,189,178,0.12)',  dark: 'rgba(56,189,178,0.18)',  icon: '#38bdb2' },
    interface:  { light: 'rgba(237,100,166,0.12)', dark: 'rgba(237,100,166,0.18)', icon: '#ed64a6' },
    faq:        { light: 'rgba(72,187,120,0.12)',  dark: 'rgba(72,187,120,0.18)',  icon: '#48bb78' },
    advanced:   { light: 'rgba(160,174,192,0.12)', dark: 'rgba(160,174,192,0.18)', icon: '#a0aec0' },
};

const DEFAULT_COLOR = { light: 'rgba(100,149,237,0.12)', dark: 'rgba(100,149,237,0.18)', icon: 'var(--vk-blue)' };

const categories = computed(() => translations[currentLang.value]?.glossary?.categories || []);

const isSearching = computed(() => searchQuery.value.trim().length > 0);

const searchResults = computed(() => {
    if (!isSearching.value) return [];
    const q = searchQuery.value.trim().toLowerCase();
    return categories.value.flatMap(cat =>
        cat.terms
            .filter(term =>
                term.name.toLowerCase().includes(q) ||
                (term.alt && term.alt.toLowerCase().includes(q)) ||
                (term.desc && term.desc.toLowerCase().includes(q))
            )
            .map(term => ({ ...term, _catLabel: cat.label }))
    );
});

const categoryTerms = computed(() => selectedCategory.value?.terms || []);

const sheetTitle = computed(() => {
    if (view.value === 'terms' && selectedCategory.value) return selectedCategory.value.label;
    if (view.value === 'article' && selectedTerm.value) return selectedTerm.value.name;
    return t('menu_glossary') || 'Glossary';
});

function getCategoryIcon(id) {
    return CATEGORY_ICONS[id] || CATEGORY_ICONS.advanced;
}
function getCategoryColor(id) {
    return CATEGORY_COLORS[id] || DEFAULT_COLOR;
}

function selectCategory(cat) {
    navDirection.value = 'forward';
    navStack.value = [];
    selectedCategory.value = cat;
    view.value = 'terms';
}

function selectTerm(term, fromSearchResults = false) {
    navDirection.value = 'forward';
    navStack.value.push({ view: view.value, selectedCategory: selectedCategory.value, selectedTerm: selectedTerm.value });
    const cat = categories.value.find(c => c.terms.some(t => t.id === term.id));
    if (cat) selectedCategory.value = cat;
    selectedTerm.value = term;
    view.value = 'article';
}

function navigateToChipTerm(termId) {
    const term = categories.value.flatMap(c => c.terms).find(t => t.id === termId);
    if (!term) return;
    navDirection.value = 'forward';
    navStack.value.push({ view: view.value, selectedCategory: selectedCategory.value, selectedTerm: selectedTerm.value });
    const cat = categories.value.find(c => c.terms.some(t => t.id === termId));
    selectedCategory.value = cat;
    selectedTerm.value = term;
    view.value = 'article';
}

function goBack() {
    navDirection.value = 'back';
    if (navStack.value.length > 0) {
        const prev = navStack.value.pop();
        view.value = prev.view;
        selectedCategory.value = prev.selectedCategory;
        selectedTerm.value = prev.selectedTerm;
        return;
    }
    if (view.value === 'article') {
        selectedTerm.value = null;
        view.value = 'terms';
    } else if (view.value === 'terms') {
        view.value = 'categories';
        selectedCategory.value = null;
    }
}

async function open(termId) {
    navStack.value = [];
    if (!props.viewMode) {
        sheet.value?.open();
    }
    if (termId) {
        const term = categories.value.flatMap(c => c.terms).find(t => t.id === termId);
        if (term) {
            const cat = categories.value.find(c => c.terms.some(t => t.id === termId));
            selectedCategory.value = cat;
            selectedTerm.value = term;
            view.value = 'article';
        }
    } else {
        view.value = 'categories';
        selectedCategory.value = null;
        selectedTerm.value = null;
        searchQuery.value = '';
    }
}


function handleGlossaryEvent(e) {
    open(e.detail?.term);
}

function handleGlBack() {
    if (!props.viewMode) return;
    if (view.value === 'categories') {
        window.dispatchEvent(new CustomEvent('navigate-to', { detail: 'view-menu' }));
    } else {
        goBack();
    }
}

// Sync header title when navigating inside viewMode (watches sheetTitle to catch chip-to-chip article nav)
watch(sheetTitle, () => {
    if (!props.viewMode) return;
    window.dispatchEvent(new CustomEvent('gl-header-update', { detail: { title: sheetTitle.value } }));
});

onMounted(() => {
    window.addEventListener('open-glossary', handleGlossaryEvent);
    window.addEventListener('gl-back', handleGlBack);
    if (props.viewMode) {
        window.dispatchEvent(new CustomEvent('gl-header-update', {
            detail: { title: sheetTitle.value }
        }));
    }
});
onBeforeUnmount(() => {
    window.removeEventListener('open-glossary', handleGlossaryEvent);
    window.removeEventListener('gl-back', handleGlBack);
});

const parsedDesc = computed(() => {
    if (!selectedTerm.value?.desc) return [];
    const parts = [];
    // [[termId]] or [[termId|display text]] — chip links
    // [display text](url) — external URL links
    const regex = /\[\[([^\]|]+)(?:\|([^\]]*))?\]\]|\[([^\]]+)\]\((https?:\/\/[^)]+)\)/g;
    const text = selectedTerm.value.desc;
    let lastIndex = 0, match;
    while ((match = regex.exec(text)) !== null) {
        if (match.index > lastIndex) parts.push({ type: 'text', value: text.slice(lastIndex, match.index) });
        if (match[4]) {
            // External URL link: [label](url)
            parts.push({ type: 'link', label: match[3], url: match[4] });
        } else {
            // Term chip: [[termId]] or [[termId|display]]
            const termId = match[1];
            const displayText = match[2];
            const ref = categories.value.flatMap(c => c.terms).find(t => t.id === termId);
            parts.push({ type: 'chip', termId, label: displayText ?? ref?.name ?? termId });
        }
        lastIndex = regex.lastIndex;
    }
    if (lastIndex < text.length) parts.push({ type: 'text', value: text.slice(lastIndex) });
    return parts;
});

function openLink(url) {
    window.open(url, '_blank', 'noopener,noreferrer');
}

defineExpose({ open });
</script>

<template>
    <SheetView ref="sheet" :title="sheetTitle" :show-back="view !== 'categories'" :z-index="20000" :view-mode="viewMode" @back="goBack">

        <div class="gl-view-wrapper view-content-wrapper">
            <Transition :name="navDirection === 'forward' ? 'gl-fwd' : 'gl-back'" mode="out-in">

                <div v-if="view === 'categories'" key="categories" class="gl-cats-view">
                    <div class="gl-search-wrap">
                        <div class="gl-search-bar">
                            <svg class="gl-search-icon" viewBox="0 0 24 24"><path d="M21 21l-4.35-4.35M17 11A6 6 0 1 1 5 11a6 6 0 0 1 12 0z"/></svg>
                            <input v-model="searchQuery" class="gl-search-input" type="search" :placeholder="t('search') || 'Search...'"/>
                            <button v-if="isSearching" class="gl-search-clear" @click="searchQuery = ''">
                                <svg viewBox="0 0 24 24"><path d="M18 6L6 18M6 6l12 12"/></svg>
                            </button>
                        </div>
                    </div>
                    <div v-if="viewMode" class="gl-drawer-hint">
                        <span>{{ t('hint_glossary_drawer') }}</span>&nbsp;<svg viewBox="0 0 24 24"><path d="M19 9l1.25-2.75L23 5l-2.75-1.25L19 1l-1.25 2.75L15 5l2.75 1.25L19 9zm-7.5.5L9 4 6.5 9.5 1 12l5.5 2.5L9 20l2.5-5.5L17 12l-5.5-2.5zM19 15l-1.25 2.75L15 19l2.75 1.25L19 23l1.25-2.75L23 19l-2.75-1.25L19 15z"/></svg>&nbsp;<span>{{ t('hint_glossary_drawer_suffix') }}</span>
                    </div>
                    <Transition name="gl-fade" mode="out-in">
                        <div v-if="isSearching" key="results" class="gl-list">
                            <div v-if="searchResults.length === 0" class="gl-empty">
                                <svg viewBox="0 0 24 24"><path d="M21 21l-4.35-4.35M17 11A6 6 0 1 1 5 11a6 6 0 0 1 12 0z"/></svg>
                                <span>{{ t('no_results') || 'No results' }}</span>
                            </div>
                            <div v-for="term in searchResults" :key="term.id" class="gl-term-item" @click="selectTerm(term, true)">
                                <div class="gl-term-body">
                                    <span class="gl-term-name">{{ term.name }}</span>
                                    <span class="gl-term-sub">{{ term._catLabel }}<template v-if="term.alt"> · {{ term.alt }}</template></span>
                                </div>
                                <svg class="gl-arrow" viewBox="0 0 24 24"><path d="M9 18l6-6-6-6"/></svg>
                            </div>
                        </div>
                        <div v-else key="cats" class="gl-list">
                            <div v-for="cat in categories" :key="cat.id" class="gl-cat-card"
                                :style="{ '--gl-cat-bg-light': getCategoryColor(cat.id).light, '--gl-cat-bg-dark': getCategoryColor(cat.id).dark, '--gl-cat-icon': getCategoryColor(cat.id).icon }"
                                @click="selectCategory(cat)">
                                <div class="gl-cat-icon-wrap"><svg viewBox="0 0 24 24"><path :d="getCategoryIcon(cat.id)"/></svg></div>
                                <div class="gl-cat-info">
                                    <span class="gl-cat-label">{{ cat.label }}</span>
                                    <span class="gl-cat-count">{{ cat.terms.length }} {{ t('glossary_terms') || 'terms' }}</span>
                                </div>
                                <svg class="gl-arrow" viewBox="0 0 24 24"><path d="M9 18l6-6-6-6"/></svg>
                            </div>
                        </div>
                    </Transition>
                </div>

                <div v-else-if="view === 'terms'" key="terms" class="gl-list gl-list--padded">
                    <div v-for="term in categoryTerms" :key="term.id" class="gl-term-item" @click="selectTerm(term, false)">
                        <div class="gl-term-body">
                            <span class="gl-term-name">{{ term.name }}</span>
                            <span v-if="term.alt" class="gl-term-sub">{{ term.alt }}</span>
                        </div>
                        <svg class="gl-arrow" viewBox="0 0 24 24"><path d="M9 18l6-6-6-6"/></svg>
                    </div>
                </div>

                <div v-else-if="view === 'article'" :key="'article-' + selectedTerm?.id" class="gl-article">
                    <div class="gl-article-header">
                        <h1 class="gl-article-title">{{ selectedTerm.name }}</h1>
                        <span v-if="selectedTerm.alt" class="gl-article-badge">{{ selectedTerm.alt }}</span>
                    </div>
                    <div class="gl-article-divider"></div>
                    <p class="gl-article-desc">
                        <template v-for="(part, i) in parsedDesc" :key="i">
                            <span v-if="part.type === 'text'">{{ part.value }}</span>
                            <button v-else-if="part.type === 'chip'" class="gl-chip" @click="navigateToChipTerm(part.termId)">{{ part.label }}</button>
                            <button v-else-if="part.type === 'link'" class="gl-ext-link" @click="openLink(part.url)">{{ part.label }}</button>
                        </template>
                    </p>
                </div>

            </Transition>
        </div>

    </SheetView>
</template>

<style scoped>


/* ── Quick Access hint (viewMode only) ──────────────── */
.gl-drawer-hint {
    padding: 2px 14px 10px;
    font-size: 13px;
    color: var(--text-gray);
    line-height: 1.4;
}

.gl-drawer-hint svg {
    width: 13px;
    height: 13px;
    fill: currentColor;
    display: inline-block;
    vertical-align: middle;
    margin-bottom: 2px;
}

/* ── Categories view ─────────────────────────────────── */
.gl-cats-view {
    display: flex;
    flex-direction: column;
    padding-bottom: calc(80px + var(--sab));
}

/* ── Search ──────────────────────────────────────────── */
.gl-search-wrap {
    padding: 10px 12px 8px;
    flex-shrink: 0;
}

.gl-search-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    background: rgba(255, 255, 255, var(--element-opacity, 0.7));
    border: 1px solid var(--border-color, rgba(0,0,0,0.08));
    border-radius: 14px;
    padding: 0 12px;
    height: 44px;
}

body.dark-theme .gl-search-bar {
    background: rgba(255,255,255,0.06);
    border-color: rgba(255,255,255,0.09);
}

.gl-search-icon {
    width: 17px;
    height: 17px;
    stroke: var(--text-gray);
    stroke-width: 2;
    fill: none;
    stroke-linecap: round;
    stroke-linejoin: round;
    flex-shrink: 0;
}

.gl-search-input {
    flex: 1;
    border: none !important;
    background: transparent !important;
    backdrop-filter: none !important;
    -webkit-backdrop-filter: none !important;
    border-radius: 0 !important;
    box-shadow: none !important;
    overflow: visible !important;
    font-size: 15px;
    color: var(--text-black);
    outline: none;
    font-family: inherit;
    min-width: 0;
    padding: 0;
    height: auto;
}

.gl-search-input::placeholder { color: var(--text-gray); }
.gl-search-input::-webkit-search-cancel-button { display: none; }

.gl-search-clear {
    width: 22px;
    height: 22px;
    border: none;
    background: rgba(0,0,0,0.08);
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    flex-shrink: 0;
    padding: 0;
}

body.dark-theme .gl-search-clear {
    background: rgba(255,255,255,0.1);
}

.gl-search-clear svg {
    width: 12px;
    height: 12px;
    stroke: var(--text-gray);
    stroke-width: 2.5;
    fill: none;
    stroke-linecap: round;
}

/* ── Shared list container ───────────────────────────── */
.gl-list {
    padding: 4px 12px 0;
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.gl-list--padded {
    padding: 12px 12px calc(80px + var(--sab));
}

/* ── Empty state ─────────────────────────────────────── */
.gl-empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 10px;
    padding: 40px 20px;
    color: var(--text-gray);
    font-size: 14px;
}

.gl-empty svg {
    width: 32px;
    height: 32px;
    stroke: var(--text-gray);
    stroke-width: 1.5;
    fill: none;
    stroke-linecap: round;
    opacity: 0.5;
}

/* ── Shared arrow ────────────────────────────────────── */
.gl-arrow {
    width: 17px;
    height: 17px;
    stroke: var(--text-gray);
    stroke-width: 2;
    fill: none;
    stroke-linecap: round;
    stroke-linejoin: round;
    flex-shrink: 0;
    opacity: 0.5;
}

/* ── Category card ───────────────────────────────────── */
.gl-cat-card {
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 14px;
    border-radius: 16px;
    background: rgba(255, 255, 255, var(--element-opacity, 0.7));
    border: 1px solid var(--border-color, rgba(0,0,0,0.08));
    cursor: pointer;
    -webkit-tap-highlight-color: transparent;
    user-select: none;
    transition: opacity 0.15s;
}
.gl-cat-card:active { opacity: 0.65; }

body.dark-theme .gl-cat-card {
    background: rgba(255,255,255,0.05);
    border-color: rgba(255,255,255,0.09);
}

.gl-cat-icon-wrap {
    width: 42px;
    height: 42px;
    border-radius: 12px;
    background: var(--gl-cat-bg-light);
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
}

body.dark-theme .gl-cat-icon-wrap {
    background: var(--gl-cat-bg-dark);
}

.gl-cat-icon-wrap svg {
    width: 20px;
    height: 20px;
    stroke: var(--gl-cat-icon);
    stroke-width: 2;
    fill: none;
    stroke-linecap: round;
    stroke-linejoin: round;
}

.gl-cat-info {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 2px;
}

.gl-cat-label {
    font-weight: 600;
    font-size: 15px;
    color: var(--text-black);
    line-height: 1.2;
}

.gl-cat-count {
    font-size: 12px;
    color: var(--text-gray);
}

/* ── Term item ───────────────────────────────────────── */
.gl-term-item {
    display: flex;
    align-items: center;
    padding: 12px 14px;
    border-radius: 14px;
    background: rgba(255,255,255, var(--element-opacity, 0.7));
    border: 1px solid var(--border-color, rgba(0,0,0,0.08));
    cursor: pointer;
    gap: 10px;
    -webkit-tap-highlight-color: transparent;
    user-select: none;
    transition: opacity 0.15s;
}
.gl-term-item:active { opacity: 0.65; }

body.dark-theme .gl-term-item {
    background: rgba(255,255,255,0.05);
    border-color: rgba(255,255,255,0.09);
}

.gl-term-body {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 2px;
}

.gl-term-name {
    font-weight: 600;
    font-size: 15px;
    color: var(--text-black);
}

.gl-term-sub {
    font-size: 12px;
    color: var(--text-gray);
}

/* ── Article ─────────────────────────────────────────── */
.gl-article {
    padding: 16px 16px calc(80px + var(--sab));
}

.gl-article-header {
    display: flex;
    flex-direction: column;
    gap: 10px;
    margin-bottom: 16px;
}

.gl-article-title {
    margin: 0;
    font-size: 28px;
    font-weight: 700;
    color: var(--text-black);
    line-height: 1.15;
    letter-spacing: -0.5px;
}

.gl-article-badge {
    display: inline-flex;
    align-items: center;
    padding: 4px 10px;
    border-radius: 8px;
    background: rgba(var(--vk-blue-rgb), 0.1);
    color: var(--vk-blue);
    font-size: 12px;
    font-weight: 600;
    align-self: flex-start;
}

.gl-article-divider {
    height: 1px;
    background: var(--border-color, rgba(0,0,0,0.08));
    margin-bottom: 18px;
    border-radius: 1px;
}

body.dark-theme .gl-article-divider {
    background: rgba(255,255,255,0.08);
}

.gl-article-desc {
    margin: 0;
    font-size: 15px;
    line-height: 1.7;
    color: var(--text-black);
    opacity: 0.9;
}

/* ── View transition wrapper ─────────────────────────── */
.gl-view-wrapper {
    display: flex;
    flex-direction: column;
}

/* ── Slide forward (categories → terms → article) ────── */
.gl-fwd-enter-active {
    transition: transform 0.22s cubic-bezier(0.2, 0.8, 0.2, 1), opacity 0.22s ease;
}
.gl-fwd-leave-active {
    transition: transform 0.16s cubic-bezier(0.4, 0, 1, 1), opacity 0.16s ease;
}
.gl-fwd-enter-from {
    transform: translateX(40px);
    opacity: 0;
}
.gl-fwd-leave-to {
    transform: translateX(-30px);
    opacity: 0;
}

/* ── Slide back (article → terms → categories) ───────── */
.gl-back-enter-active {
    transition: transform 0.22s cubic-bezier(0.2, 0.8, 0.2, 1), opacity 0.22s ease;
}
.gl-back-leave-active {
    transition: transform 0.16s cubic-bezier(0.4, 0, 1, 1), opacity 0.16s ease;
}
.gl-back-enter-from {
    transform: translateX(-40px);
    opacity: 0;
}
.gl-back-leave-to {
    transform: translateX(30px);
    opacity: 0;
}

/* ── Fade (search results ↔ category grid) ───────────── */
.gl-fade-enter-active,
.gl-fade-leave-active {
    transition: opacity 0.15s ease;
}
.gl-fade-enter-from,
.gl-fade-leave-to {
    opacity: 0;
}

/* ── Link chips inside article descriptions ──────────── */
.gl-chip {
    display: inline-flex;
    align-items: center;
    padding: 2px 8px;
    margin: 0 2px;
    border-radius: 6px;
    background: rgba(var(--vk-blue-rgb), 0.12);
    color: var(--vk-blue);
    font-size: 13px;
    font-weight: 600;
    font-family: inherit;
    border: 1px solid rgba(var(--vk-blue-rgb), 0.2);
    cursor: pointer;
    vertical-align: baseline;
    line-height: 1.5;
    transition: background 0.15s, opacity 0.15s;
    -webkit-tap-highlight-color: transparent;
}
.gl-chip:active {
    background: rgba(var(--vk-blue-rgb), 0.22);
    opacity: 0.8;
}
body.dark-theme .gl-chip {
    background: rgba(var(--vk-blue-rgb), 0.18);
    border-color: rgba(var(--vk-blue-rgb), 0.28);
}

/* ── External URL links inside article descriptions ──── */
.gl-ext-link {
    display: inline-flex;
    align-items: center;
    padding: 2px 8px;
    margin: 0 2px;
    border-radius: 6px;
    background: rgba(72,187,120,0.12);
    color: #38a169;
    font-size: 13px;
    font-weight: 600;
    font-family: inherit;
    border: 1px solid rgba(72,187,120,0.22);
    cursor: pointer;
    vertical-align: baseline;
    line-height: 1.5;
    transition: background 0.15s, opacity 0.15s;
    -webkit-tap-highlight-color: transparent;
}
.gl-ext-link:active {
    background: rgba(72,187,120,0.22);
    opacity: 0.8;
}
body.dark-theme .gl-ext-link {
    background: rgba(72,187,120,0.18);
    color: #68d391;
    border-color: rgba(72,187,120,0.3);
}
</style>
