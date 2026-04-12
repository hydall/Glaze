<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue';
import { triggerCharacterImport } from '@/utils/characterIO.js';
import { exportCharacterAsV2Json, exportCharacterAsV2Png } from '@/utils/characterIO.js';
import { triggerChatImport } from '@/core/services/chatImporter.js';
import { db } from '@/utils/db.js';
import { createNewSession as dbCreateSession, deleteSession as dbDeleteSession } from '@/utils/sessions.js';
import { translations } from '@/utils/i18n.js';
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
        title: translations[currentLang.value]?.sheet_title_char_options || 'Character',
        items: [
            {
                label: translations[currentLang.value]?.action_create_new || 'Create New',
                icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    window.dispatchEvent(new CustomEvent('open-character-editor', { detail: { index: -1 } }));
                }
            },
            {
                label: translations[currentLang.value]?.action_import || 'Import from file',
                icon: '<svg viewBox="0 0 24 24"><path d="M4 15h2v3h12v-3h2v3c0 1.1-.9 2-2 2H6c-1.1 0-2-.9-2-2v-3zm4.41-6.59L11 5.83V17h2V5.83l2.59 2.58L17 7l-5-5-5 5 1.41 1.41z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    triggerCharacterImport(async (charData) => {
                        if (charData) {
                            try {
                                if (!charData.id) {
                                    charData.id = Date.now().toString();
                                }
                                // Save to IndexedDB
                                await db.saveCharacter(charData, -1);
                                // Reload the list
                                await loadCharacters();
                            } catch (e) {
                                console.error("Failed to save character", e);
                                alert("Failed to save character: " + e.message);
                            }
                        }
                    });
                }
            }
        ]
    });
};

const onEditCharacter = (char) => {
    const index = characters.value.indexOf(char);
    if (index !== -1) {
        window.dispatchEvent(new CustomEvent('open-character-editor', { detail: { index } }));
    }
};

const openActions = (char) => {
    const isFav = char.fav === true;
    const favLabel = isFav 
        ? (translations[currentLang.value]?.action_remove_fav || 'Remove from favorites') 
        : (translations[currentLang.value]?.action_add_fav || 'Add to favorites');
    
    const favIcon = isFav 
        ? '<svg viewBox="0 0 24 24"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/><line x1="4" y1="4" x2="20" y2="20" stroke="#ff4444" stroke-width="2" /></svg>'
        : '<svg viewBox="0 0 24 24"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/></svg>';
    
    const favColor = isFav ? '#ff4444' : 'var(--text-gray)';

    showBottomSheet({
        title: char.name,
        items: [
            {
                label: translations[currentLang.value]?.action_export_st || 'Export',
                icon: '<svg viewBox="0 0 24 24"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    setTimeout(() => {
                        showBottomSheet({
                            title: (translations[currentLang.value]?.action_export_st || 'Export') + ': ' + char.name,
                            items: [
                                {
                                    label: 'PNG (Character Card)',
                                    icon: '<svg viewBox="0 0 24 24"><path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c0 1.1.9 2-2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z"/></svg>',
                                    onClick: () => {
                                        exportCharacterAsV2Png(char);
                                        closeBottomSheet();
                                    }
                                },
                                {
                                    label: 'JSON (SillyTavern V2)',
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
                label: translations[currentLang.value]?.action_delete || 'Delete',
                icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: () => {
                    closeBottomSheet();
                    showBottomSheet({
                        title: translations[currentLang.value]?.confirm_delete_character || 'Delete character?',
                        items: [
                            {
                                label: translations[currentLang.value]?.btn_yes || 'Yes',
                                icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                                iconColor: '#ff4444',
                                isDestructive: true,
                                onClick: async () => {
                                    if (char.id) {
                                        await db.deleteCharacter(char.id);
                                        await loadCharacters();
                                    }
                                    closeBottomSheet();
                                }
                            },
                            {
                                label: translations[currentLang.value]?.btn_no || 'No',
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
        title: translations[currentLang.value]?.sort_by || 'Sort',
        items: [
            {
                label: translations[currentLang.value]?.sort_name || 'Name',
                icon: sortType.value === 'name' ? '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>' : null,
                onClick: () => {
                    sortType.value = 'name';
                    closeBottomSheet();
                }
            },
            {
                label: translations[currentLang.value]?.sort_date || 'Date added',
                icon: sortType.value === 'date' ? '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>' : null,
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
            title: translations[currentLang.value]?.history_title || 'Sessions',
            bigInfo: {
                icon: '<svg viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z"/></svg>',
                description: translations[currentLang.value]?.no_sessions || 'No sessions',
                buttonText: translations[currentLang.value]?.action_create_new || 'Create New',
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
                            title: translations[currentLang.value]?.history_title || 'Sessions',
                            items: [
                                {
                                    label: translations[currentLang.value]?.action_create_new || 'Create New',
                                    icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                                    onClick: async () => {
                                        closeBottomSheet();
                                        await dbCreateSession(char.id);
                                        emit('open-chat', char);
                                    }
                                },
                                {
                                    label: translations[currentLang.value]?.action_import || 'Import from file',
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
        const preview = lastMsg ? (lastMsg.text.length > 40 ? lastMsg.text.substring(0, 40) + '...' : lastMsg.text) : 'Empty session';
        const dateFormatted = lastMsg ? formatDate(lastMsg.timestamp, 'short') : '';
        const isCurrent = sid === currentSessionId;
        
        return {
            label: `Session #${sid}`,
            sublabel: preview,
            badge: `${msgs.length} msgs${dateFormatted ? ' · ' + dateFormatted : ''}`,
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
        title: translations[currentLang.value]?.history_title || 'Sessions',
        cardItems: cardItems,
        headerAction: {
            icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
            onClick: () => {
                closeBottomSheet();
                setTimeout(() => {
                    showBottomSheet({
                        title: translations[currentLang.value]?.history_title || 'Sessions',
                        items: [
                            {
                                label: translations[currentLang.value]?.action_create_new || 'Create New',
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
                                label: translations[currentLang.value]?.action_import || 'Import from file',
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
        title: translations[currentLang.value]?.confirm_delete_session || 'Delete Session?',
        items: [
            {
                label: translations[currentLang.value]?.btn_yes || 'Yes',
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
                label: translations[currentLang.value]?.btn_no || 'No',
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
});

defineExpose({ onAddCharacter });
</script>

<template>
  <div class="view-content-wrapper">
    <!-- Favorites List -->
    <!-- Favorites List -->
    <div class="menu-group" v-if="favorites.length > 0 && !searchQuery">
      <div class="favorites-section">
        <div class="section-title">
          <svg viewBox="0 0 24 24" class="section-icon"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/></svg>
          <span>{{ translations[currentLang.value]?.section_favorites || 'Favorites' }}</span>
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
        <span>{{ sortType === 'name' ? (translations[currentLang.value]?.sort_name || 'Name') : (translations[currentLang.value]?.sort_date || 'Date added') }}</span>
        <svg viewBox="0 0 24 24" style="width: 20px; height: 20px; fill: currentColor;"><path d="M7 10l5 5 5-5z"/></svg>
      </div>
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
          <div class="card-desc" v-if="char.scenario || char.description">{{ char.scenario || char.description }}</div>
          
          <div class="card-actions">
            <div class="card-tag" v-if="char.version">v{{ char.version }}</div>
          </div>
        </div>
      </div>
    </TransitionGroup>

    <div v-if="!isLoading && !hasVisibleCards" class="empty-state">
      <svg class="empty-state-icon" viewBox="0 0 24 24"><path d="M16 11c1.66 0 2.99-1.34 2.99-3S17.66 5 16 5c-1.66 0-3 1.34-3 3s1.34 3 3 3zm-8 0c1.66 0 2.99-1.34 2.99-3S9.66 5 8 5C6.34 5 5 6.34 5 8s1.34 3 3 3zm0 2c-2.33 0-7 1.17-7 3.5V19h14v-2.5c0-2.33-4.67-3.5-7-3.5zm8 0c-.29 0-.62.02-.97.05 1.16.84 1.97 1.97 1.97 3.45V19h6v-2.5c0-2.33-4.67-3.5-7-3.5z"/></svg>
      <div class="empty-state-text">{{ translations[currentLang.value]?.no_characters || 'No characters' }}</div>
    </div>
  </div>
</template>

<style scoped>
.sort-controls {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 12px;
  padding: 0 16px;
  margin-bottom: 12px;
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
  transition: transform 0.1s ease, background-color 0.2s, opacity 0.2s;
  overflow: hidden;
}

.preset-selector:active {
  transform: scale(0.95);
  opacity: 0.8;
}

.preset-selector svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}

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
  grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
  gap: 12px;
  padding: 0 16px;
  padding-bottom: calc(90px + var(--sab)); /* Space for bottom nav */
}

.character-card {
  position: relative;
  border-radius: 16px;
  overflow: hidden;
  aspect-ratio: 2 / 3;
  background-color: var(--bg-color-light, #2a2a2a);
  box-shadow: 0 4px 6px rgba(0,0,0,0.1);
  transition: transform 0.1s ease, box-shadow 0.1s ease;
  cursor: pointer;
  border: 1px solid rgba(255,255,255,0.05);
}

.character-card:active {
  transform: scale(0.96);
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
  transition: background 0.2s;
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