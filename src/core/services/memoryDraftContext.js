export function buildMemoryContinuityContext(memoryBook, selected) {
    const selectedIds = new Set(selected.map(msg => msg.id));
    const activeEntries = Array.isArray(memoryBook.entries) ? memoryBook.entries : [];
    return activeEntries
        .filter(entry => {
            const ids = Array.isArray(entry.messageIds) ? entry.messageIds : [];
            return ids.length && ids.every(id => !selectedIds.has(id));
        })
        .slice(-2)
        .map(entry => `${entry.title || 'Memory'}: ${entry.content || ''}`.trim())
        .filter(Boolean)
        .join('\n\n');
}

export function buildMemoryDraftLoreContext(selected) {
    const historicalLabels = new Map();
    selected.forEach(msg => {
        (Array.isArray(msg?.contextRefs) ? msg.contextRefs : []).forEach(ref => {
            if (ref?.type === 'lorebook' && ref?.id) {
                const key = ref.id;
                const existing = historicalLabels.get(key) || { label: ref.label || 'Entry', count: 0 };
                existing.count += 1;
                historicalLabels.set(key, existing);
            }
        });
    });

    const historicalLines = [...historicalLabels.values()]
        .sort((a, b) => b.count - a.count)
        .slice(0, 3)
        .map(item => `- ${item.label}${item.count > 1 ? ` x${item.count}` : ''}`);

    const liveCandidates = [...new Set(selected.flatMap(msg =>
        (Array.isArray(msg?.triggeredLorebooks) ? msg.triggeredLorebooks : [])
            .map(entry => entry?.name || entry?.label || '')
            .filter(Boolean)
    ))]
        .slice(0, 2)
        .map(label => `- ${label}`);

    const sections = [];
    if (historicalLines.length) {
        sections.push(['Historical triggers:', ...historicalLines].join('\n'));
    }
    if (liveCandidates.length) {
        sections.push(['Current live candidates:', ...liveCandidates].join('\n'));
    }
    return sections.join('\n\n');
}

export function buildMemoryDraftSummaryExcerpt(summary) {
    if (!summary) return '';
    if (typeof summary === 'string') return summary.trim().slice(0, 800);
    if (typeof summary === 'object') {
        if (typeof summary.content === 'string') return summary.content.trim().slice(0, 800);
        return ['timeline', 'characterArcs', 'conflictsThreads', 'notHappenedYet', 'notes']
            .map(key => summary[key])
            .filter(value => typeof value === 'string' && value.trim())
            .join('\n\n')
            .slice(0, 800);
    }
    return '';
}
