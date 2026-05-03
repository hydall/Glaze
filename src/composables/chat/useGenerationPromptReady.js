function mapTriggeredLorebooks(loreEntries) {
    return loreEntries.map(entry => ({
        id: entry.id,
        name: entry.comment || entry.name || entry.keys?.[0] || 'Entry',
        lorebookName: entry.lorebookName,
        lorebookId: entry.lorebookId,
        _source: entry._source || 'keyword'
    }));
}

function mapTriggeredMemories(memoryEntries) {
    return (memoryEntries || []).map(entry => ({
        id: entry.id,
        name: entry.title || 'Memory'
    }));
}

function buildContextRefs(triggeredLorebooks, triggeredMemories, sessionId) {
    return [
        ...triggeredLorebooks.map(entry => ({
            id: entry.id,
            type: 'lorebook',
            label: entry.name,
            sourceId: entry.lorebookId || null,
            sourceName: entry.lorebookName || null
        })),
        ...triggeredMemories.map(entry => ({
            id: entry.id,
            type: 'memory',
            label: entry.name,
            sourceId: sessionId,
            sourceName: 'Memory Book'
        }))
    ];
}

export async function handleGenerationPromptReady({
    loreEntries,
    memoryEntries,
    currentMessages,
    msgIndex,
    char,
    sessionId,
    persistence,
    snapshotPromptMeta
}) {
    const { db } = persistence;
    const triggeredLorebooks = mapTriggeredLorebooks(loreEntries);
    const triggeredMemories = mapTriggeredMemories(memoryEntries);
    const contextRefs = buildContextRefs(triggeredLorebooks, triggeredMemories, sessionId);

    const assignRefs = (message) => {
        snapshotPromptMeta(message);
        message.triggeredLorebooks = triggeredLorebooks;
        message.triggeredMemories = triggeredMemories;
        message.contextRefs = contextRefs;
    };

    if (msgIndex !== -1 && currentMessages.value[msgIndex]) {
        assignRefs(currentMessages.value[msgIndex]);
    }

    if (msgIndex > 0 && currentMessages.value[msgIndex - 1]?.role === 'user') {
        assignRefs(currentMessages.value[msgIndex - 1]);
    }

    const snapshot = JSON.parse(JSON.stringify(currentMessages.value));
    await db.patchChatData(char.id, (data) => {
        data.sessions[sessionId] = snapshot;
    });
}
