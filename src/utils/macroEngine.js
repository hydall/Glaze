export function replaceMacros(text, char, persona, sessionVarsIn = null, notifyObj = null) {
    if (!text) return "";

    // --- Comments ---
    // Multi-line scoped: {{ // }} ... {{ /// }}
    let result = text.replace(/\{\{\s*\/\/\s*\}\}[\s\S]*?\{\{\s*\/\/\/\s*\}\}/g, '');
    // Single-line: {{// comment}}
    result = result.replace(/\{\{\/\/[^}]*\}\}/g, '');

    const charName = char ? (char.macro_name || char.name) : "Character";
    const charDesc = char ? (char.description || char.desc || "") : "";
    const charScenario = char ? (char.scenario || "") : "";
    const charPersonality = char ? (char.personality || "") : "";
    const charMesExample = char ? (char.mes_example || "") : "";

    const userName = persona ? persona.name : "User";
    const userPersona = persona ? (persona.prompt || "") : "";

    result = result.replace(/{{char}}/gi, charName)
        .replace(/{{description}}/gi, charDesc)
        .replace(/{{scenario}}/gi, charScenario)
        .replace(/{{personality}}/gi, charPersonality)
        .replace(/{{mesExamples}}/gi, charMesExample)
        .replace(/{{user}}/gi, userName)
        .replace(/{{persona}}/gi, userPersona);

    // {{trim}}
    if (result.includes("{{trim}}")) {
        result = result.replace(/{{trim}}/gi, "").trim();
    }

    const charId = char?.id || "default";
    const sessionId = char?.sessionId || "current";

    // If sessionVars not provided (main thread), load from localStorage
    const ownVars = sessionVarsIn === null;
    const sessionVars = ownVars ? _getSessionVars(charId, sessionId) : sessionVarsIn;
    let varsChanged = false;

    // {{setvar::name::value}}
    result = result.replace(/{{setvar::([\s\S]*?)::([\s\S]*?)}}/gi, (match, name, value) => {
        sessionVars[name] = value;
        varsChanged = true;
        return "";
    });

    // {{setglobalvar::name::value}}
    result = result.replace(/{{setglobalvar::([\s\S]*?)::([\s\S]*?)}}/gi, (match, name, value) => {
        _setGlobalVar(name, value);
        return "";
    });

    // {{getvar::name}}
    result = result.replace(/{{getvar::([\s\S]*?)}}/gi, (match, name) => {
        return sessionVars[name] !== undefined ? sessionVars[name] : "";
    });

    // {{getglobalvar::name}}
    result = result.replace(/{{getglobalvar::([\s\S]*?)}}/gi, (match, name) => {
        const val = _getGlobalVar(name);
        return val !== null ? val : "";
    });

    // {{lumiaDef}}, {{lumiaOOC}}, {{loomRetrofits}}, etc. - custom macros from preset
    // These are treated as global variables set via setglobalvar
    result = result.replace(/\{\{(lumiaDef|lumiaOOC|lumiaOOCErotic|lumiaOOCEroticBleed|lumiaPersonality|loomRetrofits|loomStyle|loomSummary|loomUtils|sim_tracker|suggest)\}\}/gi, (match, name) => {
        const val = _getGlobalVar(name);
        return val !== null ? val : match; // return original macro if not found
    });

    // {{random::a::b::c}}
    result = result.replace(/{{random::(.*?)}}/gi, (match, optionsStr) => {
        const options = optionsStr.split("::");
        return options[Math.floor(Math.random() * options.length)];
    });

    // {{pick::a::b::c}}
    let pickCount = 0;
    result = result.replace(/{{pick::(.*?)}}/gi, (match, optionsStr) => {
        const options = optionsStr.split("::");
        const version = sessionVars.__pick_version || 0;
        const seed = `${charId}_${sessionId}_pick_${pickCount++}_v${version}`;
        const hash = _simpleHash(seed);
        return options[hash % options.length];
    });

    // {{roll::1d20}}
    result = result.replace(/{{roll::(.*?)}}/gi, (match, dice) => {
        return _rollDice(dice);
    });

    // {{date}} / {{time}} / {{weekday}} - current datetime
    const now = new Date();
    result = result.replace(/\{\{date\}\}/gi, () => now.toLocaleDateString());
    result = result.replace(/\{\{time\}\}/gi, () => now.toLocaleTimeString());
    result = result.replace(/\{\{weekday\}\}/gi, () => now.toLocaleDateString('en-US', { weekday: 'long' }));

    // {{reasoningPrefix}} / {{reasoningSuffix}} - reasoning tags from sessionVars or localStorage
    result = result.replace(/\{\{reasoningPrefix\}\}/gi, () => {
        return sessionVars.reasoningPrefix || localStorage.getItem('gz_api_reasoning_start') || '<think>';
    });
    result = result.replace(/\{\{reasoningSuffix\}\}/gi, () => {
        return sessionVars.reasoningSuffix || localStorage.getItem('gz_api_reasoning_end') || '';
    });

    // --- Escaping: \{\{ → {{ and \}\} → }} ---
    result = result.replace(/\\\{/g, '{').replace(/\\\}/g, '}');

    if (varsChanged) {
        if (notifyObj) notifyObj.varsChanged = true;
        if (ownVars) _saveSessionVars(charId, sessionId, sessionVars);
    }

    return result;
}

function _getSessionVars(charId, sessionId) {
    const key = `gz_vars_${charId}_${sessionId}`;
    try {
        return JSON.parse(localStorage.getItem(key)) || {};
    } catch (e) {
        return {};
    }
}

function _saveSessionVars(charId, sessionId, vars) {
    const key = `gz_vars_${charId}_${sessionId}`;
    localStorage.setItem(key, JSON.stringify(vars));
}

function _getGlobalVar(name) {
    try {
        const globalVars = JSON.parse(localStorage.getItem('gz_global_vars') || '{}');
        return globalVars[name] !== undefined ? globalVars[name] : null;
    } catch (e) {
        return null;
    }
}

function _setGlobalVar(name, value) {
    try {
        const globalVars = JSON.parse(localStorage.getItem('gz_global_vars') || '{}');
        globalVars[name] = value;
        localStorage.setItem('gz_global_vars', JSON.stringify(globalVars));
    } catch (e) { }
}

function _simpleHash(str) {
    let hash = 0;
    for (let i = 0; i < str.length; i++) {
        const char = str.charCodeAt(i);
        hash = ((hash << 5) - hash) + char;
        hash |= 0;
    }
    return Math.abs(hash);
}

function _rollDice(dice) {
    const match = dice.match(/(\d+)d(\d+)/i);
    if (!match) return dice;
    const count = parseInt(match[1]);
    const sides = parseInt(match[2]);
    let total = 0;
    for (let i = 0; i < count; i++) {
        total += Math.floor(Math.random() * sides) + 1;
    }
    return total.toString();
}
