const makeResultHtmlStr = `<span class="imggen-result-wrapper"><img class="imggen-result" src="data:image/png;base64,largeBase64Here" alt="A test" data-iig-instruction='{"prompt":"test"}' data-iig-id="123"><button class="imggen-options-btn" type="button" title="Options">opt</button></span>`

function makeResultHtml(instruction, id, dataUrl) {
    const enc = JSON.stringify(instruction).replace(/&/g, '&amp;').replace(/'/g, '&#39;');
    return `<span class="wrapper"><img src="${dataUrl}" data-iig-instruction='${enc}' id="${id}">...</span>`;
}

function normalizeImgGenHtmlForEditing(text, iigMap) {
    if (!text) return text;
    const makeTag = (instruction) => `<img data-iig-instruction='${instruction}' src="[IMG:GEN]">`;
    const extractInstruction = (chunk) => {
        if (!chunk) return null;
        const m1 = chunk.match(/\bdata-iig-instruction='([^']*)'/i);
        if (m1?.[1] != null) return m1[1];
        const m2 = chunk.match(/\bdata-iig-instruction="([^"]*)"/i);
        if (m2?.[1] != null) return m2[1];
        return null;
    };
    text = text.replace(
        /<span\b[^>]*\bclass="[^"]*\bimggen-result-wrapper\b[^"]*"[^>]*>[\s\S]*?<\/span>/gi,
        (wrapperHtml) => {
            const instruction = extractInstruction(wrapperHtml);
            if (!instruction) return wrapperHtml;

            const mSrc = wrapperHtml.match(/src="([^"]+)"/i);
            const mId = wrapperHtml.match(/data-iig-id="([^"]+)"/i);
            if (mSrc && mSrc[1]) {
                iigMap[instruction] = { dataUrl: mSrc[1], id: mId ? mId[1] : `iig_mock` };
            }

            return makeTag(instruction);
        }
    );
    return text;
}

const iigMap = {};
const editedText = normalizeImgGenHtmlForEditing(makeResultHtmlStr, iigMap);
console.log("Edited:", editedText);

let newText = editedText.replace(
    /<img\b[^>]*?(?:data-iig-instruction='([^']*)'[^>]*?src="\[IMG:GEN\]"|src="\[IMG:GEN\]"[^>]*?data-iig-instruction='([^']*?)')[^>]*?>/g,
    (match, inst1, inst2) => {
        const raw = inst1 ?? inst2 ?? '{}';
        if (iigMap[raw]) {
            const { dataUrl, id } = iigMap[raw];
            let instrObj = {};
            try {
                instrObj = JSON.parse(raw.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&'));
            } catch (e) { }
            return makeResultHtml(instrObj, id, dataUrl);
        }
        return match;
    }
);

console.log("Restored:", newText);
