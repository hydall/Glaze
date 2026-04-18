<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue';
import { db } from '@/utils/db.js';
import { formatDate } from '@/utils/dateFormatter.js';
import { formatText } from '@/utils/textFormatter.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { translations, pluralize } from '@/utils/i18n.js';
import { currentLang, dialogGrouping } from '@/core/config/APPSettings.js';
import { attachLongPress } from '@/core/services/ui.js';
import { getChatData, createNewSession, deleteSession, renameSession } from '@/utils/sessions.js';
import { importSillyTavernChat, exportSillyTavernChat, exportGlazeChat, pickChatFile } from '@/core/services/chatImporter.js';
import { allPersonas, loadPersonas } from '@/core/states/personaState.js';

const props = defineProps({
  activeCategory: { type: String, default: 'all' }
});

const emit = defineEmits(['open-chat']);

const chats = ref([]);
const characters = ref([]);
const searchQuery = ref('');
const unread = ref({});
const generating = ref({}); // { charName: boolean }

const loadData = async () => {
    try {
        const [chatsDataRaw, unreadDataRaw, charsData] = await Promise.all([
            db.getChats(),
            db.getUnread(),
            db.getAll('characters')
        ]);
        
        const chatsData = chatsDataRaw || {};
        const unreadData = unreadDataRaw || {};

        characters.value = charsData || [];
        unread.value = unreadData;
        
        const processedChats = [];
        const charMap = new Map(charsData.map(c => [c.id, c]));

        Object.keys(chatsData).forEach(charId => {
            const charData = chatsData[charId];
            const char = charMap.get(charId);
            if (!char || !charData) return;

            const sessions = charData.sessions || (Array.isArray(charData) ? { 1: charData } : {});
            const currentId = charData.currentId || 1;

        Object.keys(sessions).forEach(sid => {
            const sessionId = parseInt(sid);
            const msgs = sessions[sid];
            if (!Array.isArray(msgs)) return;
            const lastMsg = msgs[msgs.length - 1];
            const timestamp = lastMsg ? (lastMsg.timestamp || 0) : 0;
                
                // Check generation status from localStorage
                if (localStorage.getItem(`gz_generating_${charId}_${sessionId}`)) generating.value[`${charId}_${sessionId}`] = true;

                processedChats.push({
                    name: char.name || "Unknown",
                    id: char.id,
                    sessionId: sessionId,
                    sessionName: charData.sessionNames?.[sid] || null,
                    msg: lastMsg ? lastMsg.text : (char.first_mes || ""),
                    time: timestamp ? formatDate(timestamp, 'short') : (lastMsg ? lastMsg.time : ""),
                    timestamp: timestamp,
                    messagesCount: msgs.length,
                    avatar: char.avatar,
                    thumbnail: char.thumbnail,
                    color: char.color,
                    category: char.category || 'all',
                    tags: char.tags || [],
                    charObj: { ...char, sessionId: sessionId },
                    isCurrent: sessionId === currentId
                });
            });
        });

        processedChats.sort((a, b) => b.timestamp - a.timestamp);
        chats.value = processedChats;

    } catch (e) {
        console.error("Error loading dialogs:", e);
    }
};

const filteredChats = computed(() => {
    let list = chats.value;
    
    if (props.activeCategory !== 'all') {
        list = list.filter(chat => {
            if (chat.category === props.activeCategory) return true;
            if (chat.tags && chat.tags.includes(props.activeCategory)) return true;
            return false;
        });
    }

    if (searchQuery.value) {
        const q = searchQuery.value.toLowerCase();
        list = list.filter(chat => chat.name && chat.name.toLowerCase().includes(q));
    }

    return list;
});

const getAvatarUrl = (avatar) => {
    if (!avatar) return '';
    if (avatar.startsWith('http') || avatar.startsWith('blob') || avatar.startsWith('data:')) return avatar;
    return `/characters/${avatar}`;
};

const formatPreview = (text) => {
    let formatted = formatText(text);
    formatted = formatted.replace(/<br\s*\/?>/gi, '\n').replace(/<[^>]*>/g, '');
    // Only first line
    const firstLine = formatted.split('\n').find(l => l.trim()) || '';
    return firstLine.length > 100 ? firstLine.substring(0, 100) + '...' : firstLine;
};

// Grouped view: accordion groups per character
const expandedGroups = ref(new Set());

const toggleGroup = (charId) => {
    const next = new Set(expandedGroups.value);
    if (next.has(charId)) next.delete(charId);
    else next.add(charId);
    expandedGroups.value = next;
};

const groupedChats = computed(() => {
    const list = filteredChats.value;
    const map = new Map();
    for (const chat of list) {
        if (!map.has(chat.id)) {
            map.set(chat.id, { latest: chat, sessions: [] });
        }
        const entry = map.get(chat.id);
        entry.sessions.push(chat);
        if (chat.timestamp > entry.latest.timestamp) entry.latest = chat;
    }
    for (const entry of map.values()) {
        entry.sessions.sort((a, b) => b.timestamp - a.timestamp);
    }
    return [...map.values()].sort((a, b) => b.latest.timestamp - a.latest.timestamp);
});

const onOpenChat = (chat) => {
    emit('open-chat', chat.charObj);
};

const handleItemClick = (event, chat) => {
    if (event.currentTarget._checkLongPress && event.currentTarget._checkLongPress()) return;
    onOpenChat(chat);
};

const vLongPress = {
    mounted: (el, binding) => {
        const check = attachLongPress(el, binding.value);
        el._checkLongPress = check;
    }
};

const openActions = (chat, mode = 'flat') => {
    let items = [];
    let title = chat.name;

    if (mode === 'header') {
        items = [
            {
                label: translations[currentLang.value]?.action_edit || 'Edit',
                icon: '<svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>',
                onClick: () => {
                    const charIndex = characters.value.findIndex(c => c.id === chat.id);
                    if (charIndex !== -1) {
                        window.dispatchEvent(new CustomEvent('open-character-editor', { detail: { index: charIndex } }));
                    }
                    closeBottomSheet();
                }
            },
            {
                label: translations[currentLang.value]?.action_new_session || 'New Session',
                icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                onClick: async () => {
                    await createNewSession(chat.id);
                    loadData();
                    closeBottomSheet();
                }
            }
        ];
    } else {
        if (mode !== 'session') {
            items.push({
                label: translations[currentLang.value]?.action_new_session || 'New Session',
                icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                onClick: async () => {
                    await createNewSession(chat.id);
                    loadData();
                    closeBottomSheet();
                }
            });
        }

        if (mode === 'session') {
            items.push({
                label: translations[currentLang.value]?.action_rename || 'Rename',
                icon: '<svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    showBottomSheet({
                        title: translations[currentLang.value]?.action_rename || 'Rename',
                        input: {
                            placeholder: translations[currentLang.value]?.placeholder_enter_name || 'Enter name',
                            value: chat.sessionName || `Session #${chat.sessionId}`,
                            confirmLabel: translations[currentLang.value]?.btn_save || 'Save',
                            onConfirm: async (val) => {
                                if (val) {
                                    await renameSession(chat.id, chat.sessionId, val);
                                    loadData();
                                    closeBottomSheet();
                                }
                            }
                        }
                    });
                }
            });
        }
        
        items.push({
            label: 'Export Chat (Glaze)',
            icon: '<svg viewBox="0 0 24 24"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-7 14-5-5h3V8h4v4h3l-5 5z"/></svg>',
            onClick: () => {
                exportGlazeChat(chat);
                closeBottomSheet();
            }
        });

        items.push({
            label: translations[currentLang.value]?.action_export_chat || 'Export Chat (JSONL)',
            icon: '<svg viewBox="0 0 24 24"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></svg>',
            onClick: () => {
                exportSillyTavernChat(chat);
                closeBottomSheet();
            }
        });
        
        items.push({
            label: translations[currentLang.value]?.action_delete_session || 'Delete Session',
            icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
            iconColor: '#ff4444',
            isDestructive: true,
            onClick: () => {
                closeBottomSheet();
                showBottomSheet({
                    title: translations[currentLang.value]?.confirm_delete_session || 'Delete session?',
                    items: [
                        {
                            label: translations[currentLang.value]?.btn_yes || 'Yes',
                            icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                            iconColor: '#ff4444',
                            isDestructive: true,
                            onClick: async () => {
                                // Check if it's the last session to prevent auto-creation of a new one
                                const chats = await db.getChats() || {};
                                let charData = chats[chat.id];
                                let sessionCount = 0;
                                
                                if (charData) {
                                    if (charData.sessions) {
                                        sessionCount = Object.keys(charData.sessions).length;
                                    } else if (Array.isArray(charData)) {
                                        sessionCount = 1;
                                    }
                                }

                                if (sessionCount <= 1) {
                                    if (charData) {
                                        if (Array.isArray(charData)) {
                                            charData = { currentId: 1, sessions: {} };
                                        } else if (charData.sessions) {
                                            delete charData.sessions[chat.sessionId];
                                        }
                                        await db.saveChat(chat.id, charData);
                                    }
                                } else {
                                    await deleteSession(chat.id, chat.sessionId);
                                }
                                
                                loadData();
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
        });

        if (mode === 'session') {
            title += ` (#${chat.sessionId})`;
        }
    }

    showBottomSheet({
        title,
        items
    });
};

const handleHeaderClick = (event, charId) => {
    if (event.currentTarget._checkLongPress && event.currentTarget._checkLongPress()) return;
    toggleGroup(charId);
};


const startChatImport = async () => {
    const file = await pickChatFile();
    if (!file) return;

    // Ensure personas are loaded
    if (allPersonas.value.length === 0) {
        await loadPersonas();
    }

    // 1. Select Persona
    const selectPersona = () => {
        const items = allPersonas.value.map(p => ({
            label: p.name,
            icon: p.avatar ? `<img src="${p.avatar}" style="width:24px;height:24px;border-radius:50%;object-fit:cover;">` : 
                  `<div style="width:24px;height:24px;border-radius:50%;background-color:var(--vk-blue);display:flex;align-items:center;justify-content:center;color:white;font-size:12px;font-weight:bold;">${(p.name && p.name[0] ? p.name[0] : '?').toUpperCase()}</div>`,
            onClick: () => {
                closeBottomSheet();
                setTimeout(() => selectCharacter(p), 300);
            }
        }));

        showBottomSheet({
            title: translations[currentLang.value]?.select_persona_import || 'Select User Persona',
            items: items
        });
    };

    // 2. Select Character
    const selectCharacter = (persona) => {
        const items = characters.value.map(char => ({
            label: char.name || "Unknown",
            icon: (char.thumbnail || char.avatar) ? `<img src="${getAvatarUrl(char.thumbnail || char.avatar)}" style="width:24px;height:24px;border-radius:50%;object-fit:cover;">` : 
                  `<div style="width:24px;height:24px;border-radius:50%;background-color:${char.color||'#ccc'};display:flex;align-items:center;justify-content:center;color:white;font-size:12px;font-weight:bold;">${(char.name && char.name[0] ? char.name[0] : '?').toUpperCase()}</div>`,
            onClick: () => {
                closeBottomSheet();
                performImport(persona, char.id);
            }
        }));

        showBottomSheet({
            title: translations[currentLang.value]?.select_char_import || 'Select Character',
            items: items
        });
    };

    // 3. Perform Import
    const performImport = async (persona, charId) => {
        try {
            const result = await importSillyTavernChat(file, charId, persona);
            loadData();
            
            showBottomSheet({
                title: translations[currentLang.value]?.import_success || 'Import Successful',
                bigInfo: {
                    icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                    description: `Imported ${result.messageCount} messages.`,
                    buttonText: translations[currentLang.value]?.btn_close || 'Close',
                    onButtonClick: () => {
                        closeBottomSheet();
                    }
                }
            });
        } catch (err) {
            console.error("Chat import failed", err);
            alert("Import error: " + err.message);
        }
    };

    selectPersona();
};

const openNewChatPicker = () => {
    const items = characters.value.map(char => ({
        label: char.name || "Unknown",
        icon: (char.thumbnail || char.avatar) ? `<img src="${getAvatarUrl(char.thumbnail || char.avatar)}" style="width:24px;height:24px;border-radius:50%;object-fit:cover;">` : 
              `<div style="width:24px;height:24px;border-radius:50%;background-color:${char.color||'#ccc'};display:flex;align-items:center;justify-content:center;color:white;font-size:12px;font-weight:bold;">${(char.name && char.name[0] ? char.name[0] : '?').toUpperCase()}</div>`,
        onClick: async () => {
            closeBottomSheet();
            const sessionId = await createNewSession(char.id);
            emit('open-chat', { charId: char.id, sessionId });
        }
    }));

    items.push({
        label: 'Import from SillyTavern (JSONL)',
        icon: '<svg viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm0 14H6l-2 2V4h16v12z"/></svg>',
        onClick: () => {
            closeBottomSheet();
            startChatImport();
        }
    });

    showBottomSheet({
        title: translations[currentLang.value]?.sheet_title_select_char || 'Select Character',
        items: items
    });
};

const onGenerationStarted = (e) => {
    if (e.detail && e.detail.charId && e.detail.sessionId) {
        generating.value[`${e.detail.charId}_${e.detail.sessionId}`] = true;
    }
};

const onGenerationEnded = (e) => {
    if (e.detail && e.detail.charId && e.detail.sessionId) {
        generating.value[`${e.detail.charId}_${e.detail.sessionId}`] = false;
        loadData(); // Reload to show new message and unread status
    }
};

const onGroupEnter = (el, done) => {
    el.style.height = '0px';
    el.style.opacity = '0';
    el.style.transform = 'translateY(-10px)';
    
    void el.offsetWidth; // Force reflow
    
    el.style.transition = 'height 0.25s cubic-bezier(0.2, 0.8, 0.2, 1), opacity 0.3s ease, transform 0.3s cubic-bezier(0.2, 0.8, 0.2, 1)';
    el.style.height = el.scrollHeight + 'px';
    el.style.opacity = '1';
    el.style.transform = 'translateY(0)';
    
    const onEnd = (e) => {
        if (e.propertyName === 'height') {
            el.removeEventListener('transitionend', onEnd);
            done();
        }
    };
    el.addEventListener('transitionend', onEnd);
};

const onGroupAfterEnter = (el) => {
    el.style.height = 'auto';
    el.style.transition = '';
    el.style.transform = '';
    el.style.opacity = '';
};

const onGroupLeave = (el, done) => {
    el.style.height = el.scrollHeight + 'px';
    
    void el.offsetWidth; // Force reflow
    
    el.style.transition = 'height 0.2s cubic-bezier(0.4, 0, 0.2, 1), opacity 0.2s ease, transform 0.2s cubic-bezier(0.4, 0, 0.2, 1)';
    
    requestAnimationFrame(() => {
        el.style.height = '0px';
        el.style.opacity = '0';
        el.style.transform = 'translateY(-10px)';
    });
    
    const onEnd = (e) => {
        if (e.propertyName === 'height') {
            el.removeEventListener('transitionend', onEnd);
            done();
        }
    };
    el.addEventListener('transitionend', onEnd);
};

defineExpose({ openNewChatPicker });

onMounted(() => {
    loadData();
    window.addEventListener('sync-data-refreshed', loadData);
    window.addEventListener('chat-updated', loadData);
    window.addEventListener('character-updated', loadData);
    window.addEventListener('chat-generation-started', onGenerationStarted);
    window.addEventListener('chat-generation-ended', onGenerationEnded);
    window.addEventListener('header-search', (e) => searchQuery.value = e.detail);
});

onUnmounted(() => {
    window.removeEventListener('sync-data-refreshed', loadData);
    window.removeEventListener('chat-updated', loadData);
    window.removeEventListener('character-updated', loadData);
    window.removeEventListener('chat-generation-started', onGenerationStarted);
    window.removeEventListener('chat-generation-ended', onGenerationEnded);
    // Note: anonymous listener for header-search is fine as component is unmounted
});
</script>

<template>
  <div class="view-content-wrapper">
      <div class="list-container">
          <!-- Flat list mode -->
          <template v-if="!dialogGrouping">
              <div v-for="chat in filteredChats" :key="chat.id + '_' + chat.sessionId" class="list-item" :class="{ unread: unread[chat.id] && chat.isCurrent }" v-long-press="() => openActions(chat)" @click="handleItemClick($event, chat)" @contextmenu.prevent="openActions(chat)">
                <div class="avatar">
                    <img v-if="chat.thumbnail || chat.avatar" :src="getAvatarUrl(chat.thumbnail || chat.avatar)" :alt="chat.name" loading="lazy">
                    <div v-else class="avatar-placeholder" :style="{ backgroundColor: chat.color || '#66ccff' }">{{ chat.name && chat.name[0] ? chat.name[0].toUpperCase() : '?' }}</div>
                </div>
                <div class="item-content">
                    <div class="item-header"><span class="item-title">{{ chat.name }}</span><span class="item-meta">{{ chat.time }}</span></div>
                    <div class="item-subtitle">
                        <div class="session-label">{{ chat.sessionName || 'Session #' + chat.sessionId }}</div>
                        <div class="msg-preview" v-if="!generating[`${chat.id}_${chat.sessionId}`]">{{ formatPreview(chat.msg) }}</div>
                        <div class="msg-preview generating" v-else>
                            <svg class="typing-icon-mini" viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
                            <span>{{ translations[currentLang.value]?.model_typing || 'Generating...' }}</span>
                        </div>
                    </div>
                </div>
                <div class="unread-dot" v-if="unread[chat.id] && chat.isCurrent"></div>
              </div>
          </template>

          <!-- Grouped mode -->
          <template v-else>
              <div v-for="group in groupedChats" :key="'g_' + group.latest.id" class="group-block">
                <!-- Character group header -->
                <div class="list-item group-header" :class="{ unread: unread[group.latest.id] && !expandedGroups.has(group.latest.id) }" v-long-press="() => openActions(group.latest, 'header')" @click="handleHeaderClick($event, group.latest.id)" @contextmenu.prevent="openActions(group.latest, 'header')">
                    <div class="avatar">
                        <img v-if="group.latest.thumbnail || group.latest.avatar" :src="getAvatarUrl(group.latest.thumbnail || group.latest.avatar)" :alt="group.latest.name" loading="lazy">
                        <div v-else class="avatar-placeholder" :style="{ backgroundColor: group.latest.color || '#66ccff' }">{{ group.latest.name && group.latest.name[0] ? group.latest.name[0].toUpperCase() : '?' }}</div>
                    </div>
                    <div class="item-content">
                        <div class="item-header">
                            <span class="item-title">{{ group.latest.name }}</span>
                            <span class="item-meta">{{ group.latest.time }}</span>
                        </div>
                        <div class="item-subtitle">
                            <div class="session-labels-row">
                                <div class="session-count-label">{{ group.sessions.length }} {{ pluralize(group.sessions.length, 'count_sessions') }}</div>
                                <div class="group-right-icons">
                                    <div class="unread-dot" v-if="unread[group.latest.id] && !expandedGroups.has(group.latest.id)"></div>
                                    <svg class="group-chevron" :class="{ expanded: expandedGroups.has(group.latest.id) }" viewBox="0 0 24 24"><path d="M7.41 8.59L12 13.17l4.59-4.58L18 10l-6 6-6-6z"/></svg>
                                </div>
                            </div>
                            <div class="msg-preview" v-if="!generating[`${group.latest.id}_${group.latest.sessionId}`]">{{ formatPreview(group.latest.msg) }}</div>
                            <div class="msg-preview generating" v-else>
                                <svg class="typing-icon-mini" viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
                                <span>{{ translations[currentLang.value]?.model_typing || 'Generating...' }}</span>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Sessions list (expanded) -->
                <Transition @enter="onGroupEnter" @after-enter="onGroupAfterEnter" @leave="onGroupLeave" :css="false">
                    <div v-if="expandedGroups.has(group.latest.id)" class="group-expand-wrapper">
                        <div class="sessions-list sheet-card-list dialog-sessions-list">
                            <div v-for="session in group.sessions" :key="session.id + '_' + session.sessionId" 
                                 class="triggered-item-card" 
                             v-long-press="() => openActions(session, 'session')" 
                             @click="handleItemClick($event, session)" 
                             @contextmenu.prevent="openActions(session, 'session')">
                            <div class="item-info">
                                <div class="item-label-row">
                                    <div class="item-label" :class="{ 'unread-text': unread[session.id] && session.isCurrent }">{{ session.sessionName || 'Session #' + session.sessionId }}</div>
                                    <div class="item-badge">
                                        <svg viewBox="0 0 24 24" class="badge-icon"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>
                                        {{ session.messagesCount || '0' }} {{ pluralize(session.messagesCount || 0, 'count_messages') }}{{ session.time ? ' · ' + session.time : '' }}
                                    </div>
                                </div>
                                <div class="item-sublabel" :class="{ 'unread-text': unread[session.id] && session.isCurrent }" v-if="!generating[`${session.id}_${session.sessionId}`]">{{ formatPreview(session.msg) }}</div>
                                <div class="item-sublabel generating" v-else>
                                    <svg class="typing-icon-mini" viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
                                    <span>{{ translations[currentLang.value]?.model_typing || 'Generating...' }}</span>
                                </div>
                            </div>
                            <div class="unread-dot" v-if="unread[session.id] && session.isCurrent"></div>
                        </div>
                        </div>
                    </div>
                </Transition>
              </div>
          </template>

          <div v-if="filteredChats.length === 0" class="empty-state">
              <svg class="empty-state-icon" viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm0 14H6l-2 2V4h16v12z"/></svg>
              <div class="empty-state-text">{{ translations[currentLang.value]?.no_dialogs || 'No dialogs' }}</div>
          </div>
      </div>
  </div>
</template>

<style scoped>
.list-container { padding-bottom: calc(80px + var(--sab)); }
.session-label { color: var(--text-gray); font-size: 0.8em; margin-bottom: 2px; }
.msg-preview { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.session-count-label { color: var(--text-gray); font-size: 0.8em; margin-bottom: 2px; }

.group-expand-wrapper {
    overflow: hidden;
    will-change: height;
}

.dialog-sessions-list .item-label-row {
    flex-wrap: nowrap;
}

/* Grouped mode */
.group-block { display: flex; flex-direction: column; }

.group-header { cursor: pointer; }

.session-labels-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.group-right-icons {
    display: flex;
    align-items: center;
    justify-content: flex-end;
}

.group-right-icons .unread-dot {
    margin-left: 0;
    margin-right: 4px;
}

.group-chevron {
    width: 20px;
    height: 20px;
    flex-shrink: 0;
    fill: var(--text-gray);
    margin-left: 4px;
    transition: transform 0.2s ease;
}
.group-chevron.expanded { transform: rotate(180deg); }

.sessions-list { overflow: hidden; }

.dialog-sessions-list {
    padding: 0 16px 16px 16px;
    gap: 8px;
}

.item-label.unread-text, .item-sublabel.unread-text {
    color: var(--vk-blue) !important;
    font-weight: 500;
}



.msg-preview.generating {
    display: flex;
    align-items: center;
    gap: 4px;
    color: var(--text-gray);
    font-style: italic;
}

.typing-icon-mini {
    width: 14px;
    height: 14px;
    fill: currentColor;
    animation: pulse 1s infinite alternate;
}

@keyframes pulse {
    from { opacity: 0.5; }
    to { opacity: 1; }
}

.list-item.unread .msg-preview {
    color: var(--vk-blue);
    font-weight: 500;
}

.unread-dot {
    width: 10px;
    height: 10px;
    background-color: var(--vk-blue);
    border-radius: 50%;
    margin-left: 8px;
    flex-shrink: 0;
}
</style>
