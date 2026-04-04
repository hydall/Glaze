export function replaceMacros(text, char, persona) {
    if (!text) return "";

    // --- Comments ---
    // Multi-line scoped: {{ // }} ... {{ /// }}
    let result = text.replace(/\{\{\s*\/\/\s*\}\}[\s\S]*?\{\{\s*\/\/\/\s*\}\}/g, '');
    // Single-line: {{// comment}}
    result = result.replace(/\{\{\/\/[^}]*\}\}/g, '');

    const charName = char ? char.name : "Character";
    const charDesc = char ? (char.description || char.desc || "") : "";
    const charScenario = char ? (char.scenario || "") : "";
    const charPersonality = char ? (char.personality || "") : "";
    const charMesExample = char ? (char.mes_example || "") : "";

    const userName = persona ? persona.name : "User";
    const userPersona = persona ? (persona.prompt || "") : "";

    result = result.replace(/\{{1,2}char\}{1,2}/gi, charName)
        .replace(/{{description}}/gi, charDesc)
        .replace(/{{scenario}}/gi, charScenario)
        .replace(/{{personality}}/gi, charPersonality)
        .replace(/{{mesExamples}}/gi, charMesExample)
        .replace(/\{{1,2}user\}{1,2}/gi, userName)
        .replace(/{{persona}}/gi, userPersona);

    // --- Advanced Macros ---

    // {{trim}}
    if (result.includes("{{trim}}")) {
        result = result.replace(/{{trim}}/gi, "").trim();
    }

    const charId = char?.id || "default";
    const sessionId = char?.sessionId || "current";

    // {{setvar::name::value}}
    result = result.replace(/{{setvar::([\s\S]*?)::([\s\S]*?)}}/gi, (match, name, value) => {
        const vars = getSessionVars(charId, sessionId);
        vars[name] = value;
        saveSessionVars(charId, sessionId, vars);
        return "";
    });

    // {{getvar::name}}
    result = result.replace(/{{getvar::([\s\S]*?)}}/gi, (match, name) => {
        const vars = getSessionVars(charId, sessionId);
        return vars[name] !== undefined ? vars[name] : "";
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
        const vars = getSessionVars(charId, sessionId);
        const version = vars.__pick_version || 0;
        const seed = `${charId}_${sessionId}_pick_${pickCount++}_v${version}`;
        const hash = simpleHash(seed);
        return options[hash % options.length];
    });

    // {{roll::1d20}}
    result = result.replace(/{{roll::(.*?)}}/gi, (match, dice) => {
        return rollDice(dice);
    });

    // --- Escaping: \{\{ → {{ and \}\} → }} ---
    result = result.replace(/\\\{/g, '{').replace(/\\\}/g, '}');

    return result;
}

function getSessionVars(charId, sessionId) {
    const key = `gz_vars_${charId}_${sessionId}`;
    try {
        return JSON.parse(localStorage.getItem(key)) || {};
    } catch (e) {
        return {};
    }
}

function saveSessionVars(charId, sessionId, vars) {
    const key = `gz_vars_${charId}_${sessionId}`;
    localStorage.setItem(key, JSON.stringify(vars));
}

function simpleHash(str) {
    let hash = 0;
    for (let i = 0; i < str.length; i++) {
        const char = str.charCodeAt(i);
        hash = ((hash << 5) - hash) + char;
        hash |= 0;
    }
    return Math.abs(hash);
}

function rollDice(dice) {
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
