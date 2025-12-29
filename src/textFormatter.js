export function formatText(text) {
    if (!text) return "";
    
    // Remove leading/trailing line breaks
    text = text.replace(/^[\r\n]+|[\r\n]+$/g, '');

    // 1. Allow HTML (No escaping)
    let html = text;

    // 2. Extract Code Blocks (to prevent formatting inside them)
    const codeBlocks = [];
    html = html.replace(/```(\w*)\n?([\s\S]*?)```/g, (match, lang, code) => {
        const id = `__CODE_BLOCK_${codeBlocks.length}__`;
        codeBlocks.push({ lang, code });
        return id;
    });

    // Extract Style Blocks (to prevent formatting inside them)
    const styleBlocks = [];
    html = html.replace(/<style([\s\S]*?)>([\s\S]*?)<\/style>/gi, (match, attributes, content) => {
        const id = `__STYLE_BLOCK_${styleBlocks.length}__`;
        // Fix escaped newlines inside style blocks by converting them to real newlines
        content = content.replace(/&lt;br\s*\/?(?:&gt;|>)/gi, '\n');
        styleBlocks.push({ attributes, content });
        return id;
    });

    // Extract CSS comments (to prevent formatting inside them)
    const cssComments = [];
    html = html.replace(/\/\*[\s\S]*?\*\//g, (match) => {
        const id = `__CSS_COMMENT_${cssComments.length}__`;
        cssComments.push(match);
        return id;
    });

    // Fix escaped newlines from model (in remaining text)
    html = html.replace(/&lt;br\s*\/?(?:&gt;|>)/gi, '<br>');

    // 3. Quotes -> Blue
    // Regex matches HTML tags (to skip), Quotes preceded by = (to skip), OR Quotes (to color)
    const regex = /(<[^>]+>)|(=[ \t]*"(?:[^"]|<[^>]+>)*?")|("((?:[^"]|<[^>]+>)*?)"|“((?:[^”]|<[^>]+>)*?)”|«((?:[^»]|<[^>]+>)*?)»)/g;
    html = html.replace(regex, (match, tag, skipQuote) => {
        if (tag) return tag; // Return HTML tag unchanged
        if (skipQuote) return skipQuote; // Return quotes preceded by = unchanged
        return `<span style="color: var(--vk-blue);">${match}</span>`;
    });

    // 4. Markdown Parsing (in order of precedence)
    // Horizontal Rule on its own line
    html = html.replace(/^(_{3,}|-{3,}|\*{3,})$/gm, '<hr>');

    // Bold and Italic
    html = html.replace(/\*\*\*([\s\S]+?)\*\*\*/g, '<strong><em>$1</em></strong>');
    
    // Bold
    html = html.replace(/\*\*([\s\S]+?)\*\*/g, '<strong>$1</strong>');
    
    // Italic/Action: *text* -> Gray
    html = html.replace(/\*([\s\S]+?)\*/g, '<em>$1</em>');

    // 5. Color styling for Actions
    // Color all em tags gray for actions
    html = html.replace(/<em>/g, '<em style="color: #888;">');

    // Restore CSS comments
    html = html.replace(/__CSS_COMMENT_(\d+)__/g, (match, index) => {
        return cssComments[index];
    });

    // 6. Newlines
    html = html.replace(/\n/g, '<br>');

    // Restore Style Blocks
    html = html.replace(/__STYLE_BLOCK_(\d+)__/g, (match, index) => {
        const block = styleBlocks[index];
        return `<style${block.attributes}>${block.content}</style>`;
    });

    // 7. Restore Code Blocks
    html = html.replace(/__CODE_BLOCK_(\d+)__/g, (match, index) => {
        const block = codeBlocks[index];
        // Escape HTML characters to display code literally
        const escapedCode = block.code
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;");
        
        return `<pre class="code-block" data-lang="${block.lang}"><code>${escapedCode}</code></pre>`;
    });

    return html;
}

export function replaceMacros(text, char, persona) {
    if (!text) return "";
    
    const charName = char ? char.name : "Character";
    const charDesc = char ? (char.description || char.desc || "") : "";
    const charScenario = char ? (char.scenario || "") : "";
    const charPersonality = char ? (char.personality || "") : "";
    
    const userName = persona ? persona.name : "User";
    const userPersona = persona ? (persona.prompt || "") : "";

    return text.replace(/{{char}}/gi, charName)
               .replace(/{{description}}/gi, charDesc)
               .replace(/{{scenario}}/gi, charScenario)
               .replace(/{{personality}}/gi, charPersonality)
               .replace(/{{user}}/gi, userName)
               .replace(/{{persona}}/gi, userPersona);
}