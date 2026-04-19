<script setup>
import { ref, computed, onMounted, onUnmounted, defineAsyncComponent } from 'vue';

const CatalogView = defineAsyncComponent(() => import('@/views/CatalogView.vue'));
import { triggerCharacterImport, extractCharacterBook } from '@/utils/characterIO.js';
import { exportCharacterAsV2Json, exportCharacterAsV2Png } from '@/utils/characterIO.js';
import { triggerChatImport } from '@/core/services/chatImporter.js';
import { importCharacter } from '@/core/states/catalogState.js';
import { datacatExtract, datacatExtractionStatus, datacatGetCharacter } from '@/core/services/catalog/datacatProvider.js';
import { db, markSyncDeletedEntry } from '@/utils/db.js';
import { createNewSession as dbCreateSession, deleteSession as dbDeleteSession } from '@/utils/sessions.js';
import { translations, t, pluralize } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { attachLongPress } from '@/core/services/ui.js';
import { estimateTokens } from '@/utils/tokenizer.js';
import { formatDate } from '@/utils/dateFormatter.js';

const props = defineProps({
  activeCategory: {
    type: String,
    default: 'all'
  }
});

const activeTab = ref('characters');

const emit = defineEmits(['open-chat']);

const characters = ref([]);
const searchQuery = ref('');
const isLoading = ref(true);

const getCharTokens = (char) => {
  let text = char.name || "";
  text += "\n" + (char.description || "");
  text += "\n" + (char.personality || "");
  text += "\n" + (char.scenario || "");
  text += "\n" + (char.first_mes || "");
  text += "\n" + (char.mes_example || "");
  return estimateTokens(text);
};

// Helper to resolve avatar paths
const getAvatarUrl = (avatar) => {
  if (!avatar) return ''; 
  // Assuming avatars are served from /characters/ or are full URLs
  if (avatar.startsWith('http') || avatar.startsWith('blob') || avatar.startsWith('data:')) return avatar;
  return `/characters/${avatar}`;
};

// Fetch characters
const loadCharacters = async () => {
  isLoading.value = true;
  try {
    // Load from IndexedDB
    const chars = await db.getAll('characters');
    // Ensure all characters have an ID
    if (chars) {
        for (const char of chars) {
            if (!char.id) await db.saveCharacter(char);
        }
    }
    characters.value = chars || [];
  } catch (error) {
    console.error('Error loading characters:', error);
    characters.value = [];
  } finally {
    isLoading.value = false;
  }
};

const onAddCharacter = () => {
    showBottomSheet({
        title: t('sheet_title_char_options'),
        items: [
            {
                label: t('action_create_new'),
                hint: t('hint_create_new'),
                icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    window.dispatchEvent(new CustomEvent('open-character-editor', { detail: { index: -1 } }));
                }
            },
            {
                label: t('action_import'),
                hint: t('hint_import_file'),
                icon: '<svg viewBox="0 0 24 24"><path d="M4 15h2v3h12v-3h2v3c0 1.1-.9 2-2 2H6c-1.1 0-2-.9-2-2v-3zm4.41-6.59L11 5.83V17h2V5.83l2.59 2.58L17 7l-5-5-5 5 1.41 1.41z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    triggerCharacterImport(async (charData) => {
                        if (charData) {
                            try {
                                if (!charData.id) {
                                    charData.id = Date.now().toString();
                                }
                                await extractCharacterBook(charData);
                                await db.saveCharacter(charData, -1);
                                await loadCharacters();
                            } catch (e) {
                                console.error("Failed to save character", e);
                                alert("Failed to save character: " + e.message);
                            }
                        }
                    });
                }
            },
            {
                label: t('action_import_janitor'),
                hint: t('hint_import_janitor'),
                icon: '<svg viewBox="0 0 24 24"><path d="M3.9 12c0-1.71 1.39-3.1 3.1-3.1h4V7H7c-2.76 0-5 2.24-5 5s2.24 5 5 5h4v-1.9H7c-1.71 0-3.1-1.39-3.1-3.1zM8 13h8v-2H8v2zm9-6h-4v1.9h4c1.71 0 3.1 1.39 3.1 3.1s-1.39 3.1-3.1 3.1h-4V17h4c2.76 0 5-2.24 5-5s-2.24-5-5-5z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    setTimeout(() => {
                        showBottomSheet({
                            title: t('action_import_janitor'),
                            input: {
                                placeholder: t('placeholder_janitor_url'),
                                confirmLabel: t('btn_ok'),
                                onConfirm: (url) => {
                                    startJanitorExtraction(url);
                                }
                            }
                        });
                    }, 300);
                }
            }
        ]
    });
};

let pollInterval = null;
const startJanitorExtraction = async (url) => {
    closeBottomSheet();
    setTimeout(() => {
        showBottomSheet({
            noDropdown: true,
            title: t('catalog_extracting'),
            bigInfo: {
                icon: `<svg viewBox="0 0 24 24" style="fill:var(--vk-blue);width:100%;height:100%"><path d="M12 4V1L8 5l4 4V6c3.31 0 6 2.69 6 6 0 1.01-.25 1.97-.7 2.8l1.46 1.46C19.54 15.03 20 13.57 20 12c0-4.42-3.58-8-8-8zm0 14c-3.31 0-6-2.69-6-6 0-1.01.25-1.97.7-2.8L5.24 7.74C4.46 8.97 4 10.43 4 12c0 4.42 3.58 8 8 8v3l4-4-4-4v3z"/></svg>`,
                description: t('catalog_extract_progress'),
                buttonText: t('btn_cancel'),
                onButtonClick: () => {
                    if (pollInterval) clearInterval(pollInterval);
                    closeBottomSheet();
                }
            }
        });
    }, 300);

    try {
        await datacatExtract(url, true);
        let attempts = 0;
        const MAX = 60;
        
        pollInterval = setInterval(async () => {
            attempts++;
            if (attempts > MAX) {
                clearInterval(pollInterval);
                closeBottomSheet();
                return;
            }
            try {
                const status = await datacatExtractionStatus();
                // Extract UUID from the provided URL, as DataCat's history URL might not contain the slug or query parameters
                const uuidMatch = url.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
                const searchStr = uuidMatch ? uuidMatch[0] : url;
                
                const done = status.history?.find(h => h.url?.includes(searchStr));
                if (done && done.characterId) {
                    clearInterval(pollInterval);
                    pollInterval = null;
                    
                    const result = await datacatGetCharacter(done.characterId);
                    const charData = result.charData;
                    if (!charData.id) charData.id = Date.now().toString();
                    
                    await importCharacter(charData, result.avatarUrl);
                    closeBottomSheet();
                    
                    setTimeout(() => {
                        const index = characters.value.findIndex(c => c.id === charData.id);
                        if (index !== -1) {
                            window.dispatchEvent(new CustomEvent('open-character-editor', { detail: { index } }));
                        }
                    }, 500);
                }
            } catch (e) { }
        }, 3000);
    } catch(e) {
        closeBottomSheet();
        setTimeout(() => {
            showBottomSheet({
                noDropdown: true,
                title: t('title_error'),
                bigInfo: {
                    icon: `<svg viewBox="0 0 24 24" style="fill:#ff4444;width:100%;height:100%"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>`,
                    description: e.message,
                    buttonText: t('btn_ok'),
                    onButtonClick: closeBottomSheet
                }
            });
        }, 300);
    }
}

const onEditCharacter = (char) => {
    const index = characters.value.indexOf(char);
    if (index !== -1) {
        window.dispatchEvent(new CustomEvent('open-character-editor', { detail: { index } }));
    }
};

const openActions = (char) => {
    const isFav = char.fav === true;
    const favLabel = isFav 
        ? t('action_remove_fav') 
        : t('action_add_fav');
    
    const favIcon = isFav 
        ? '<svg viewBox="0 0 24 24"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/><line x1="4" y1="4" x2="20" y2="20" stroke="#ff4444" stroke-width="2" /></svg>'
        : '<svg viewBox="0 0 24 24"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/></svg>';
    
    const favColor = isFav ? '#ff4444' : 'var(--text-gray)';

    showBottomSheet({
        title: char.name,
        items: [
            {
                label: t('action_export_st'),
                icon: '<svg viewBox="0 0 24 24"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    setTimeout(() => {
                        showBottomSheet({
                            title: t('action_export_st') + ': ' + char.name,
                            items: [
                                {
                                    label: t('label_export_png'),
                                    icon: '<svg viewBox="0 0 24 24"><path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c0 1.1.9 2-2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z"/></svg>',
                                    onClick: () => {
                                        exportCharacterAsV2Png(char);
                                        closeBottomSheet();
                                    }
                                },
                                {
                                    label: t('label_export_json'),
                                    icon: '<svg viewBox="0 0 24 24"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>',
                                    onClick: () => {
                                        exportCharacterAsV2Json(char);
                                        closeBottomSheet();
                                    }
                                }
                            ]
                        });
                    }, 300);
                }
            },
            {
                label: favLabel,
                icon: favIcon,
                iconColor: favColor,
                onClick: async () => {
                    char.fav = !char.fav;
                    await db.saveCharacter(char, -1);
                    closeBottomSheet();
                }
            },
            {
                label: t('action_delete'),
                icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: () => {
                    closeBottomSheet();
                    showBottomSheet({
                        title: t('confirm_delete_character'),
                        items: [
                            {
                                label: t('btn_yes'),
                                icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                                iconColor: '#ff4444',
                                isDestructive: true,
                                onClick: async () => {
                                    if (char.id) {
                                        await db.deleteCharacter(char.id);
                                        await markSyncDeletedEntry('character', char.id);
                                        await loadCharacters();
                                    }
                                    closeBottomSheet();
                                }
                            },
                            {
                                label: t('btn_no'),
                                icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                                onClick: () => closeBottomSheet()
                            }
                        ]
                    });
                }
            }
        ]
    });
};

// Sorting state
const sortType = ref('date'); // 'name' or 'date'
const sortDirection = ref('desc'); // 'asc' or 'desc'

const toggleSortDirection = () => {
    sortDirection.value = sortDirection.value === 'asc' ? 'desc' : 'asc';
};

const openSortTypeSelector = () => {
    showBottomSheet({
        title: t('sort_by'),
        items: [
            {
                label: t('sort_name'),
                isActive: sortType.value === 'name',
                onClick: () => {
                    sortType.value = 'name';
                    closeBottomSheet();
                }
            },
            {
                label: t('sort_date'),
                isActive: sortType.value === 'date',
                onClick: () => {
                    sortType.value = 'date';
                    closeBottomSheet();
                }
            }
        ]
    });
};

// Sorted characters (category + sort, NO search filter)
const sortedCharacters = computed(() => {
  let chars = characters.value;

  // Filter by Category
  if (props.activeCategory !== 'all') {
    chars = chars.filter(char => {
      return char.tags && char.tags.includes(props.activeCategory);
    });
  }

  // Sorting
  chars = [...chars].sort((a, b) => {
    if (sortType.value === 'name') {
      const nameA = (a.name || '').toLowerCase();
      const nameB = (b.name || '').toLowerCase();
      if (nameA < nameB) return sortDirection.value === 'asc' ? -1 : 1;
      if (nameA > nameB) return sortDirection.value === 'asc' ? 1 : -1;
      return 0;
    } else { // 'date'
      const timeA = parseInt(a.id || 0);
      const timeB = parseInt(b.id || 0);
      if (timeA < timeB) return sortDirection.value === 'asc' ? -1 : 1;
      if (timeA > timeB) return sortDirection.value === 'asc' ? 1 : -1;
      return 0;
    }
  });

  return chars;
});

// Check if a card matches search query
const isMatchingSearch = (char) => {
  if (!searchQuery.value) return true;
  if (char.fav) return true; // Favorites are always visible
  const query = searchQuery.value.toLowerCase();
  return (char.name || "").toLowerCase().includes(query);
};

// Final list of characters to display (Filtered by category, sorted, AND filtered by search)
const filteredCharacters = computed(() => {
  return sortedCharacters.value.filter(char => isMatchingSearch(char));
});

// For empty state check
const hasVisibleCards = computed(() => {
  return filteredCharacters.value.length > 0;
});


const favorites = computed(() => {
  return characters.value.filter(char => char.fav === true);
});

onMounted(() => {
  loadCharacters();
  window.addEventListener('header-search', (e) => searchQuery.value = e.detail);
  window.addEventListener('character-updated', loadCharacters);
  window.addEventListener('sync-data-refreshed', loadCharacters);
});

// Custom Directive for Long Press
const vLongPress = {
  mounted: (el, binding) => {
    // attachLongPress returns a function that returns true if a long press just happened
    const check = attachLongPress(el, binding.value);
    el._checkLongPress = check;
  }
};

const openSessionsSheet = async (char) => {
    // Use raw db.get to bypass getChat's auto-session-creation
    let rawData = await db.get(`gz_chat_${char.id}`);
    
    // If no data or no sessions, show the "no sessions" empty state
    if (!rawData || !rawData.sessions || Object.keys(rawData.sessions).length === 0) {
        showBottomSheet({
            title: t('history_title'),
            bigInfo: {
                icon: '<svg viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z"/></svg>',
                description: t('no_sessions'),
                buttonText: t('action_create_new'),
                onButtonClick: async () => {
                    closeBottomSheet();
                    await dbCreateSession(char.id);
                    emit('open-chat', char);
                }
            },
            headerAction: {
                icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    setTimeout(() => {
                        showBottomSheet({
                            title: t('history_title'),
                            items: [
                                {
                                    label: t('action_create_new'),
                                    icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                                    onClick: async () => {
                                        closeBottomSheet();
                                        await dbCreateSession(char.id);
                                        emit('open-chat', char);
                                    }
                                },
                                {
                                    label: t('action_import'),
                                    icon: '<svg viewBox="0 0 24 24"><path d="M4 15h2v3h12v-3h2v3c0 1.1-.9 2-2 2H6c-1.1 0-2-.9-2-2v-3zm4.41-6.59L11 5.83V17h2V5.83l2.59 2.58L17 7l-5-5-5 5 1.41 1.41z"/></svg>',
                                    onClick: () => {
                                        closeBottomSheet();
                                        triggerChatImport(char.id, null, () => {
                                            emit('open-chat', char);
                                        });
                                    }
                                }
                            ]
                        });
                    }, 300);
                }
            }
        });
        return;
    }
    
    const sessions = rawData.sessions;
    const currentSessionId = rawData.currentId;
    
    const ids = Object.keys(sessions).map(Number).sort((a,b) => {
        const lastA = sessions[a][sessions[a].length-1]?.timestamp || 0;
        const lastB = sessions[b][sessions[b].length-1]?.timestamp || 0;
        return lastB - lastA; // descending
    });

    const cardItems = ids.map(sid => {
        const msgs = sessions[sid] || [];
        const lastMsg = msgs[msgs.length - 1];
        const preview = lastMsg ? (lastMsg.text.length > 40 ? lastMsg.text.substring(0, 40) + '...' : lastMsg.text) : t('empty_session');
        const dateFormatted = lastMsg ? formatDate(lastMsg.timestamp, 'short') : '';
        const isCurrent = sid === currentSessionId;
        
        return {
            label: t('session_name', { id: sid }),
            sublabel: preview,
            badge: `${msgs.length} ${pluralize(msgs.length, 'count_messages')}${dateFormatted ? ' · ' + dateFormatted : ''}`,
            onClick: () => {
                closeBottomSheet();
                // We emit the char with the chosen sessionId so ChatView will load it
                const charWithSession = { ...char, sessionId: sid };
                emit('open-chat', charWithSession);
            },
            actions: [
                {
                    icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                    color: '#ff4444',
                    onClick: () => {
                        openDeleteSessionConfirm(char, sid);
                    }
                }
            ]
        };
    });

    showBottomSheet({
        title: t('history_title'),
        cardItems: cardItems,
        headerAction: {
            icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
            onClick: () => {
                closeBottomSheet();
                setTimeout(() => {
                    showBottomSheet({
                        title: t('history_title'),
                        items: [
                            {
                                label: t('action_create_new'),
                                icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                                onClick: async () => {
                                    closeBottomSheet();
                                    await dbCreateSession(char.id);
                                    // Open new session
                                    // We don't pass sessionId so ChatView looks for currentId in DB, which was just created
                                    emit('open-chat', char);
                                }
                            },
                            {
                                label: t('action_import'),
                                icon: '<svg viewBox="0 0 24 24"><path d="M4 15h2v3h12v-3h2v3c0 1.1-.9 2-2 2H6c-1.1 0-2-.9-2-2v-3zm4.41-6.59L11 5.83V17h2V5.83l2.59 2.58L17 7l-5-5-5 5 1.41 1.41z"/></svg>',
                                onClick: () => {
                                    closeBottomSheet();
                                    triggerChatImport(char.id, null, () => {
                                        emit('open-chat', char);
                                    });
                                }
                            }
                        ]
                    });
                }, 300);
            }
        }
    });
};

const openDeleteSessionConfirm = (char, sessionId) => {
    showBottomSheet({
        title: t('confirm_delete_session'),
        items: [
            {
                label: t('btn_yes'),
                icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: async () => {
                    await dbDeleteSession(char.id, sessionId);
                    closeBottomSheet();
                    // Reopen the sheet right after deleting to show updated list
                    setTimeout(() => openSessionsSheet(char), 300);
                }
            },
            {
                label: t('btn_no'),
                icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    setTimeout(() => openSessionsSheet(char), 300);
                }
            }
        ]
    });
};

// Click handler wrapper to prevent click if long press occurred
const handleCharClick = (e, char) => {
  if (e.currentTarget._checkLongPress && e.currentTarget._checkLongPress()) return;
  openSessionsSheet(char);
};

onUnmounted(() => {
  window.removeEventListener('character-updated', loadCharacters);
  window.removeEventListener('sync-data-refreshed', loadCharacters);
});

defineExpose({ onAddCharacter, loadCharacters });
</script>

<template>
  <div class="view-content-wrapper">
    <!-- Tab Bar -->
    <div class="top-tabs-container">
      <div class="tab-slider" :style="{ transform: `translateX(${activeTab === 'catalog' ? '100%' : '0'})` }"></div>
      <div class="top-tab" :class="{ active: activeTab === 'characters' }" @click="activeTab = 'characters'">
        <svg viewBox="0 0 24 24" class="tab-icon"><path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/></svg>
        <span>{{ t('tab_my_characters') }}</span>
      </div>
      <div class="top-tab" :class="{ active: activeTab === 'catalog' }" @click="activeTab = 'catalog'">
        <svg viewBox="0 0 24 24" class="tab-icon"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/></svg>
        <span>{{ t('tab_catalog') }}</span>
      </div>
    </div>

    <!-- Catalog Tab -->
    <CatalogView v-if="activeTab === 'catalog'" class="char-catalog-embed" />

    <!-- Characters Tab -->
    <template v-else>
    <!-- Favorites List -->
    <!-- Favorites List -->
    <div class="menu-group" v-if="favorites.length > 0 && !searchQuery">
      <div class="favorites-section">
        <div class="section-title">
          <svg viewBox="0 0 24 24" class="section-icon"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/></svg>
          <span>{{ t('section_favorites') }}</span>
        </div>
        <div class="favorites-scroll-container">
          <div 
            v-for="char in favorites" 
            :key="char.id || char.name" 
            class="favorite-item"
            @click="handleCharClick($event, char)"
            v-long-press="() => openActions(char)"
            @contextmenu.prevent="openActions(char)"
          >
            <div class="favorite-avatar-wrapper">
              <div class="favorite-avatar">
                <img v-if="char.thumbnail || char.avatar" :src="getAvatarUrl(char.thumbnail || char.avatar)" :alt="char.name" loading="lazy">
                <div v-else class="avatar-placeholder" :style="{ backgroundColor: char.color || '#66ccff' }">
                  {{ (char.name && char.name[0]) ? char.name[0].toUpperCase() : '?' }}
                </div>
              </div>
              <div class="fav-ring"></div>
            </div>
            <div class="favorite-name">{{ char.name }}</div>
          </div>
        </div>
      </div>
    </div>

    <!-- Sort controls -->
    <div class="sort-controls" v-if="characters.length > 0">
      <div class="sort-dir-btn" @click="toggleSortDirection" :class="{ 'is-asc': sortDirection === 'asc' }">
        <svg viewBox="0 0 24 24"><path d="M20 12l-1.41-1.41L13 16.17V4h-2v12.17l-5.58-5.59L4 12l8 8 8-8z"/></svg>
      </div>
      <div class="preset-selector" @click="openSortTypeSelector">
        <span>{{ sortType === 'name' ? t('sort_name') : t('sort_date') }}</span>
        <svg viewBox="0 0 24 24" style="width: 20px; height: 20px; fill: currentColor;" class="selector-chevron"><path d="M7 10l5 5 5-5z"/></svg>
      </div>
    </div>

    <!-- Character Count -->
    <div class="character-count" v-if="characters.length > 0">
      {{ t('catalog_total', { count: filteredCharacters.length }) }}
    </div>

    <!-- Main Character List -->
    <TransitionGroup 
      tag="div" 
      class="character-grid" 
      id="characters-list" 
      name="list"
    >
      <div 
        v-for="char in filteredCharacters" 
        :key="char.id || char.name"
        class="character-card"
        :class="{
          favorite: char.fav
        }"
        @click="handleCharClick($event, char)"
        v-long-press="() => openActions(char)"
        @contextmenu.prevent="openActions(char)"
      >
        <div class="card-token-badge">
          <svg viewBox="0 0 24 24"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>
          <span>{{ getCharTokens(char) }}</span>
        </div>
        <div class="card-edit-btn" @click.stop="onEditCharacter(char)">
          <svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
        </div>
        <div class="card-image-wrapper">
          <img v-if="char.thumbnail || char.avatar" :src="getAvatarUrl(char.thumbnail || char.avatar)" :alt="char.name" loading="lazy" class="card-image">
          <div v-else class="card-placeholder" :style="{ backgroundColor: char.color || '#66ccff' }">
            {{ (char.name && char.name[0]) ? char.name[0].toUpperCase() : '?' }}
          </div>
          <div class="card-gradient"></div>
        </div>
        
        <div class="card-info">
          <div class="card-header-row">
            <div class="card-name">{{ char.name }}</div>
            <div class="card-fav-icon" v-if="char.fav">
              <svg viewBox="0 0 24 24"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/></svg>
            </div>
          </div>
          <div class="card-desc" v-if="char.scenario || char.description" v-html="char.scenario || char.description"></div>
          
          <div class="card-actions">
            <div class="card-tag" v-if="char.version">v{{ char.version }}</div>
          </div>
        </div>
      </div>
    </TransitionGroup>

    <div v-if="!isLoading && !hasVisibleCards" class="empty-state">
      <svg class="empty-state-icon" viewBox="0 0 24 24"><path d="M16 11c1.66 0 2.99-1.34 2.99-3S17.66 5 16 5c-1.66 0-3 1.34-3 3s1.34 3 3 3zm-8 0c1.66 0 2.99-1.34 2.99-3S9.66 5 8 5C6.34 5 5 6.34 5 8s1.34 3 3 3zm0 2c-2.33 0-7 1.17-7 3.5V19h14v-2.5c0-2.33-4.67-3.5-7-3.5zm8 0c-.29 0-.62.02-.97.05 1.16.84 1.97 1.97 1.97 3.45V19h6v-2.5c0-2.33-4.67-3.5-7-3.5z"/></svg>
      <div class="empty-state-text">{{ t('no_characters') }}</div>
    </div>
    </template>
  </div>
</template>

<style scoped>

.char-catalog-embed {
  /* Match the height CatalogView expects: viewport minus header area, char tabs, and footer area */
  height: calc(100dvh - var(--header-height, 60px) - 16px - 53px - var(--footer-height, 80px) - 20px);
}

.top-tabs-container {
  display: flex;
  position: relative;
  align-items: stretch;
  padding: 0;
  margin: 10px 16px 12px;
  background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.1);
  backdrop-filter: blur(var(--element-blur, 12px));
  -webkit-backdrop-filter: blur(var(--element-blur, 12px));
  border: 1px solid rgba(var(--vk-blue-rgb, 82, 139, 204), 0.2);
  border-radius: 100px;
  overflow: hidden;
}

@media (min-width: 600px) {
  .top-tabs-container {
    width: clamp(320px, 33.333%, 500px);
    margin-right: auto;
  }
}

.tab-slider {
  position: absolute;
  top: 0;
  left: 0;
  width: 50%;
  height: 100%;
  background-color: var(--vk-blue, #4080ff);
  border-radius: 100px;
  transition: transform 0.3s cubic-bezier(0.4, 0, 0.2, 1);
  z-index: 0;
}

.top-tab {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  padding: 10px 14px;
  font-size: 14px;
  font-weight: 600;
  color: var(--vk-blue, #4080ff);
  cursor: pointer;
  z-index: 1;
  transition: color 0.3s ease;
  user-select: none;
}

.top-tab.active {
  color: #fff;
}

.tab-icon {
  width: 18px;
  height: 18px;
  fill: currentColor;
}

.sort-controls {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 12px;
  padding: 12px 16px;
}

.sort-dir-btn {
  width: 32px;
  height: 32px;
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: 50%;
  background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.15);
  backdrop-filter: blur(var(--element-blur, 12px));
  -webkit-backdrop-filter: blur(var(--element-blur, 12px));
  border: 1px solid rgba(var(--vk-blue-rgb, 82, 139, 204), 0.2);
  cursor: pointer;
  color: var(--vk-blue);
  transition: transform 0.1s ease, background-color 0.2s, opacity 0.2s;
  flex-shrink: 0;
}

@media (hover: hover) {
  .sort-dir-btn:hover {
    background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.25);
    border-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.4);
    transform: translateY(-1px);
  }
}

.sort-dir-btn:active {
  transform: scale(0.95);
  opacity: 0.8;
}

.sort-dir-btn svg {
  width: 20px;
  height: 20px;
  fill: currentColor;
  transition: transform 0.3s cubic-bezier(0.34, 1.56, 0.64, 1);
}

.sort-dir-btn.is-asc svg {
  transform: rotate(180deg);
}

.preset-selector {
  height: 32px;
  display: flex;
  align-items: center;
  gap: 6px;
  cursor: pointer;
  font-weight: 600;
  font-size: 13px;
  color: var(--vk-blue);
  padding: 0 14px;
  border-radius: 16px;
  background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.15);
  backdrop-filter: blur(var(--element-blur, 12px));
  -webkit-backdrop-filter: blur(var(--element-blur, 12px));
  border: 1px solid rgba(var(--vk-blue-rgb, 82, 139, 204), 0.2);
  transition: transform 0.1s ease, background-color 0.2s, border-color 0.2s, opacity 0.2s;
  overflow: hidden;
  user-select: none;
}

@media (hover: hover) {
  .preset-selector:hover {
    background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.25);
    border-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.4);
    transform: translateY(-1px);
  }
}

.preset-selector:active {
  transform: scale(0.95);
  opacity: 0.8;
}

.preset-selector.active {
  background-color: var(--vk-blue, #4080ff);
  color: #fff;
  border-color: var(--vk-blue, #4080ff);
  box-shadow: 0 4px 12px rgba(var(--vk-blue-rgb, 82, 139, 204), 0.4);
}

.preset-selector.dropdown-open {
  background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.25);
  border-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.5);
}

.preset-selector.dropdown-open .selector-chevron {
  transform: rotate(180deg);
}

.selector-chevron {
  width: 20px;
  height: 20px;
  fill: currentColor;
  transition: transform 0.2s cubic-bezier(0.34, 1.56, 0.64, 1);
}

.character-count {
  font-size: 11px;
  color: var(--text-secondary, rgba(255,255,255,0.45));
  padding: 2px 16px 6px;
  flex-shrink: 0;
}

/* Styles */


/* Favorites Section */
.favorites-section {
  padding: 14px 0;
}

.section-title {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 0 16px;
  margin-bottom: 12px;
  font-size: 13px;
  font-weight: 700;
  color: var(--text-dark-gray);
  text-transform: uppercase;
  letter-spacing: 0.5px;
  opacity: 0.8;
}

.section-icon {
  width: 14px;
  height: 14px;
  fill: #ff4444; /* Heart icon red */
}

/* count removed */

.favorites-scroll-container {
  display: flex;
  overflow-x: auto;
  padding: 8px 16px;
  gap: 16px;
  scrollbar-width: none;
  scroll-behavior: smooth;
  -webkit-overflow-scrolling: touch;
}

.favorites-scroll-container::-webkit-scrollbar {
  display: none;
}

.favorite-item {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 8px;
  flex-shrink: 0;
  width: 72px;
  transition: transform 0.2s cubic-bezier(0.34, 1.56, 0.64, 1);
}

.favorite-item:active {
  transform: scale(0.92);
}

@media (hover: hover) {
  .favorite-item:hover {
    transform: translateY(-2px);
  }
  
  .favorite-item:hover .favorite-avatar {
    transform: scale(1.05);
    box-shadow: 0 6px 16px rgba(0,0,0,0.25);
  }
  
  .favorite-item:hover .favorite-name {
    color: var(--vk-blue);
  }
}

.favorite-avatar-wrapper {
  position: relative;
  width: 56px;
  height: 56px;
}

.favorite-avatar {
  width: 100%;
  height: 100%;
  border-radius: 50%;
  overflow: hidden;
  background-color: var(--bg-color-light, #f0f0f0);
  box-shadow: 0 4px 12px rgba(0,0,0,0.15);
  display: flex;
  align-items: center;
  justify-content: center;
  position: relative;
  z-index: 2;
  transition: transform 0.3s cubic-bezier(0.34, 1.56, 0.64, 1), box-shadow 0.3s ease;
}

.favorite-avatar img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}

.fav-ring {
  position: absolute;
  top: -3px;
  left: -3px;
  right: -3px;
  bottom: -3px;
  border-radius: 50%;
  border: 2px solid var(--vk-blue); /* VK Blue ring */
  opacity: 0.8;
  z-index: 1;
}

.favorite-name {
  font-size: 11px;
  font-weight: 600;
  color: var(--text-dark-gray);
  text-align: center;
  width: 100%;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  transition: color 0.2s ease;
}

/* TransitionGroup Animations */
.list-enter-active,
.list-leave-active {
  transition: all 0.3s ease;
}

.list-enter-from,
.list-leave-to {
  opacity: 0;
  transform: scale(0.9);
}

/* Move animation (FLIP) */
.list-move {
  transition: transform 0.3s ease;
}

.character-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(140px, 1fr));
  gap: 12px;
  padding: 0 16px;
  padding-bottom: calc(90px + var(--sab)); /* Space for bottom nav */
}

@media (min-width: 600px) {
  .character-grid {
    grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
    gap: 16px;
  }
}

.character-card {
  position: relative;
  border-radius: 16px;
  overflow: hidden;
  aspect-ratio: 2 / 3;
  background-color: var(--bg-color-light, #2a2a2a);
  box-shadow: 0 4px 6px rgba(0,0,0,0.1);
  transition: transform 0.3s cubic-bezier(0.34, 1.56, 0.64, 1), box-shadow 0.3s ease, border-color 0.3s ease;
  cursor: pointer;
  border: 1px solid rgba(255,255,255,0.05);
}

.character-card:active {
  transform: scale(0.96);
}

@media (hover: hover) {
  .character-card:hover {
    transform: translateY(-4px) scale(1.01);
    box-shadow: 0 12px 24px rgba(0,0,0,0.3);
  }

  .character-card.favorite:hover {
    box-shadow: 0 12px 24px rgba(var(--vk-blue-rgb, 81, 129, 184), 0.25);
    border-color: rgba(var(--vk-blue-rgb, 81, 129, 184), 0.8);
  }

  .character-card:hover .card-edit-btn {
    box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.4);
    opacity: 1;
    transform: scale(1.1);
  }

  .character-card:hover .card-image {
    transform: scale(1.05);
  }
  
  .character-card:hover .card-token-badge {
    box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.4);
  }
}

.character-card.favorite {
  border: 1px solid rgba(var(--vk-blue-rgb, 81, 129, 184), 0.5);
}

.card-image-wrapper {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 100%;
  z-index: 0;
}

.card-image {
  width: 100%;
  height: 100%;
  object-fit: cover;
  transition: transform 0.5s ease;
}

.card-placeholder {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 3em;
  color: rgba(255,255,255,0.8);
  font-weight: bold;
}

.card-gradient {
  position: absolute;
  bottom: 0;
  left: 0;
  width: 100%;
  height: 70%;
  background: linear-gradient(to top, rgba(0,0,0,0.95) 0%, rgba(0,0,0,0.6) 50%, transparent 100%);
  pointer-events: none;
}

.card-info {
  position: absolute;
  bottom: 0;
  left: 0;
  width: 100%;
  padding: 12px;
  box-sizing: border-box;
  z-index: 1;
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.card-header-row {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
}

.card-name {
  font-weight: 700;
  font-size: 1.1em;
  color: #fff;
  text-shadow: 0 2px 4px rgba(0,0,0,0.8);
  line-height: 1.2;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.card-fav-icon {
  flex-shrink: 0;
  width: 16px;
  height: 16px;
  fill: #ff4444;
  filter: drop-shadow(0 1px 2px rgba(0,0,0,0.5));
}

.card-desc {
  font-size: 0.8em;
  color: rgba(255,255,255,0.8);
  display: -webkit-box;
  -webkit-line-clamp: 3;
  line-clamp: 3;
  -webkit-box-orient: vertical;
  overflow: hidden;
  text-shadow: 0 1px 2px rgba(0,0,0,0.8);
  line-height: 1.3;
}

.card-actions {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-top: 4px;
}

.card-tag {
  font-size: 0.7em;
  color: rgba(255,255,255,0.5);
  background: rgba(0,0,0,0.3);
  padding: 2px 6px;
  border-radius: 4px;
}

.card-edit-btn {
  position: absolute;
  top: 8px;
  right: 8px;
  z-index: 10;
  width: 32px;
  height: 32px;
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: 50%;
  background: rgba(0,0,0,0.5);
  backdrop-filter: blur(4px);
  transition: background 0.2s, opacity 0.2s, transform 0.2s, box-shadow 0.2s;
  opacity: 0.8;
}

.card-edit-btn:active {
  background: rgba(0,0,0,0.7);
}

.card-edit-btn svg {
  width: 18px;
  height: 18px;
  fill: #fff;
}

.card-token-badge {
  position: absolute;
  top: 8px;
  left: 8px;
  z-index: 10;
  display: flex;
  align-items: center;
  font-size: 11px;
  font-weight: 600;
  color: #fff;
  background-color: rgba(0,0,0,0.6);
  backdrop-filter: blur(4px);
  padding: 4px 8px;
  border-radius: 12px;
  pointer-events: none;
  transition: background-color 0.3s ease, box-shadow 0.3s ease;
}

.card-token-badge svg {
  width: 12px;
  height: 12px;
  margin-right: 4px;
  fill: currentColor;
  opacity: 0.9;
}

.empty-state {
  grid-column: 1 / -1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 40px 0;
  text-align: center;
  color: var(--text-gray);
}

.empty-state-icon {
  width: 64px;
  height: 64px;
  margin-bottom: 16px;
  fill: var(--text-gray);
  opacity: 0.5;
}

.empty-state-text {
  font-size: 1.1em;
  font-weight: 500;
}
</style>
