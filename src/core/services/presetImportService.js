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
        if (identifier === 'personaDescription') return 'user_persona';
        if (identifier === 'charDescription') return 'char_card';
        if (identifier === 'charPersonality') return 'char_personality';
        if (identifier === 'scenario') return 'scenario';
        if (identifier === 'chatHistory') return 'chat_history';
        if (identifier === 'dialogueExamples') return 'example_dialogue';
        if (identifier === 'worldInfoBefore') return 'worldInfoBefore';
        if (identifier === 'worldInfoAfter') return 'worldInfoAfter';
        return null;
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
        runOnEdit: r.runOnEdit || false,
        macroRules: (r.substituteRegex || 0).toString(),
        ephemerality: [1, 2], // Hardcoded default based on ST behavior if not provided
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
            let identifier = b.id;
            if (b.id === 'user_persona') identifier = 'personaDescription';
            else if (b.id === 'char_card') identifier = 'charDescription';
            else if (b.id === 'char_personality') identifier = 'charPersonality';
            else if (b.id === 'scenario') identifier = 'scenario';
            else if (b.id === 'chat_history') identifier = 'chatHistory';
            else if (b.id === 'example_dialogue') identifier = 'dialogueExamples';

            const enabled = b.enabled !== undefined ? b.enabled : true;
            const isMarker = !!b.isStatic || ["personaDescription", "charDescription", "charPersonality", "scenario", "chatHistory", "dialogueExamples", "worldInfoBefore", "worldInfoAfter"].includes(identifier);
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

            data.prompt_order[1].order.push({
                identifier: identifier,
                enabled: enabled
            });
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
            markdownOnly: r.markdownOnly !== undefined ? r.markdownOnly : false,
            runOnEdit: r.runOnEdit !== undefined ? r.runOnEdit : false,
            substituteRegex: r.macroRules ? parseInt(r.macroRules) || 0 : 0,
            ephemerality: r.ephemerality || [1, 2],
            minDepth: r.minDepth || null,
            maxDepth: r.maxDepth || null
        }));
    }

    return data;
}
