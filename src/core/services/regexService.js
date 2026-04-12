import { getEffectivePreset } from '@/core/states/presetState.js';
import { replaceMacros } from '@/utils/macroEngine.js';

function escapeRegex(string) {
    return string.replace(/[/\-\\^$*+?.()|[\]{}]/g, '\\$&');
}

/**
 * Applies a list of regex scripts to a string based on placement and ephemerality filters.
 * 
 * @param {string} text The input text to process.
 * @param {number} placementFilter 1=User Input, 2=AI Output, 3=Slash Commands, 4=World Info, 5=Reasoning.
 * @param {number} ephemeralityFilter 1=Alter Chat Display, 2=Alter Outgoing Prompt.
 * @param {Array} options Extra options { charId, sessionId, globalScripts, char, persona }
 * @returns {string} Processed text.
 */
export function applyRegexes(text, placementFilter, ephemeralityFilter, options = {}) {
    if (!text) return "";
    let processedText = text;

    const { charId, sessionId, globalScripts: providedGlobalScripts, char, persona } = options;

    // Load global scripts if not provided
    let globalScripts = providedGlobalScripts;
    if (!globalScripts) {
        try {
            const stored = localStorage.getItem('regex_scripts');
            globalScripts = stored ? JSON.parse(stored) : [];
        } catch (e) {
            console.error('Failed to load global regex scripts', e);
            globalScripts = [];
        }
    }

    // Load preset scripts if possible
    let presetRegexes = [];
    if (charId && sessionId) {
        const chatId = `${charId}_${sessionId}`;
        const preset = getEffectivePreset(charId, chatId);
        if (preset && preset.regexes) {
            presetRegexes = preset.regexes;
        }
    }

    const allScripts = [...presetRegexes, ...globalScripts];

    for (const script of allScripts) {
        if (script.disabled) continue;

        // Filter by placement
        if (script.placement && !script.placement.includes(placementFilter)) continue;

        // Filter by ephemerality
        if (script.ephemerality && !script.ephemerality.includes(ephemeralityFilter)) continue;

        try {
            let triggered = false;

            // 1. Trim Tokens
            if (script.trimOut) {
                const trimTokens = script.trimOut.split('\n').filter(t => t.trim());
                for (const token of trimTokens) {
                    const before = processedText;
                    processedText = processedText.replace(new RegExp(token, 'g'), '');
                    if (processedText !== before) triggered = true;
                }
            }

            // 2. Regex Pattern
            if (script.regex) {
                let pattern = script.regex;
                let replacement = script.replacement || '';
                let flags = 'g';

                // Handle Macros
                if (script.macroRules && script.macroRules !== '0') {
                    if (script.macroRules === '1') { // Raw
                        pattern = replaceMacros(pattern, char, persona);
                        replacement = replaceMacros(replacement, char, persona);
                    } else if (script.macroRules === '2') { // Escaped
                        // For regex pattern, we must escape the substituted values
                        pattern = pattern.replace(/{{user}}/gi, persona ? escapeRegex(persona.name) : 'User')
                            .replace(/{{char}}/gi, char ? escapeRegex(char.name) : 'Character');
                        // Other macros might still need raw replacement or escaping
                        pattern = replaceMacros(pattern, char, persona);

                        replacement = replaceMacros(replacement, char, persona);
                    }
                }

                // Support /pattern/flags format
                if (pattern.startsWith('/') && pattern.lastIndexOf('/') > 0) {
                    const lastSlash = pattern.lastIndexOf('/');
                    const extractedFlags = pattern.substring(lastSlash + 1);
                    pattern = pattern.substring(1, lastSlash);
                    flags = extractedFlags.includes('g') ? extractedFlags : extractedFlags + 'g';
                }

                const regex = new RegExp(pattern, flags);
                const before = processedText;
                processedText = processedText.replace(regex, replacement);
                if (processedText !== before) triggered = true;
            }

            if (triggered && options.triggeredRegexes) {
                if (!options.triggeredRegexes.some(r => r.id === script.id)) {
                    options.triggeredRegexes.push(script);
                }
            }
        } catch (e) {
            console.error(`Error executing regex script "${script.name}":`, e, script);
        }
    }

    return processedText;
}

// Exports
export function exportSTRegex(script) {
    return {
        id: script.id || Date.now().toString(),
        scriptName: script.name || 'Unnamed Regex',
        findRegex: script.regex || '',
        replaceString: script.replacement || '',
        trimStrings: script.trimOut ? script.trimOut.split('\n').filter(s => s) : [],
        placement: script.placement || [2],
        disabled: script.disabled ?? false,
        markdownOnly: script.ephemerality ? script.ephemerality.includes(1) && !script.ephemerality.includes(2) : (script.markdownOnly ?? false),
        promptOnly: script.ephemerality ? script.ephemerality.includes(2) && !script.ephemerality.includes(1) : (script.promptOnly ?? false),
        runOnEdit: script.runOnEdit ?? false,
        substituteRegex: script.macroRules ? parseInt(script.macroRules) || 0 : 0,
        ephemerality: script.ephemerality || [1, 2],
        minDepth: script.minDepth ?? null,
        maxDepth: script.maxDepth ?? null
    };
}
