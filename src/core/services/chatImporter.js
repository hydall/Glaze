import { db } from '@/utils/db.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { saveFile } from './fileSaver.js';
import { addMessageStats, addRegenerationStats } from './statsService.js';

function createEmptyMemoryCoverage() {
    return {
        entryIds: [],
        needsRebuild: false,
        stale: false
    };
}

function normalizeImportedMessage(msg) {
    if (!msg || typeof msg !== 'object') return msg;
    if (!msg.id) msg.id = `legacy_${msg.timestamp || Date.now()}_${Math.random().toString(36).slice(2, 6)}`;
    if (!Array.isArray(msg.contextRefs)) msg.contextRefs = [];
    if (!msg.memoryCoverage || typeof msg.memoryCoverage !== 'object') msg.memoryCoverage = createEmptyMemoryCoverage();
    if (!Array.isArray(msg.memoryCoverage.entryIds)) msg.memoryCoverage.entryIds = [];
    if (typeof msg.memoryCoverage.needsRebuild !== 'boolean') msg.memoryCoverage.needsRebuild = false;
    if (typeof msg.memoryCoverage.stale !== 'boolean') msg.memoryCoverage.stale = false;
    if (!Array.isArray(msg.triggeredLorebooks)) msg.triggeredLorebooks = msg.triggeredLorebooks ? msg.triggeredLorebooks : [];
    if (!Array.isArray(msg.triggeredMemories)) msg.triggeredMemories = msg.triggeredMemories ? msg.triggeredMemories : [];
    return msg;
}

async function importGlazeChatPackage(json, characterId, userPersona) {
    if (!json || json._format !== 'glaze_chat') {
        throw new Error('Invalid Glaze chat package');
    }

    const sessionId = await db.createSession(characterId);
    const chats = await db.getChats();
    const chatData = chats[characterId];
    if (!chatData.sessions) chatData.sessions = {};

    const importedMessages = Array.isArray(json.messages)
        ? json.messages.map(message => normalizeImportedMessage(JSON.parse(JSON.stringify(message))))
        : [];
    if (!importedMessages.length) throw new Error('No valid messages found in Glaze chat package');

    chatData.sessions[sessionId] = importedMessages;

    if (json.summary) {
        if (!chatData.summaries) chatData.summaries = {};
        chatData.summaries[sessionId] = JSON.parse(JSON.stringify(json.summary));
    }
    if (json.authorsNote) {
        if (!chatData.authorsNotes) chatData.authorsNotes = {};
        chatData.authorsNotes[sessionId] = typeof json.authorsNote === 'object'
            ? (json.authorsNote.content || '')
            : (json.authorsNote || '');
    }
    if (json.memoryBook) {
        if (!chatData.memoryBooks) chatData.memoryBooks = {};
        chatData.memoryBooks[sessionId] = JSON.parse(JSON.stringify(json.memoryBook));
    }

    await db.saveChat(characterId, chatData);

    for (const msg of importedMessages) {
        const chars = msg.text?.length || 0;
        const tokens = Math.ceil(chars / 4);
        addMessageStats(characterId, sessionId, tokens, chars, msg.timestamp);
        if (msg.swipes && msg.swipes.length > 1) {
            for (let i = 0; i < msg.swipes.length; i++) {
                if (i === msg.swipeId) continue;
                const sChars = (msg.swipes[i] || '').length;
                const sTokens = Math.ceil(sChars / 4);
                addRegenerationStats(characterId, sessionId, sTokens, sChars);
            }
        }
    }

    return { characterId, sessionId, messageCount: importedMessages.length };
}

/**
 * Imports a SillyTavern chat file (JSONL) into the application database.
 * @param {File} file - The file object from input.
 * @param {String} characterId - The ID of the character to bind this chat to.
 * @param {Object} userPersona - The persona object to use for user messages.
 * @returns {Promise<Object>} - Result with charName and sessionId.
 */
export async function importSillyTavernChat(file, characterId, userPersona) {
    const fileName = String(file?.name || '').toLowerCase();
    if (fileName.endsWith('.glzchat.json')) {
        const text = await readFile(file);
        const json = JSON.parse(text);
        return importGlazeChatPackage(json, characterId, userPersona);
    }

    let messages = [];
    let metadata = null;
    let isJsonArray = false;

    // Check if it's a JSON array by reading a small chunk
    await new Promise((resolve) => {
        const reader = new FileReader();
        reader.onload = (e) => {
            const str = e.target.result || "";
            if (str.trimStart().startsWith('[')) {
                isJsonArray = true;
            }
            resolve();
        };
        reader.onerror = () => resolve();
        reader.readAsText(file.slice(0, 100));
    });

    if (isJsonArray) {
        try {
            const text = await readFile(file);
            const json = JSON.parse(text);
            if (Array.isArray(json)) {
                let lastTimestamp = 0;
                messages = json.map(obj => {
                    const scMsg = convertMessage(obj, userPersona);
                    if (scMsg.timestamp <= lastTimestamp) {
                        scMsg.timestamp = lastTimestamp + 1;
                    }
                    lastTimestamp = scMsg.timestamp;
                    return scMsg;
                });
            }
        } catch (e) {
            console.warn("Failed to parse JSON array mode, proceeding to JSONL stream", e);
        }
    }

    if (messages.length === 0) {
        let lastTimestamp = 0;
        let lineIndex = 0;
        let remainder = '';

        const processLine = (line) => {
            if (!line.trim()) return;
            try {
                const obj = JSON.parse(line);
                if (obj.chat_metadata) {
                    metadata = obj.chat_metadata;
                } else {
                    const scMsg = convertMessage(obj, userPersona);
                    if (scMsg.timestamp <= lastTimestamp) {
                        scMsg.timestamp = lastTimestamp + 1;
                    }
                    lastTimestamp = scMsg.timestamp;
                    messages.push(scMsg);
                }
            } catch (e) {
                console.warn(`Skipping invalid JSON line at index ${lineIndex}`, e);
            }
            lineIndex++;
        };

        if (typeof file.stream === 'function') {
            const stream = file.stream();
            const reader = stream.getReader();
            const decoder = new TextDecoder('utf-8');

            while (true) {
                const { done, value } = await reader.read();
                if (done) break;

                const chunk = decoder.decode(value, { stream: true });
                const textChunk = remainder + chunk;
                const lines = textChunk.split(/\r?\n/);
                remainder = lines.pop();

                for (let i = 0; i < lines.length; i++) {
                    processLine(lines[i]);
                }
            }
        } else {
            // Fallback for environments lacking stream()
            const text = await readFile(file);
            const lines = text.split(/\r?\n/);
            for (let i = 0; i < lines.length; i++) {
                processLine(lines[i]);
            }
        }

        if (remainder.trim()) {
            processLine(remainder);
        }
    }

    if (messages.length === 0) {
        throw new Error("No valid messages found in file");
    }

    if (!characterId) {
        throw new Error("No character selected for import");
    }

    // Create new session in DB
    // This adapts to db.js structure: { currentId: N, sessions: { ... } }
    const sessionId = await db.createSession(characterId);
    const chats = await db.getChats();
    const chatData = chats[characterId];

    // Save messages to the new session
    if (!chatData.sessions) {
        chatData.sessions = {};
    }
    chatData.sessions[sessionId] = messages;

    // Import Author's Notes if present
    if (metadata && (metadata.note_prompt || metadata.note_depth)) {
        try {
            const roleMap = { 0: 'system', 1: 'user', 2: 'assistant' };
            const anData = {
                enabled: true,
                content: metadata.note_prompt || "",
                depth: typeof metadata.note_depth === 'number' ? metadata.note_depth : 4,
                role: roleMap[metadata.note_role] || 'system',
                position: metadata.note_position !== undefined ? metadata.note_position : 1
            };
            if (!chatData.authorsNotes) chatData.authorsNotes = {};
            chatData.authorsNotes[sessionId] = anData.content; // Save only the content string
        } catch (e) {
            console.warn("Failed to import Author's Notes", e);
        }
    }

    await db.saveChat(characterId, chatData);

    // Add stats for imported messages
    for (const msg of messages) {
        if (!msg) continue;
        const chars = msg.text?.length || 0;
        const tokens = Math.ceil(chars / 4); // Approximation for speed

        addMessageStats(characterId, sessionId, tokens, chars, msg.timestamp);

        if (msg.swipes && msg.swipes.length > 1) {
            for (let i = 0; i < msg.swipes.length; i++) {
                if (i === msg.swipeId) continue;
                const sChars = (msg.swipes[i] || '').length;
                const sTokens = Math.ceil(sChars / 4);
                addRegenerationStats(characterId, sessionId, sTokens, sChars);
            }
        }
    }

    return { characterId, sessionId, messageCount: messages.length };
}

/**
 * Exports a chat session to SillyTavern JSONL format.
 * @param {Object} chat - The chat object from the list (contains id, sessionId, name).
 */
export async function exportSillyTavernChat(chat) {
    const fullChatData = await db.getChat(chat.id);
    if (!fullChatData || !fullChatData.sessions || !fullChatData.sessions[chat.sessionId]) {
        throw new Error("Chat data not found");
    }

    const messages = fullChatData.sessions[chat.sessionId];
    const charName = chat.name;

    // Try to find user name from messages
    let userName = "User";
    const firstUserMsg = messages.find(m => m && m.role === 'user');
    if (firstUserMsg && firstUserMsg.persona && firstUserMsg.persona.name) {
        userName = firstUserMsg.persona.name;
    }

    const lines = [];

    // 1. Metadata Line
    const metadata = {
        user_name: userName,
        character_name: charName,
        create_date: formatSTDate(new Date(messages.find(m => m)?.timestamp || Date.now())),
        chat_metadata: {
            exported_from: "Glaze",
            import_date: Date.now()
        }
    };

    // Export Author's Notes
    try {
        let anData = null;
        if (fullChatData.authorsNotes && fullChatData.authorsNotes[chat.sessionId]) {
            anData = fullChatData.authorsNotes[chat.sessionId];
            // If anData is an object (legacy format), extract content. Otherwise, it's already a string.
            if (typeof anData === 'object') anData = anData.content;

            // In case we want to port back the settings to the legacy preset or just throw them away.
            // Since settings are largely dictated by the active preset now, we keep just content.
        } else {
            const anJson = localStorage.getItem(`gz_an_${charName}`);
            if (anJson) anData = JSON.parse(anJson);
        }

        if (anData) {
            // If anData is a string, we assume it's the content.
            // If it's an object (from legacy localStorage), we check its properties.
            const content = typeof anData === 'string' ? anData : anData.content;
            const enabled = typeof anData === 'string' ? true : anData.enabled; // Assume enabled if just content string
            const depth = typeof anData === 'string' ? 4 : anData.depth; // Default depth if just content string
            const role = typeof anData === 'string' ? 'system' : anData.role; // Default role if just content string
            const position = typeof anData === 'string' ? 1 : anData.position; // Default position if just content string

            if (enabled && content) {
                const roleMap = { 'system': 0, 'user': 1, 'assistant': 2 };
                metadata.chat_metadata.note_prompt = anData.content;
                metadata.chat_metadata.note_depth = anData.depth || 4;
                metadata.chat_metadata.note_role = roleMap[anData.role] !== undefined ? roleMap[anData.role] : 0;
                metadata.chat_metadata.note_position = anData.position !== undefined ? anData.position : 1;
                metadata.chat_metadata.note_interval = 1;
            }
        }
    } catch (e) {
        console.warn("Failed to export Author's Notes", e);
    }

    lines.push(JSON.stringify(metadata));

    // 2. Message Lines
    for (const msg of messages) {
        if (!msg) continue;
        const isUser = msg.role === 'user';
        const name = isUser ? (msg.persona?.name || userName) : charName;
        const dateObj = new Date(msg.timestamp || Date.now());
        const sendDate = formatSTDate(dateObj);

        const stMsg = {
            name: name,
            is_user: isUser,
            is_system: msg.role === 'system',
            send_date: sendDate,
            mes: msg.text || "",
            swipe_id: msg.swipeId,
            swipes: msg.swipes,
            extra: {}
        };

        if (msg.reasoning) {
            stMsg.extra.reasoning = msg.reasoning;
        }
        if (msg.id) {
            stMsg.extra.glazeMessageId = msg.id;
        }
        if (Array.isArray(msg.contextRefs) && msg.contextRefs.length) {
            stMsg.extra.glazeContextRefs = msg.contextRefs;
        }
        if (msg.memoryCoverage && typeof msg.memoryCoverage === 'object') {
            stMsg.extra.glazeMemoryCoverage = msg.memoryCoverage;
        }
        if (Array.isArray(msg.triggeredMemories) && msg.triggeredMemories.length) {
            stMsg.extra.glazeTriggeredMemories = msg.triggeredMemories;
        }

        // Reconstruct swipe_info
        if (msg.swipesMeta && Array.isArray(msg.swipesMeta)) {
            stMsg.swipe_info = msg.swipesMeta.map(meta => {
                const info = { extra: {} };
                if (!meta) return info;
                if (meta.reasoning) info.extra.reasoning = meta.reasoning;
                // Gen time reconstruction (approximate)
                if (meta.genTime) {
                    const durationMs = parseFloat(meta.genTime) * 1000;
                    if (!isNaN(durationMs)) {
                        const end = dateObj.getTime();
                        const start = end - durationMs;
                        info.gen_started = new Date(start).toISOString();
                        info.gen_finished = new Date(end).toISOString();
                    }
                }
                return info;
            });
        }

        // Main message gen time
        if (!isUser && msg.genTime) {
            const durationMs = parseFloat(msg.genTime) * 1000;
            if (!isNaN(durationMs)) {
                const end = dateObj.getTime();
                const start = end - durationMs;
                stMsg.gen_started = new Date(start).toISOString();
                stMsg.gen_finished = new Date(end).toISOString();
            }
        }

        lines.push(JSON.stringify(stMsg));
    }

    const fileContent = lines.join('\n');
    const safeName = charName.replace(/[\\/:*?"<>|]/g, '_');
    const dateStr = new Date().toISOString().replace(/[:T]/g, '-').split('.')[0];
    const filename = `${safeName} - ${dateStr}.jsonl`;

    await saveFile(filename, fileContent, 'application/jsonl', 'chats');
}

export async function exportGlazeChat(chat) {
    const fullChatData = await db.getChat(chat.id);
    if (!fullChatData || !fullChatData.sessions || !fullChatData.sessions[chat.sessionId]) {
        throw new Error('Chat data not found');
    }

    const payload = {
        _format: 'glaze_chat',
        _version: 1,
        exportedAt: Date.now(),
        characterId: chat.id,
        characterName: chat.name,
        sessionId: chat.sessionId,
        messages: JSON.parse(JSON.stringify(fullChatData.sessions[chat.sessionId] || [])),
        summary: fullChatData.summaries?.[chat.sessionId] ?? null,
        authorsNote: fullChatData.authorsNotes?.[chat.sessionId] ?? null,
        memoryBook: fullChatData.memoryBooks?.[chat.sessionId] ?? null
    };

    const safeName = String(chat.name || 'Chat').replace(/[\\/:*?"<>|]/g, '_');
    const dateStr = new Date().toISOString().replace(/[:T]/g, '-').split('.')[0];
    const filename = `${safeName} - ${dateStr}.glzchat.json`;
    await saveFile(filename, JSON.stringify(payload, null, 2), 'application/json', 'chats');
}

/**
 * Opens a file picker for chat files.
 * @returns {Promise<File|null>}
 */
export function pickChatFile() {
    return new Promise((resolve) => {
        const input = document.createElement('input');
        input.type = 'file';
        input.accept = '.json,.jsonl,application/json,text/plain,*/*';
        input.onchange = (e) => {
            resolve(e.target.files[0] || null);
        };
        input.click();
    });
}

/**
 * Opens file dialog and imports chat.
 */
export function triggerChatImport(characterId, userPersona, onImport) {
    pickChatFile().then(async (file) => {
        if (!file) return;
        try {
            const result = await importSillyTavernChat(file, characterId, userPersona);
            if (onImport) {
                onImport(result);
            }
        } catch (error) {
            console.error("Import failed:", error);
            const t = translations[currentLang.value];
            showBottomSheet({
                title: t?.title_error || "Error",
                bigInfo: {
                    icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;color:#ff4444"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>',
                    description: (t?.msg_import_chat_failed || "Failed to import chat") + ": " + error.message,
                    buttonText: t?.btn_ok || "OK",
                    onButtonClick: () => closeBottomSheet()
                }
            });
        }
    });
}

function readFile(file) {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = (e) => resolve(e.target.result);
        reader.onerror = (e) => reject(new Error("Failed to read file"));
        reader.readAsText(file);
    });
}

function convertMessage(stMsg, userPersona) {
    const role = stMsg.is_user ? 'user' : 'char';

    // Date parsing
    let timestamp = Date.now();
    if (stMsg.send_date) {
        const parsed = Date.parse(stMsg.send_date);
        if (!isNaN(parsed)) timestamp = parsed;
    }

    const dateObj = new Date(timestamp);
    const time = `${String(dateObj.getHours()).padStart(2, '0')}:${String(dateObj.getMinutes()).padStart(2, '0')}`;

    const scMsg = {
        role: role,
        text: stMsg.mes || "",
        time: time,
        timestamp: timestamp,
        id: stMsg.extra?.glazeMessageId || `legacy_${timestamp}_${Math.random().toString(36).slice(2, 6)}`,
        // Ensure swipes are transferred
        swipes: Array.isArray(stMsg.swipes) ? stMsg.swipes : [stMsg.mes || ""],
        swipeId: typeof stMsg.swipe_id === 'number' ? stMsg.swipe_id : 0,
        contextRefs: Array.isArray(stMsg.extra?.glazeContextRefs) ? stMsg.extra.glazeContextRefs : [],
        memoryCoverage: stMsg.extra?.glazeMemoryCoverage || createEmptyMemoryCoverage(),
        triggeredMemories: Array.isArray(stMsg.extra?.glazeTriggeredMemories) ? stMsg.extra.glazeTriggeredMemories : []
    };

    // User specific
    if (role === 'user') {
        scMsg.persona = {
            name: userPersona?.name || stMsg.name || "User",
            avatar: userPersona?.avatar || null
        };
    }

    // Character specific & Generation Metadata
    if (role === 'char') {
        // Generation Time from gen_started / gen_finished
        if (stMsg.gen_started && stMsg.gen_finished) {
            scMsg.genTime = calculateDuration(stMsg.gen_started, stMsg.gen_finished);
        }

        // Reasoning from extra (ignoring reasoning_duration)
        if (stMsg.extra && stMsg.extra.reasoning) {
            scMsg.reasoning = stMsg.extra.reasoning;
        }

        // Swipes Metadata (mapping swipe_info)
        if (stMsg.swipe_info && Array.isArray(stMsg.swipe_info)) {
            scMsg.swipesMeta = stMsg.swipe_info.map(info => {
                const meta = {};
                if (info.extra && info.extra.reasoning) {
                    meta.reasoning = info.extra.reasoning;
                }
                if (info.gen_started && info.gen_finished) {
                    meta.genTime = calculateDuration(info.gen_started, info.gen_finished);
                }
                return meta;
            });
        }
    }

    // Ignored fields per instruction:
    // smallsys, tokencount, avatar (force_avatar), api, model

    return scMsg;
}

function calculateDuration(startStr, endStr) {
    const start = new Date(startStr).getTime();
    const end = new Date(endStr).getTime();
    if (!isNaN(start) && !isNaN(end)) {
        return ((end - start) / 1000).toFixed(1) + 's';
    }
    return null;
}

function formatSTDate(date) {
    // Format: "October 3, 2025 9:11pm"
    const options = { month: 'long', day: 'numeric', year: 'numeric', hour: 'numeric', minute: 'numeric', hour12: true };
    let str = date.toLocaleString('en-US', options);
    // Remove 'at' if present (e.g. "October 3, 2025 at 9:11 PM")
    str = str.replace(' at ', ' ');
    // Lowercase am/pm
    str = str.replace(' PM', 'pm').replace(' AM', 'am');
    return str;
}
