export function generateId(length = 6) {
    return Date.now().toString(36) + Math.random().toString(36).substr(2, length);
}

export function detectPresetFormat(data) {
    if (data.tabs && Array.isArray(data.tabs)) return 'latex';
    if (data.prompts && Array.isArray(data.prompts)) return 'sillytavern';
    if (data.blocks && Array.isArray(data.blocks)) return 'glaze';
    return null;
}

export function finalizeImportedPreset(preset) {
    if (!preset.blocks) preset.blocks = [];

    preset.blocks.forEach(b => {
        if (b.id !== 'authors_note' && b.id !== 'summary' && !b.insertion_mode) {
            b.insertion_mode = 'relative';
        }
    });

    if (!preset.blocks.find(b => b.id === 'summary')) {
        const historyIdx = preset.blocks.findIndex(b => b.id === 'chat_history');
        const insertIdx = historyIdx !== -1 ? historyIdx : preset.blocks.length;
        preset.blocks.splice(insertIdx, 0, { id: 'summary', name: 'Summary', role: 'system', content: '', enabled: true, isStatic: true, i18n: 'magic_summary', depth: 4, insertion_mode: 'relative', prefix: 'Summary: ' });
    }
    if (!preset.blocks.find(b => b.id === 'authors_note')) {
        const historyIdx = preset.blocks.findIndex(b => b.id === 'chat_history');
        const insertIdx = historyIdx !== -1 ? historyIdx + 1 : preset.blocks.length;
        preset.blocks.splice(insertIdx, 0, { id: 'authors_note', name: "Author's Note", role: 'system', content: '', enabled: true, isStatic: true, i18n: 'magic_authors_notes', insertion_mode: 'relative' });
    }
    if (!preset.blocks.find(b => b.id === 'guided_generation')) {
        const authorsIdx = preset.blocks.findIndex(b => b.id === 'authors_note');
        const historyIdx = preset.blocks.findIndex(b => b.id === 'chat_history');
        const insertIdx = authorsIdx !== -1 ? authorsIdx + 1 : (historyIdx !== -1 ? historyIdx + 1 : preset.blocks.length);
        preset.blocks.splice(insertIdx, 0, { id: 'guided_generation', name: 'Guided Generation', role: 'system', content: '[System Note: {{guidance}}]', enabled: true, isStatic: true, i18n: 'block_guided_generation', insertion_mode: 'relative' });
    }

    if (!preset.guidedGenerationPrompt) preset.guidedGenerationPrompt = '[Generate your next reply according to these instructions: {{guidance}}]';
    if (!preset.guidedImpersonationPrompt) preset.guidedImpersonationPrompt = '[Instead of replying for {{char}}, impersonate {{user}} according to these instructions: {{guidance}}]';
    if (!preset.summaryPrompt) {
        preset.summaryPrompt = 'Summarize the following roleplay conversation concisely, focusing on the current situation and key events:\n\n{{history}}\n\nSummary:';
    }

    const newId = Date.now().toString();
    preset.id = newId;
    if (preset.createdAt === undefined) preset.createdAt = Date.now();
    return preset;
}

export const mandatoryBlocks = [
    { id: "worldInfoBefore", i18n: "block_wi_before", name: "World Info Before", role: "system", content: "", isStatic: true, enabled: true },
    { id: "user_persona", i18n: "block_user_persona", name: "User Persona", role: "system", content: "", isStatic: true, enabled: true },
    { id: "char_card", i18n: "block_char_card", name: "Character Card", role: "system", content: "", isStatic: true, enabled: true },
    { id: "char_personality", i18n: "block_char_personality", name: "Character Personality", role: "system", content: "", isStatic: true, enabled: true },
    { id: "scenario", i18n: "block_scenario", name: "Scenario", role: "system", content: "", isStatic: true, enabled: true },
    { id: "example_dialogue", i18n: "block_example_dialogue", name: "Dialogue Examples", role: "system", content: "", isStatic: true, enabled: true },
    { id: "worldInfoAfter", i18n: "block_wi_after", name: "World Info After", role: "system", content: "", isStatic: true, enabled: true },
    { id: "chat_history", i18n: "block_chat_history", name: "Chat History", role: "system", content: "", isStatic: true, enabled: true },
    { id: "guided_generation", i18n: "block_guided_generation", name: "Guided Generation", role: "system", content: "[System Note: {{guidance}}]", isStatic: true, enabled: true }
];

const BLOCK_TO_ST_MAP = {
    'user_persona': 'personaDescription',
    'char_card': 'charDescription',
    'char_personality': 'charPersonality',
    'scenario': 'scenario',
    'chat_history': 'chatHistory',
    'example_dialogue': 'dialogueExamples',
    'worldInfoBefore': 'worldInfoBefore',
    'worldInfoAfter': 'worldInfoAfter',
    'guided_generation': 'guided_generation'
};

const ST_TO_BLOCK_MAP = Object.fromEntries(
    Object.entries(BLOCK_TO_ST_MAP).map(([k, v]) => [v, k])
);

export function convertSTPreset(data, fileName) {
    const orderedBlocks = [];
    const usedMandatory = new Set();
    const usedIdentifiers = new Set();

    let orderList = [];
    if (data.prompt_order && Array.isArray(data.prompt_order) && data.prompt_order.length > 0) {
        // Some presets have multiple orders, we take the one with most items or just the first one
        const bestOrder = data.prompt_order.reduce((prev, current) =>
            (current.order.length > prev.order.length) ? current : prev
            , data.prompt_order[0]);
        orderList = bestOrder.order;
    } else if (data.prompts) {
        orderList = data.prompts.map(p => ({ identifier: p.identifier, enabled: p.enabled !== false }));
    }

    const mapToMandatory = (identifier) => {
        return ST_TO_BLOCK_MAP[identifier] || null;
    };

    const processBlock = (item, isStashed = false) => {
        const p = data.prompts.find(p => p.identifier === item.identifier);
        if (!p) return;
        if (['enhanceDefinitions'].includes(item.identifier) && !p.content) return;

        usedIdentifiers.add(item.identifier);

        const isEnabled = isStashed ? false : (item.enabled !== undefined ? item.enabled : (p.enabled !== false));
        const mandatoryId = mapToMandatory(item.identifier);

        if (mandatoryId) {
            if (!usedMandatory.has(mandatoryId)) {
                const mb = mandatoryBlocks.find(b => b.id === mandatoryId);
                if (mb) {
                    orderedBlocks.push({ ...mb, enabled: isEnabled, isStashed: isStashed });
                    usedMandatory.add(mandatoryId);
                    return;
                }
            }
        }

        if (p.content !== undefined && p.content !== null) {
            let insertion_mode = 'relative';
            if (p.injection_position === 1) {
                insertion_mode = 'depth';
            }

            orderedBlocks.push({
                id: p.identifier || Date.now().toString(36) + Math.random().toString(36).substr(2),
                name: p.name || item.identifier,
                content: p.content,
                enabled: isEnabled,
                isStashed: isStashed,
                role: p.role || "system",
                insertion_mode: insertion_mode,
                depth: p.injection_depth !== undefined ? p.injection_depth : 4
            });
        }
    };

    // First pass: Process blocks from order list
    orderList.forEach((item) => processBlock(item));

    // Second pass: Process leftover blocks from data.prompts
    if (data.prompts) {
        data.prompts.forEach((p) => {
            if (!usedIdentifiers.has(p.identifier)) {
                processBlock({ identifier: p.identifier, enabled: false }, true); // Pass true for isStashed
            }
        });
    }

    // Add any remaining mandatory blocks that were never found
    mandatoryBlocks.forEach(mb => {
        if (!usedMandatory.has(mb.id)) {
            orderedBlocks.push({ ...mb });
        }
    });

    // Parse Regex Scripts from ST extensions
    const regexes = data.extensions?.regex_scripts ? data.extensions.regex_scripts.map(r => ({
        id: r.id || Date.now().toString(36) + Math.random().toString(36).substr(2),
        name: r.scriptName || 'Unnamed Regex',
        regex: r.findRegex || '',
        replacement: r.replaceString || '',
        trimOut: Array.isArray(r.trimStrings) ? r.trimStrings.join('\n') : (r.trimStrings || ''),
        placement: r.placement || [2],
        disabled: r.disabled !== undefined ? r.disabled : false,
        markdownOnly: r.markdownOnly || false,
        promptOnly: r.promptOnly || false,
        runOnEdit: r.runOnEdit || false,
        macroRules: (r.substituteRegex || 0).toString(),
        ephemerality: r.ephemerality || (r.markdownOnly === true && r.promptOnly === false ? [1] : r.markdownOnly === false && r.promptOnly === true ? [2] : [1, 2]),
        minDepth: r.minDepth || null,
        maxDepth: r.maxDepth || null
    })) : [];

    return {
        name: fileName || "Imported Preset",
        reasoningEnabled: data.reasoning_enabled || false,
        impersonationPrompt: data.impersonation_prompt || "",
        reasoningStart: data.reasoning_start || "",
        reasoningEnd: data.reasoning_end || "",
        mergePrompts: false,
        mergeRole: 'system',
        blocks: orderedBlocks,
        regexes: regexes
    };
}

export const LATEX_MACRO_DISABLE_MAP = {
    '{bot_persona}': ['char_personality', 'char_card'],
    '{user_persona}': ['user_persona'],
    '{scenario}': ['scenario'],
    '{example_dialogs}': ['example_dialogue'],
    '{lorebooks}': ['worldInfoBefore', 'worldInfoAfter'],
    '{summary}': ['summary', 'authors_note']
};

export function getLatexMacroDisabledBlockIds(content) {
    if (!content) return [];
    const ids = new Set();
    for (const [macro, blockIds] of Object.entries(LATEX_MACRO_DISABLE_MAP)) {
        if (content.includes(macro)) {
            blockIds.forEach(id => ids.add(id));
        }
    }
    return [...ids];
}

export function convertLatexPreset(data, fileName) {
    const orderedBlocks = [];
    const usedMandatory = new Set();
    const disabledNativeIds = new Set();

    const LATEX_TITLE_TO_BLOCK = {
        'persona': 'user_persona',
        'char description': 'char_card',
        'character card': 'char_card',
        'char personality': 'char_personality',
        'character personality': 'char_personality',
        'scenario': 'scenario',
        'world info before': 'worldInfoBefore',
        'world info after': 'worldInfoAfter',
        'chat history': 'chat_history',
        'dialogue examples': 'example_dialogue',
        'example dialogue': 'example_dialogue',
        'author\'s note': 'authors_note',
        'summary': 'summary',
        'guided generation': 'guided_generation'
    };

    const normalizeTitle = (title) => {
        const lower = (title || '').toLowerCase().replace(/[━─🏳️✏️🛑🧑‍🔧🧠🧍📜]/gu, '').trim();
        for (const [key, blockId] of Object.entries(LATEX_TITLE_TO_BLOCK)) {
            if (lower.includes(key)) return blockId;
        }
        return null;
    };

    const tabs = data.tabs || [];

    const LATEX_TO_GLAZE_MACRO = {
        '{bot_persona}': '{{personality}}',
        '{user_persona}': '{{persona}}',
        '{scenario}': '{{scenario}}',
        '{example_dialogs}': '{{mesExamples}}',
        '{lorebooks}': '{{lorebooks}}',
        '{summary}': '{{summary}}'
    };

    const convertLatexMacrosToGlaze = (content) => {
        if (!content) return content;
        let result = content;
        for (const [latex, glaze] of Object.entries(LATEX_TO_GLAZE_MACRO)) {
            result = result.split(latex).join(glaze);
        }
        return result;
    };

    const allTabContent = tabs.map(t => t.content || '').join('\n');
    const macroReferencedBlockIds = getLatexMacroDisabledBlockIds(allTabContent);

    tabs.forEach((tab) => {
        const tabId = tab.id || generateId();
        const tabTitle = tab.title || '';
        const tabContent = convertLatexMacrosToGlaze(tab.content || '');
        const tabRole = tab.role || 'system';
        const tabEnabled = tab.enabled !== undefined ? tab.enabled : true;
        const tabDepth = tab.injectionDepth || 0;

        const mandatoryMatch = normalizeTitle(tabTitle);

        if (mandatoryMatch === 'chat_history') {
            usedMandatory.add('chat_history');
            const mb = mandatoryBlocks.find(b => b.id === 'chat_history');
            if (mb) orderedBlocks.push({ ...mb });
            return;
        }

        if (mandatoryMatch && !usedMandatory.has(mandatoryMatch)) {
            disabledNativeIds.add(mandatoryMatch);
            usedMandatory.add(mandatoryMatch);
        }

        let insertion_mode = 'relative';
        let depth = 4;
        if (tabDepth > 0) {
            insertion_mode = 'depth';
            depth = tabDepth;
        }

        orderedBlocks.push({
            id: tabId,
            name: tabTitle,
            content: tabContent,
            enabled: tabEnabled,
            isStashed: false,
            role: tabRole,
            insertion_mode,
            depth
        });
    });

    macroReferencedBlockIds.forEach(blockId => {
        if (blockId === 'chat_history') return;
        if (!usedMandatory.has(blockId)) {
            disabledNativeIds.add(blockId);
            usedMandatory.add(blockId);
        }
    });

    mandatoryBlocks.forEach(mb => {
        if (disabledNativeIds.has(mb.id)) {
            orderedBlocks.push({ ...mb, enabled: false, isStashed: false });
        } else if (!usedMandatory.has(mb.id)) {
            orderedBlocks.push({ ...mb });
        }
    });

    const EXTRA_DISABLED_BLOCKS = {
        'authors_note': { id: 'authors_note', name: "Author's Note", role: 'system', content: '', isStatic: true, i18n: 'magic_authors_notes', enabled: false, isStashed: false, insertion_mode: 'relative' },
        'summary': { id: 'summary', name: 'Summary', role: 'system', content: '', isStatic: true, i18n: 'magic_summary', enabled: false, isStashed: false, depth: 4, insertion_mode: 'relative', prefix: 'Summary: ' }
    };
    for (const [blockId, blockDef] of Object.entries(EXTRA_DISABLED_BLOCKS)) {
        if (disabledNativeIds.has(blockId)) {
            orderedBlocks.push({ ...blockDef });
        }
    }

    return {
        name: data.name || fileName || "Imported Preset",
        reasoningEnabled: false,
        impersonationPrompt: "",
        reasoningStart: "",
        reasoningEnd: "",
        mergePrompts: !!data.mergeConsecutiveRoles,
        mergeRole: 'system',
        blocks: orderedBlocks,
        regexes: [],
        disabledNativeIds: [...disabledNativeIds]
    };
}

export function exportSTPreset(preset) {
    const data = {
        name: preset.name || "Exported Preset",
        reasoning_enabled: preset.reasoningEnabled || false,
        impersonation_prompt: preset.impersonationPrompt || "",
        reasoning_start: preset.reasoningStart || "",
        reasoning_end: preset.reasoningEnd || "",
        prompts: [],
        prompt_order: [
            {
                character_id: 100000,
                order: [
                    { identifier: "main", enabled: true },
                    { identifier: "worldInfoBefore", enabled: true },
                    { identifier: "charDescription", enabled: true },
                    { identifier: "charPersonality", enabled: true },
                    { identifier: "scenario", enabled: true },
                    { identifier: "enhanceDefinitions", enabled: false },
                    { identifier: "nsfw", enabled: true },
                    { identifier: "worldInfoAfter", enabled: true },
                    { identifier: "dialogueExamples", enabled: true },
                    { identifier: "chatHistory", enabled: true },
                    { identifier: "jailbreak", enabled: true }
                ]
            },
            {
                character_id: 100001,
                order: []
            }
        ],
        extensions: {
            regex_scripts: []
        }
    };

    if (preset.blocks) {
        preset.blocks.forEach((b) => {
            const identifier = BLOCK_TO_ST_MAP[b.id] || b.id;

            const enabled = b.enabled !== undefined ? b.enabled : true;
            const isMarker = !!b.isStatic || !!ST_TO_BLOCK_MAP[identifier];
            const isSystem = isMarker || ["main", "nsfw", "jailbreak", "enhanceDefinitions"].includes(identifier);

            const promptObj = {
                id: identifier,
                identifier: identifier,
                name: b.name || identifier,
                system_prompt: isSystem,
                marker: isMarker,
                enabled: enabled
            };

            if (!isMarker) {
                promptObj.content = b.content || "";
                promptObj.role = b.role || "system";
                promptObj.injection_position = b.insertion_mode === 'depth' ? 1 : 0;
                promptObj.injection_depth = b.depth !== undefined ? b.depth : 4;
            }

            data.prompts.push(promptObj);

            if (!b.isStashed) {
                data.prompt_order[1].order.push({
                    identifier: identifier,
                    enabled: enabled
                });
            }
        });

        // Add worldInfoBefore and worldInfoAfter if missing, as ST expects them
        const orderIds = data.prompt_order[1].order.map(o => o.identifier);

        if (!orderIds.includes('worldInfoBefore')) {
            data.prompts.push({ identifier: "worldInfoBefore", name: "World Info (before)", system_prompt: true, marker: true, enabled: true });
            data.prompt_order[1].order.splice(1, 0, { identifier: "worldInfoBefore", enabled: true });
        }
        if (!orderIds.includes('worldInfoAfter')) {
            data.prompts.push({ identifier: "worldInfoAfter", name: "World Info (after)", system_prompt: true, marker: true, enabled: true });
            // Insert before chatHistory if possible, otherwise at the end
            const chatHistoryIndex = data.prompt_order[1].order.findIndex(o => o.identifier === 'chatHistory');
            const insertIdx = chatHistoryIndex !== -1 ? chatHistoryIndex : data.prompt_order[1].order.length;
            data.prompt_order[1].order.splice(insertIdx, 0, { identifier: "worldInfoAfter", enabled: true });
        }
    }

    if (preset.regexes) {
        data.extensions.regex_scripts = preset.regexes.map(r => ({
            id: r.id,
            scriptName: r.name || "Unnamed Regex",
            findRegex: r.regex || "",
            replaceString: r.replacement || "",
            trimStrings: r.trimOut ? r.trimOut.split('\n') : [],
            placement: r.placement || [2],
            disabled: r.disabled !== undefined ? r.disabled : false,
            markdownOnly: r.ephemerality ? r.ephemerality.includes(1) && !r.ephemerality.includes(2) : (r.markdownOnly !== undefined ? r.markdownOnly : false),
            promptOnly: r.ephemerality ? r.ephemerality.includes(2) && !r.ephemerality.includes(1) : (r.promptOnly !== undefined ? r.promptOnly : false),
            runOnEdit: r.runOnEdit !== undefined ? r.runOnEdit : false,
            substituteRegex: r.macroRules ? parseInt(r.macroRules) || 0 : 0,
            ephemerality: r.ephemerality || [1, 2],
            minDepth: r.minDepth || null,
            maxDepth: r.maxDepth || null
        }));
    }

    return data;
}
