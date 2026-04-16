import { replaceMacros } from '../utils/macroEngine.js';
import { normalizeBlockId } from '../utils/presetBlockIds.js';

let GPTTokenizer = null;
const isIOS = typeof navigator !== 'undefined' && /iPad|iPhone|iPod/.test(navigator.userAgent);

if (!isIOS) {
    // Dynamic import to avoid stack overflow on iOS during worker initialization
    import('../tokenizers/gp-tokenizer-9KQssiTx.js').then(module => {
        GPTTokenizer = module.T;
    }).catch(err => {
        console.error("Worker: Failed to load tokenizer:", err);
    });
}

/**
 * Strips embedded base64 media from text so it doesn't inflate token counts.
 * LLM responses may contain HTML blocks with massive data:image/... URIs
 * (hundreds of KB of base64) that are rendered visually but should not count
 * toward the context window.
 */
function stripEmbeddedMedia(text) {
    if (!text || text.length < 256) return text;
    // Remove <img> tags whose src is a data URI
    let cleaned = text.replace(/<img\s[^>]*src\s*=\s*["']data:image\/[^"']{256,}["'][^>]*\/?>/gi, '');
    // Remove bare data:image/...base64,... URIs (>256 chars to avoid false positives)
    cleaned = cleaned.replace(/data:image\/[a-z+]+;base64,[A-Za-z0-9+/=\n\r]{256,}/gi, '');
    return cleaned;
}

function estimateTokens(text) {
    if (!text) return 0;
    const cleaned = stripEmbeddedMedia(text);
    if (GPTTokenizer && typeof GPTTokenizer.countTokens === 'function') {
        try {
            return GPTTokenizer.countTokens(cleaned);
        } catch (e) {
            // Fallback for any errors during full tokenization
        }
    }
    // Lightweight heuristic fallback
    return Math.ceil(cleaned.length / 3.35);
}

function getLorebookReserve(globalSettings, safeContext) {
    const mode = globalSettings?.reserveMode || 'tokens';
    const rawValue = Number(globalSettings?.reserveValue || 0);
    if (!Number.isFinite(rawValue) || rawValue <= 0) return 0;

    if (mode === 'percent') {
        return Math.max(0, Math.floor((safeContext * rawValue) / 100));
    }

    return Math.max(0, Math.floor(rawValue));
}

function escapeRegex(string) {
    return string.replace(/[/\-\\^$*+?.()|[\]{}]/g, '\\$&');
}

const GLAZE_BOUNDARIES = '[\\s.,!?;:"\'\\u201C\\u201D\\u2018\\u2019\\u00AB\\u00BB(){}\\[\\]—–]';

function sanitizeRegexFlags(flags) {
    const valid = new Set(['g', 'i', 'm', 's', 'u', 'y']);
    let out = '';
    for (const ch of (flags || '')) {
        if (valid.has(ch) && !out.includes(ch)) out += ch;
    }
    if (!out.includes('g')) out += 'g';
    return out;
}

function tryCreateRegex(pattern, flags = 'g') {
    if (pattern === undefined || pattern === null) return null;
    const strPattern = `${pattern}`;
    if (!strPattern) return null;
    try {
        return new RegExp(strPattern, sanitizeRegexFlags(flags));
    } catch (e) {
        return null;
    }
}


function applyRegexes(text, placementFilter, ephemeralityFilter, allScripts, options = {}) {
    if (!text) return "";
    let processedText = text;
    const { char, persona, sessionVars, notifyObj } = options;

    for (const script of allScripts) {
        if (script.disabled) continue;
        if (script.placement && !script.placement.includes(placementFilter)) continue;
        if (script.ephemerality && !script.ephemerality.includes(ephemeralityFilter)) continue;

        try {
            if (script.trimOut) {
                const trimTokens = script.trimOut.split('\n').filter(t => t.trim());
                for (const token of trimTokens) {
                    const trimRegex = tryCreateRegex(token, 'g');
                    if (trimRegex) {
                        processedText = processedText.replace(trimRegex, '');
                    } else {
                        processedText = processedText.split(token).join('');
                    }
                }
            }

            if (script.regex) {
                let pattern = script.regex;
                let replacement = script.replacement || '';
                let flags = 'g';

                // Handle Macros
                if (script.macroRules && script.macroRules !== '0') {
                    if (script.macroRules === '1') { // Raw
                        pattern = replaceMacros(pattern, char, persona, sessionVars, notifyObj);
                        replacement = replaceMacros(replacement, char, persona, sessionVars, notifyObj);
                    } else if (script.macroRules === '2') { // Escaped
                        pattern = pattern.replace(/{{user}}/gi, persona ? escapeRegex(persona.name) : 'User')
                            .replace(/{{char}}/gi, char ? escapeRegex(char.name) : 'Character');
                        pattern = replaceMacros(pattern, char, persona, sessionVars, notifyObj);
                        replacement = replaceMacros(replacement, char, persona, sessionVars, notifyObj);
                    }
                }

                // Support /pattern/flags format
                if (pattern.startsWith('/') && pattern.lastIndexOf('/') > 0) {
                    const lastSlash = pattern.lastIndexOf('/');
                    const extractedFlags = pattern.substring(lastSlash + 1);
                    pattern = pattern.substring(1, lastSlash);
                    flags = extractedFlags.includes('g') ? extractedFlags : extractedFlags + 'g';
                }

                const regex = tryCreateRegex(pattern, flags);
                if (regex) {
                    processedText = processedText.replace(regex, replacement);
                } else if (pattern) {
                    // Safe literal fallback for invalid/pathological regex on iOS
                    processedText = processedText.split(pattern).join(replacement);
                }
            }
        } catch (e) {
            // Ignore regex errors in worker
        }
    }

    return processedText;
}

function scanLorebooksPure(history, char, textToScan, chatId, lorebooks, globalSettings, activations) {
    const charId = char?.id;

    const activeLorebooks = lorebooks.filter(lb => {
        if (lb.enabled) return true;
        if (charId && activations?.character?.[charId]?.includes(lb.id)) return true;
        if (chatId && activations?.chat?.[chatId]?.includes(lb.id)) return true;
        return false;
    });

    if (activeLorebooks.length === 0) return [];

    let allRelevantEntries = [];
    let candidates = [];

    activeLorebooks.forEach(lb => {
        lb.entries.forEach(entry => {
            if (entry.enabled !== false && !entry.vectorSearch) {
                if (char && entry.characterFilter) {
                    const { isExclude, names } = entry.characterFilter;
                    if (names && names.length > 0) {
                        const charName = (char.name || "").toLowerCase();
                        const isInCategory = names.some(n => charName.includes(n.toLowerCase()));
                        if (isExclude && isInCategory) return;
                        if (!isExclude && !isInCategory) return;
                    }
                }
                candidates.push({ ...entry, lorebookName: lb.name, lorebookId: lb.id });
            }
        });
    });

    candidates.filter(e => e.constant).forEach(entry => {
        if (!allRelevantEntries.some(e => e.id === entry.id)) {
            allRelevantEntries.push(entry);
        }
    });

    let changed = true;
    let iteration = 0;
    const maxIterations = (globalSettings.recursiveScan === false) ? 1 : 5;

    while (changed && iteration < maxIterations) {
        changed = false;
        iteration++;

        for (const entry of candidates) {
            if (allRelevantEntries.some(e => e === entry)) continue;
            if (entry.constant) continue;

            const primaryKeys = entry.keys || [];
            const secondaryKeys = (entry.secondary_keys || entry.keysecondary) || [];
            const logic = entry.selectiveLogic ?? 5;

            const caseSensitive = entry.caseSensitive ?? globalSettings.caseSensitive ?? false;
            const wholeWords = entry.matchWholeWords ?? globalSettings.matchWholeWords ?? false;

            const checkMatch = (key, text) => {
                if (!key) return false;
                const sourceText = `${text ?? ''}`;
                const sourceKey = `${key}`;
                const flags = caseSensitive ? '' : 'i';

                if (wholeWords === 'glaze') {
                    const escaped = escapeRegex(sourceKey);
                    const pattern = `(?:^|${GLAZE_BOUNDARIES})${escaped}(?:$|${GLAZE_BOUNDARIES})`;
                    const regex = tryCreateRegex(pattern, flags);
                    if (regex) return regex.test(sourceText);
                    const haystack = caseSensitive ? sourceText : sourceText.toLowerCase();
                    const needle = caseSensitive ? sourceKey : sourceKey.toLowerCase();
                    if (!needle) return false;
                    const escapedNeedle = escapeRegex(needle);
                    const fallback = tryCreateRegex(`(?:^|${GLAZE_BOUNDARIES})${escapedNeedle}(?:$|${GLAZE_BOUNDARIES})`, caseSensitive ? '' : 'i');
                    return fallback ? fallback.test(haystack) : false;
                }

                let pattern = sourceKey;
                if (wholeWords) pattern = `\\b${pattern}\\b`;

                const regex = tryCreateRegex(pattern, flags);
                if (regex) {
                    return regex.test(sourceText);
                }

                const haystack = caseSensitive ? sourceText : sourceText.toLowerCase();
                const needle = caseSensitive ? sourceKey : sourceKey.toLowerCase();
                if (!needle) return false;

                if (wholeWords) {
                    const escaped = escapeRegex(needle);
                    const wordRegex = tryCreateRegex(`\\b${escaped}\\b`, caseSensitive ? '' : 'i');
                    if (wordRegex) return wordRegex.test(haystack);
                }

                return haystack.includes(needle);
            };

            const scanDepth = entry.scanDepth ?? 1;
            const messagesToScan = history.slice(-scanDepth).map(m => m.content).join("\n");

            const scanSource = caseSensitive ?
                (messagesToScan + textToScan) :
                (messagesToScan.toLowerCase() + textToScan.toLowerCase());

            let isStickyActive = false;
            let isOnCooldown = false;

            if (entry.sticky > 0 || entry.cooldown > 0) {
                for (let i = 1; i <= Math.max(entry.sticky || 0, entry.cooldown || 0); i++) {
                    const histMsg = history[history.length - i];
                    if (!histMsg) break;
                    const histSource = caseSensitive ? histMsg.content : histMsg.content.toLowerCase();
                    const wasMatched = primaryKeys.some(key => checkMatch(key, histSource));

                    if (wasMatched) {
                        if (i <= (entry.sticky || 0)) isStickyActive = true;
                        if (i <= (entry.cooldown || 0)) isOnCooldown = true;
                        break;
                    }
                }
            }

            if (isOnCooldown) continue;

            const matchedPrimary = isStickyActive || primaryKeys.some(key => checkMatch(key, scanSource));

            if (matchedPrimary) {
                let secondaryMatches = true;

                if (logic === 4 || secondaryKeys.length === 0) {
                    secondaryMatches = true;
                } else if (secondaryKeys.length > 0) {
                    const matches = secondaryKeys.map(key => checkMatch(key, scanSource));
                    const anyMatch = matches.some(m => m);
                    const allMatch = matches.every(m => m);

                    if (logic === 0) secondaryMatches = anyMatch;
                    else if (logic === 1) secondaryMatches = allMatch;
                    else if (logic === 2) secondaryMatches = !anyMatch;
                    else if (logic === 3) secondaryMatches = !allMatch;
                }

                if (secondaryMatches) {
                    if (entry.probability !== undefined && entry.probability < 100) {
                        if (Math.random() * 100 > entry.probability) continue;
                    }

                    allRelevantEntries.push(entry);

                    if (!entry.preventRecursion && iteration < maxIterations) {
                        textToScan += "\n" + (entry.content || "").toLowerCase();
                        changed = true;
                    }
                }
            }
        }
    }

    return allRelevantEntries.sort((a, b) => (a.order ?? 100) - (b.order ?? 100));
}

function squashHistory(historyMsgs, squashRole) {
    if (!squashRole) return historyMsgs;
    const result = [];
    for (const msg of historyMsgs) {
        const last = result[result.length - 1];
        if (last && last.role === squashRole && msg.role === squashRole) {
            last.content += '\n' + msg.content;
        } else {
            result.push({ ...msg });
        }
    }
    return result;
}

function buildNoAssistantHistory(historyMsgs, userPrefix, charPrefix, squashRole) {
    const squashed = squashHistory(historyMsgs, squashRole);
    const lines = squashed.map(m => {
        const prefix = m.role === 'user' ? (userPrefix || '') : (charPrefix || '');
        return prefix + m.content;
    });
    return lines.join('\n');
}

function buildBlockSourceReplacements(char, personaObj, sessionVars, notifyObj, summaryRawContent, getLorebookContent) {
    return [
        { macro: '{{description}}', replacement: char?.description || char?.desc || '', source: 'character' },
        { macro: '{{scenario}}', replacement: char?.scenario || '', source: 'character' },
        { macro: '{{personality}}', replacement: char?.personality || '', source: 'character' },
        { macro: '{{mesExamples}}', replacement: char?.mes_example || '', source: 'character' },
        { macro: '{{summary}}', replacement: summaryRawContent || '', source: 'summary' },
        { macro: '{{lorebooks}}', replacement: getLorebookContent(), source: 'lorebook' }
    ];
}

function buildPromptMessagesWorker(args) {
    let { char, history, summary, activePreset, mergePrompts, mergeRole, noAssistant, userPrefix, charPrefix, squashRole, personaObj, authorsNote, guidanceText, guidanceType, lorebooks, globalSettings, activations, globalRegexes, sessionVars } = args;
    if (noAssistant) mergePrompts = true;

    const messages = [];
    let mergeSourcesBuffer = [];
    let mergeContentBuffer = [];
    let allLoreEntries = [];
    let notifyObj = { varsChanged: false };

    const charId = char?.id || "default";
    const sessionId = char?.sessionId || "current";
    const chatId = char?.id && char?.sessionId ? `${char.id}_${char.sessionId}` : null;

    const presetRegexes = activePreset?.regexes || [];
    const allScripts = [...presetRegexes, ...globalRegexes];

    const flushMergeBuffer = () => {
        if (mergeContentBuffer.length > 0) {
            const content = mergeContentBuffer.join('\n');
            const sources = [];
            for (const s of mergeSourcesBuffer) {
                const existing = sources.find(x => x.source === s.source);
                if (existing) existing.tokens += s.tokens;
                else sources.push({ ...s });
            }
            messages.push({
                role: mergeRole || 'system',
                content,
                blockName: 'merged prompt',
                sources,
                _allSources: mergeSourcesBuffer.slice()
            });
            mergeContentBuffer = [];
            mergeSourcesBuffer = [];
        }
    };

    const combineSources = (sourceItems = []) => {
        const combined = [];
        for (const s of sourceItems) {
            if (!s || !s.source) continue;
            const existing = combined.find(x => x.source === s.source);
            if (existing) existing.tokens += s.tokens || 0;
            else combined.push({ source: s.source, tokens: s.tokens || 0 });
        }
        return combined;
    };

    let loreByPosition = { worldInfoBefore: [], worldInfoAfter: [], lorebooksMacro: [] };
    if (lorebooks) {
        const loreEntries = scanLorebooksPure(history || [], char, "", chatId, lorebooks, globalSettings, activations);
        allLoreEntries = loreEntries;

        loreEntries.forEach(entry => {
            const pos = entry.position === 'matchGlobal'
                ? (globalSettings?.injectionPosition || 'worldInfoBefore')
                : (entry.position || 'worldInfoBefore');
            const content = replaceMacros(entry.content || "", char, personaObj, sessionVars, notifyObj);
            const tokens = estimateTokens(content);
            const msg = {
                role: 'system',
                content,
                blockName: `Lorebook: ${entry.comment || entry.keys?.[0] || 'Entry'}`,
                isLorebook: true,
                sources: tokens > 0 ? [{ source: 'lorebook', tokens }] : [],
                _allSources: tokens > 0 ? [{ source: 'lorebook', tokens }] : []
            };
            if (loreByPosition[pos]) loreByPosition[pos].push(msg);
            else loreByPosition.worldInfoBefore.push(msg);
        });
    }

    const getLorebookContent = () => {
        return allLoreEntries
            .map(entry => replaceMacros(entry.content || "", char, personaObj, sessionVars, notifyObj))
            .filter(Boolean)
            .join('\n\n');
    };

    const injectLore = (pos) => {
        if (loreByPosition[pos] && loreByPosition[pos].length > 0) {
            if (mergePrompts) {
                loreByPosition[pos].forEach(msg => {
                    mergeContentBuffer.push(msg.content);
                    if (msg._allSources) mergeSourcesBuffer.push(...msg._allSources);
                });
            } else {
                flushMergeBuffer();
                const combinedContent = loreByPosition[pos].map(msg => msg.content).filter(Boolean).join('\n\n');
                const combinedSources = combineSources(loreByPosition[pos].flatMap(msg => msg._allSources || msg.sources || []));
                if (combinedContent) {
                    messages.push({
                        role: 'system',
                        content: combinedContent,
                        blockName: pos === 'worldInfoAfter' ? 'Lorebook After' : 'Lorebook Before',
                        isLorebook: true,
                        sources: combinedSources,
                        _allSources: combinedSources
                    });
                }
            }
            loreByPosition[pos] = [];
        }
    };

    injectLore('worldInfoBefore');

    let summaryRawContent = null;
    let summaryText = null;
    if (summary) {
        summaryRawContent = typeof summary === 'object' ? summary.content : summary;
        const prefix = (typeof summary === 'object' && summary.prefix) ? summary.prefix : 'Summary: ';
        if (summaryRawContent) summaryText = `[${prefix}${summaryRawContent}]`;
    }

    if (activePreset && activePreset.blocks) {
        const depthBlocks = [];
        const relativeBlocks = [];

        activePreset.blocks.forEach(block => {
            if (!block.enabled || block.isStashed) return;
            const normalizedId = normalizeBlockId(block.id);
            const normalizedBlock = normalizedId === block.id
                ? block
                : { ...block, id: normalizedId, originalId: block.id };
            if (normalizedBlock.insertion_mode === 'depth' && normalizedBlock.id !== 'chat_history') {
                depthBlocks.push(normalizedBlock);
            } else {
                relativeBlocks.push(normalizedBlock);
            }
        });

        const resolveDynamicMacros = (text) => {
            if (!text) return text;
            let result = text;
            if (result.includes('{{lorebooks}}')) {
                result = result.split('{{lorebooks}}').join(getLorebookContent());
            }
            if (result.includes('{{summary}}')) {
                result = result.split('{{summary}}').join(summaryRawContent || '');
            }
            return result;
        };

        const resolveBlockContent = (block) => {
            let content = "";
            let role = block.role || "system";
            let primarySource = 'preset';

            if (block.id === 'guided_generation') {
                const isImpersonation = guidanceType === 'impersonation';
                if (!guidanceText && !isImpersonation) return null;
                const template = isImpersonation
                    ? (activePreset?.guidedImpersonationPrompt || '[Instead of replying for {{char}}, impersonate {{user}} according to these instructions: {{guidance}}]')
                    : (activePreset?.guidedGenerationPrompt || '[Generate your next reply according to these instructions: {{guidance}}]');
                content = template.replace(/\{\{guidance\}\}/gi, guidanceText || '');
            }
            else if (block.id === 'user_persona') {
                content = `User Name: ${personaObj.name}\nUser Description: ${personaObj.prompt || ""}`;
                primarySource = 'preset';
            }
            else if (block.id === 'char_card') {
                content = `Character Name: ${char.name}\nDescription: ${char.description || char.desc}`;
                primarySource = 'character';
            }
            else if (block.id === 'char_personality') {
                content = `Personality: ${char.personality}`;
                primarySource = 'character';
            }
            else if (block.id === 'scenario') {
                content = `Scenario: ${char.scenario}`;
                primarySource = 'character';
            }
            else if (block.id === 'example_dialogue') {
                content = char.mes_example || "";
                primarySource = 'character';
            }
            else if (block.id === 'authors_note') {
                if (authorsNote && authorsNote.content) {
                    content = authorsNote.content;
                    if (authorsNote.role) role = authorsNote.role;
                    primarySource = 'authorsNote';
                } else return null;
            }
            else if (block.id === 'summary') {
                if (summaryText) {
                    content = summaryText;
                    if (typeof summary === 'object' && summary.role) role = summary.role;
                    primarySource = 'summary';
                } else return null;
            } else {
                content = block.content;
            }

            if (!content) return null;

            const sourceMacros = [
                { regex: /\{\{description\}\}/gi, value: char?.description || char?.desc || '', source: 'character' },
                { regex: /\{\{scenario\}\}/gi, value: char?.scenario || '', source: 'character' },
                { regex: /\{\{personality\}\}/gi, value: char?.personality || '', source: 'character' },
                { regex: /\{\{mesExamples\}\}/gi, value: char?.mes_example || '', source: 'character' },
                { regex: /\{\{summary\}\}/gi, value: summaryRawContent || '', source: 'summary' },
                { regex: /\{\{lorebooks\}\}/gi, value: getLorebookContent(), source: 'lorebook' }
            ];

            const sources = [];
            let literalTemplate = content;
            for (const sm of sourceMacros) {
                const matches = content.match(sm.regex);
                if (matches && matches.length > 0) {
                    const tokens = estimateTokens(sm.value) * matches.length;
                    if (tokens > 0) sources.push({ source: sm.source, tokens });
                    literalTemplate = literalTemplate.replace(sm.regex, '');
                }
            }

            content = replaceMacros(content, char, personaObj, sessionVars, notifyObj);
            literalTemplate = replaceMacros(literalTemplate, char, personaObj, sessionVars, notifyObj);

            if (content.includes('{{lorebooks}}')) {
                content = content.split('{{lorebooks}}').join(getLorebookContent());
            }
            if (content.includes('{{summary}}')) {
                content = content.split('{{summary}}').join(summaryRawContent || '');
            }

            const literalTokens = estimateTokens(literalTemplate);
            if (literalTokens > 0) {
                sources.push({ source: primarySource, tokens: literalTokens });
            } else if (sources.length === 0) {
                const totalTokens = estimateTokens(content);
                if (totalTokens > 0) {
                    sources.push({ source: primarySource, tokens: totalTokens });
                }
            }

            return { content, role, sources, primarySource };
        };

        const resolvedDepthBlocks = depthBlocks.map(block => {
            const resolved = resolveBlockContent(block);
            if (!resolved) return null;

            let placement = 4;
            if (resolved.role === 'user') placement = 1;
            else if (resolved.role === 'assistant') placement = 2;

            const preRegexTokens = estimateTokens(resolved.content);
            resolved.content = applyRegexes(resolved.content, placement, 2, allScripts, { char, persona: personaObj, sessionVars, charId, sessionId, notifyObj });
            const postRegexTokens = estimateTokens(resolved.content);

            if (preRegexTokens > 0 && postRegexTokens > 0 && resolved.sources.length > 0) {
                const scale = postRegexTokens / preRegexTokens;
                resolved.sources = resolved.sources.map(s => ({ source: s.source, tokens: Math.max(0, Math.round(s.tokens * scale)) }));
            } else if (postRegexTokens > 0) {
                resolved.sources = [{ source: resolved.primarySource, tokens: postRegexTokens }];
            } else {
                resolved.sources = [];
            }

            return {
                role: resolved.role,
                content: resolved.content,
                blockName: block.name,
                blockId: block.id,
                sources: resolved.sources,
                _allSources: resolved.sources,
                depth: block.depth || 0,
                isDepth: true
            };
        }).filter(Boolean);

        relativeBlocks.forEach(block => {
            if (block.id === 'chat_history') {
                if (mergePrompts) flushMergeBuffer();
                injectLore('worldInfoAfter');

                let historyMsgs = [];
                if (history) {
                    historyMsgs = history.map((m, i) => {
                        let content = m.content !== undefined ? m.content : (m.text || m.mes || "");

                        content = replaceMacros(content, char, personaObj, sessionVars, notifyObj);
                        const placement = m.role === 'user' ? 1 : 2;
                        content = applyRegexes(content, placement, 2, allScripts, { char, persona: personaObj, sessionVars, charId, sessionId, notifyObj });

                        const tokens = estimateTokens(content);
                        return {
                            role: m.role || (m.isUser ? 'user' : 'assistant'),
                            content: content,
                            image: m.image,
                            isHistory: true,
                            chatId: m.chatId !== undefined ? m.chatId : (m.originalIndex !== undefined ? m.originalIndex : i),
                            sources: tokens > 0 ? [{ source: 'history', tokens }] : [],
                            _allSources: tokens > 0 ? [{ source: 'history', tokens }] : []
                        };
                    });
                }

                if (noAssistant) {
                    const combinedContent = buildNoAssistantHistory(historyMsgs, userPrefix, charPrefix, squashRole);
                    if (combinedContent) {
                        const tokens = estimateTokens(combinedContent);
                        messages.push({
                            role: 'assistant',
                            content: combinedContent,
                            blockName: 'chat_history',
                            isHistory: true,
                            sources: tokens > 0 ? [{ source: 'history', tokens }] : [],
                            _allSources: tokens > 0 ? [{ source: 'history', tokens }] : []
                        });
                    }
                    return;
                }

                const finalHistoryWithDepth = [];
                const deepBlocks = resolvedDepthBlocks.filter(b => b.depth > historyMsgs.length);
                for (const b of deepBlocks) finalHistoryWithDepth.push(b);

                for (let i = 0; i <= historyMsgs.length; i++) {
                    const currentDepth = historyMsgs.length - i;
                    const blocksAtDepth = resolvedDepthBlocks.filter(b => b.depth === currentDepth);
                    for (const b of blocksAtDepth) finalHistoryWithDepth.push(b);

                    if (i < historyMsgs.length) {
                        finalHistoryWithDepth.push(historyMsgs[i]);
                    }
                }

                for (const m of finalHistoryWithDepth) messages.push(m);
                return;
            }

            if (block.id === 'char_card') injectLore('worldInfoBefore');

            const resolved = resolveBlockContent(block);
            if (!resolved) {
                if (block.id === 'char_card') injectLore('worldInfoAfter');
                return;
            }

            let { content, role, sources, primarySource } = resolved;

            if (mergePrompts && role !== 'assistant') {
                if (content) {
                    mergeContentBuffer.push(content);
                    if (sources) mergeSourcesBuffer.push(...sources);
                }
            } else {
                if (mergePrompts) flushMergeBuffer();

                let placement = 4;
                if (role === 'user') placement = 1;
                else if (role === 'assistant') placement = 2;

                const preRegexTokens = estimateTokens(content);
                content = applyRegexes(content, placement, 2, allScripts, { char, persona: personaObj, sessionVars, charId, sessionId, notifyObj });
                const postRegexTokens = estimateTokens(content);

                if (preRegexTokens > 0 && postRegexTokens > 0 && sources.length > 0) {
                    const scale = postRegexTokens / preRegexTokens;
                    sources = sources.map(s => ({ source: s.source, tokens: Math.max(0, Math.round(s.tokens * scale)) }));
                } else if (postRegexTokens > 0) {
                    sources = [{ source: primarySource, tokens: postRegexTokens }];
                } else {
                    sources = [];
                }

                if (content.includes('{{lorebooks}}')) {
                    content = content.split('{{lorebooks}}').join(
                        loreByPosition.lorebooksMacro.map(item => item.content).filter(Boolean).join('\n\n')
                    );
                    loreByPosition.lorebooksMacro = [];
                }

                const msg = {
                    role: role,
                    content: content,
                    blockName: block.name,
                    blockId: block.id,
                    sources,
                    _allSources: sources
                };
                messages.push(msg);
            }

            if (block.id === 'char_card') injectLore('worldInfoAfter');
        });
        if (mergePrompts) flushMergeBuffer();
    } else {
        const fallbackTokens = estimateTokens("You are a helpful assistant.");
        messages.push({
            role: "system",
            content: "You are a helpful assistant.",
            sources: fallbackTokens > 0 ? [{ source: 'preset', tokens: fallbackTokens }] : [],
            _allSources: fallbackTokens > 0 ? [{ source: 'preset', tokens: fallbackTokens }] : []
        });
        if (summaryText) {
            const sTokens = estimateTokens(summaryText);
            messages.push({
                role: "system",
                content: summaryText,
                sources: sTokens > 0 ? [{ source: 'summary', tokens: sTokens }] : [],
                _allSources: sTokens > 0 ? [{ source: 'summary', tokens: sTokens }] : []
            });
        }
        if (history) {
            for (const m of history) {
                const content = m.content !== undefined ? m.content : (m.text || m.mes || "");
                const tokens = estimateTokens(content);
                messages.push({
                    ...m,
                    content,
                    isHistory: true,
                    sources: tokens > 0 ? [{ source: 'history', tokens }] : [],
                    _allSources: tokens > 0 ? [{ source: 'history', tokens }] : []
                });
            }
        }
    }

    const filteredMessages = messages.filter(m => {
        if (m.isHistory) return true;
        return m.content && m.content.trim().length > 0;
    });

    return { messages: filteredMessages, loreEntries: allLoreEntries, notifyObj };
}

self.onmessage = async function (e) {
    const { id, type, payload } = e.data;

    if (type === 'calculateContext' || type === 'generateChatResponse') {
        try {
            const { messages, loreEntries, notifyObj } = buildPromptMessagesWorker(payload);

            const { apiConfig } = payload;
            const maxTokens = apiConfig.maxTokens;
            const contextSize = apiConfig.contextSize;
            const safeContext = contextSize - maxTokens;

            const staticMessages = messages.filter(m => !m.isHistory);
            const historyMessages = messages.filter(m => m.isHistory);
            const loreReserveTokens = getLorebookReserve(payload.globalSettings, safeContext);

            const sourceKeys = ['character', 'preset', 'summary', 'authorsNote', 'lorebook', 'history'];
            const sourceTotals = {};
            for (const k of sourceKeys) sourceTotals[k] = 0;

            let staticTokens = 0;
            for (const m of staticMessages) {
                const msgTokens = estimateTokens(m.content);
                staticTokens += msgTokens;

                const msgSources = m._allSources || m.sources || [];
                for (const s of msgSources) {
                    if (sourceKeys.includes(s.source)) {
                        sourceTotals[s.source] += s.tokens;
                    }
                }
            }

            const breakdown = {
                safeContext,
                maxTokens,
                contextSize,
                character: sourceTotals.character,
                preset: sourceTotals.preset,
                summary: sourceTotals.summary,
                authorsNote: sourceTotals.authorsNote,
                lorebook: sourceTotals.lorebook,
                lorebookReserve: loreReserveTokens,
                history: 0,
                fixedBase: 0,
                fixedTotal: 0,
                availableForHistory: 0,
                totalUsed: 0,
                remaining: 0,
                historyMessagesTotal: historyMessages.length,
                historyMessagesIncluded: 0,
                historyMessagesHiddenByContext: 0
            };

            breakdown.fixedBase = breakdown.character + breakdown.preset + breakdown.summary + breakdown.authorsNote + breakdown.lorebook;
            breakdown.fixedTotal = breakdown.fixedBase + breakdown.lorebookReserve;

            let availableForHistory = safeContext - breakdown.fixedTotal;
            breakdown.availableForHistory = Math.max(0, availableForHistory);
            let finalMessages = [];
            let cutoffIndex = -1;
            let cutoffOriginalIndex = -1;

            if (breakdown.fixedTotal >= safeContext) {
                finalMessages = staticMessages;
                cutoffIndex = historyMessages.length;
                cutoffOriginalIndex = Number.MAX_SAFE_INTEGER;
                breakdown.historyMessagesIncluded = 0;
                breakdown.historyMessagesHiddenByContext = historyMessages.length;
            } else {
                let currentHistoryTokens = 0;
                let includedCount = 0;

                for (let i = historyMessages.length - 1; i >= 0; i--) {
                    const tokens = estimateTokens(historyMessages[i].content);
                    if (currentHistoryTokens + tokens <= availableForHistory) {
                        currentHistoryTokens += tokens;
                        includedCount++;
                    } else {
                        break;
                    }
                }

                cutoffIndex = historyMessages.length - includedCount;
                const cutoffMessage = historyMessages[cutoffIndex];
                cutoffOriginalIndex = cutoffMessage !== undefined ? cutoffMessage.chatId : -1;
                breakdown.history = currentHistoryTokens;
                breakdown.historyMessagesIncluded = includedCount;
                breakdown.historyMessagesHiddenByContext = historyMessages.length - includedCount;

                const keptHistoryMessages = historyMessages.slice(cutoffIndex);

                for (const m of messages) {
                    if (!m.isHistory || keptHistoryMessages.includes(m)) {
                        finalMessages.push(m);
                    }
                }
            }

            breakdown.totalUsed = breakdown.fixedBase + breakdown.lorebookReserve + breakdown.history;
            breakdown.remaining = Math.max(0, safeContext - breakdown.totalUsed);

            self.postMessage({
                id,
                success: true,
                data: {
                    messages: finalMessages,
                    cutoffIndex,
                    cutoffOriginalIndex,
                    loreEntries,
                    staticTokens,
                    contextBreakdown: breakdown,
                    needsVarsSave: notifyObj.varsChanged,
                    sessionVars: payload.sessionVars
                }
            });
        } catch (error) {
            self.postMessage({ id, success: false, error: error.message });
        }
    }
};
