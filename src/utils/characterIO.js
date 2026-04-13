/**
 * Utility for importing and exporting character cards (SillyTavern V2 JSON/PNG).
 */
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { db } from '@/utils/db.js';
import { logger } from './logger.js';
import { saveFile } from '../core/services/fileSaver.js';
import { importSTLorebook } from '@/core/states/lorebookState.js';

// ─── Import ──────────────────────────────────────────────────────────────────

/**
 * Parses a character card file.
 * @param {File} file - File obtained from input[type="file"]
 * @returns {Promise<Object>} - Character data object
 */
export async function parseCharacterCard(file) {
    if (file.type === 'image/png' || file.name.toLowerCase().endsWith('.png')) {
        return await parsePng(file);
    } else {
        return await parseJson(file);
    }
}

function parseJson(file) {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();

        reader.onload = async (event) => {
            try {
                const text = event.target.result;
                const json = JSON.parse(text);
                const normalized = normalizeCharacterData(json);
                if (normalized.avatar && !normalized.thumbnail) {
                    try {
                        let avatarSrc = normalized.avatar;
                        if (!avatarSrc.startsWith('data:') && !avatarSrc.startsWith('http')) {
                            if (!avatarSrc.startsWith('/characters/')) {
                                avatarSrc = 'data:image/png;base64,' + avatarSrc;
                            }
                        }
                        normalized.thumbnail = await generateThumbnail(avatarSrc);
                    } catch (e) {
                        console.error('Failed to generate thumbnail from JSON', e);
                    }
                }
                resolve(normalized);
            } catch (err) {
                reject(new Error("JSON read error: " + err.message));
            }
        };

        reader.onerror = (err) => reject(err);
        reader.readAsText(file);
    });
}

async function parsePng(file) {
    const arrayBuffer = await file.arrayBuffer();
    const dataView = new DataView(arrayBuffer);
    const uint8Array = new Uint8Array(arrayBuffer);

    // Validate PNG signature
    if (uint8Array[0] !== 137 || uint8Array[1] !== 80 || uint8Array[2] !== 78 || uint8Array[3] !== 71) {
        throw new Error("Invalid PNG file");
    }

    let offset = 8;
    let charaData = null;
    const textDecoder = new TextDecoder('utf-8');

    while (offset < arrayBuffer.byteLength) {
        const length = dataView.getUint32(offset);
        offset += 4;
        const type = textDecoder.decode(uint8Array.slice(offset, offset + 4));
        offset += 4;

        if (type === 'tEXt') {
            const chunkData = uint8Array.slice(offset, offset + length);
            let nullIndex = -1;
            for (let i = 0; i < chunkData.length; i++) {
                if (chunkData[i] === 0) {
                    nullIndex = i;
                    break;
                }
            }

            if (nullIndex !== -1) {
                const keyword = textDecoder.decode(chunkData.slice(0, nullIndex));
                if (keyword === 'chara' || keyword === 'ccv3') {
                    const base64Text = textDecoder.decode(chunkData.slice(nullIndex + 1));
                    try {
                        // Decode base64 to raw bytes, then interpret as UTF-8
                        const binaryString = atob(base64Text);
                        const bytes = new Uint8Array(binaryString.length);
                        for (let i = 0; i < binaryString.length; i++) {
                            bytes[i] = binaryString.charCodeAt(i);
                        }
                        const jsonStr = new TextDecoder('utf-8').decode(bytes);
                        charaData = JSON.parse(jsonStr);
                    } catch (e) {
                        console.error("Failed to decode base64 from PNG:", e);
                    }
                }
            }
        }
        offset += length + 4; // Data + CRC
    }

    if (!charaData) throw new Error("No character data found in PNG (tEXt chunk 'chara' or 'ccv3')");

    // Convert the image to base64 for use as the avatar
    const avatarBase64 = await fileToBase64(file);
    const normalized = normalizeCharacterData(charaData);
    normalized.avatar = avatarBase64; // Avatar from the file takes priority

    try {
        normalized.thumbnail = await generateThumbnail(avatarBase64);
    } catch (e) {
        console.error("Failed to generate thumbnail for PNG:", e);
    }

    return normalized;
}

function normalizeCharacterData(json) {
    let data;
    if ((json.spec === 'chara_card_v2' || json.spec === 'chara_card_v3') && json.data) {
        if (!json.data.alternate_greetings) json.data.alternate_greetings = [];
        data = json.data;
    } else if (json.name) {
        data = json;
    } else {
        throw new Error("Unknown character data format");
    }

    if (!data.name) {
        data.name = "Unknown";
    }

    // No avatar — set null so the placeholder is shown (see .avatar-placeholder in components.css)
    if (!data.avatar || data.avatar === 'none') {
        data.avatar = null;
    }
    return data;
}

export async function extractCharacterBook(charData) {
    const cb = charData.character_book;
    if (!cb || (!cb.entries && !cb.name)) return null;

    const lbName = cb.name || `${charData.name || 'Character'} Lorebook`;
    const lorebook = await importSTLorebook({ ...cb, name: lbName }, lbName);

    delete charData.character_book;

    return lorebook;
}

function fileToBase64(file) {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = reject;
        reader.readAsDataURL(file);
    });
}

/**
 * Creates a hidden file input and triggers the import flow.
 * @param {Function} onImport - Callback invoked with character data on successful import.
 */
export function triggerCharacterImport(onImport) {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = '.json,application/json,.png,image/png'; // JSON and PNG

    input.onchange = async (e) => {
        const file = e.target.files[0];
        if (!file) return;

        try {
            const characterData = await parseCharacterCard(file);
            if (onImport) {
                onImport(characterData);
            }
        } catch (error) {
            console.error("Import failed:", error);
            const t = translations[currentLang.value];
            showBottomSheet({
                title: t?.title_error || "Error",
                bigInfo: {
                    icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;color:#ff4444"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>',
                    description: (t?.msg_import_char_failed || "Failed to import character") + ": " + error.message,
                    buttonText: t?.btn_ok || "OK",
                    onButtonClick: () => closeBottomSheet()
                }
            });
        }
    };

    input.click();
}

/**
 * Generates a base64 thumbnail from an image source.
 * @param {string} imageSrc - The source of the image (base64 or URL).
 * @param {number} maxSize - Maximum width or height.
 * @returns {Promise<string>} Base64 JPEG string of the thumbnail.
 */
export async function generateThumbnail(imageSrc, maxSize = 600) {
    if (!imageSrc) return null;
    return new Promise((resolve, reject) => {
        const img = new Image();
        img.onload = () => {
            let width = img.width;
            let height = img.height;
            if (width > height) {
                if (width > maxSize) {
                    height *= maxSize / width;
                    width = maxSize;
                }
            } else {
                if (height > maxSize) {
                    width *= maxSize / height;
                    height = maxSize;
                }
            }
            const canvas = document.createElement('canvas');
            canvas.width = width;
            canvas.height = height;
            const ctx = canvas.getContext('2d');
            ctx.drawImage(img, 0, 0, width, height);
            resolve(canvas.toDataURL('image/jpeg', 0.8));
        };
        img.onerror = () => {
            console.warn("Could not load image for thumbnail generation", imageSrc.substring(0, 50));
            reject(new Error("Failed to load image"));
        };

        // Handle CORS if it's an external URL
        if (imageSrc.startsWith('http')) {
            img.crossOrigin = 'Anonymous';
        }

        img.src = imageSrc;
    });
}

/**
 * Iterates over all characters in the DB and generates thumbnails for those missing one.
 */
export async function generateMissingThumbnails() {
    try {
        const chars = await db.getAll('characters');
        if (!chars) return;

        let updatedCount = 0;
        for (const char of chars) {
            // Only generate if there is an avatar and no thumbnail
            if (char.avatar && !char.thumbnail) {
                try {
                    let avatarSrc = char.avatar;
                    if (!avatarSrc.startsWith('http') && !avatarSrc.startsWith('blob:') && !avatarSrc.startsWith('data:')) {
                        avatarSrc = `/characters/${avatarSrc}`;
                    }

                    char.thumbnail = await generateThumbnail(avatarSrc);
                    if (char.thumbnail) {
                        await db.saveCharacter(char, -1);
                        updatedCount++;
                    }
                } catch (e) {
                    console.error(`Failed to generate missing thumbnail for ${char.name}:`, e);
                }
            }
        }
        if (updatedCount > 0) {
            logger.debug(`Generated thumbnails for ${updatedCount} characters.`);
            // Dispatch event to reload character list if needed
            window.dispatchEvent(new Event('character-updated'));
        }
    } catch (e) {
        console.error("Error generating missing thumbnails:", e);
    }
}

// ─── Export ──────────────────────────────────────────────────────────────────

/**
 * Builds a V2-spec export object, stripping internal fields.
 */
function prepareV2Data(character, excludeAvatar = false) {
    const data = JSON.parse(JSON.stringify(character));

    // Remove internal IDs and Glaze-specific fields if present
    delete data.id;
    delete data.sessionId;
    delete data.color;
    delete data.thumbnail;

    if (excludeAvatar) {
        delete data.avatar;
    }

    // character_book is excluded from export; extensions is kept as an empty object
    // because SillyTavern may require it to be present
    delete data.character_book;

    // Ensure all required V2 spec fields are present (SillyTavern)
    // Field order follows Alice.json
    const exportData = {
        name: data.name || "",
        first_mes: data.first_mes || "",
        alternate_greetings: data.alternate_greetings || [],
        description: data.description || "",
        personality: data.personality || "",
        mes_example: data.mes_example || "",
        scenario: data.scenario || "",
        creator: data.creator || "",
        creator_notes: data.creator_notes || "",
        system_prompt: data.system_prompt || "",
        post_history_instructions: data.post_history_instructions || "",
        tags: data.tags || [],
        character_version: data.character_version || "1",
        extensions: {}
    };

    // Include avatar only if not excluded
    if (!excludeAvatar && data.avatar) {
        exportData.avatar = data.avatar;
    }

    // Remove undefined fields
    Object.keys(exportData).forEach(key => {
        if (exportData[key] === undefined) delete exportData[key];
    });

    // Field order matters (Alice.json): data comes before spec
    return {
        data: exportData,
        spec: "chara_card_v2",
        spec_version: "2.0"
    };
}

/**
 * Export a character as a V2 JSON file.
 */
export async function exportCharacterAsV2Json(character) {
    const data = prepareV2Data(character, true);
    const fileName = `${(character.name || 'character').replace(/[/\\?%*:|"<>]/g, '-')}.json`;

    // UTF-8 LF without BOM
    const jsonStr = JSON.stringify(data, null, 4);

    await saveFile(fileName, jsonStr, 'application/json');
}

/**
 * Helper to compute CRC32 (required for PNG chunks).
 */
function crc32(data) {
    const table = new Uint32Array(256);
    for (let i = 0; i < 256; i++) {
        let c = i;
        for (let j = 0; j < 8; j++) {
            c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
        }
        table[i] = c;
    }

    let crc = 0xFFFFFFFF;
    for (let i = 0; i < data.length; i++) {
        crc = table[(crc ^ data[i]) & 0xFF] ^ (crc >>> 8);
    }
    return (crc ^ 0xFFFFFFFF) >>> 0;
}

/**
 * Export a character as a PNG with embedded character data.
 */
export async function exportCharacterAsV2Png(character) {
    const v2Data = prepareV2Data(character);
    const fileName = `${(character.name || 'character').replace(/[/\\?%*:|"<>]/g, '-')}.png`;

    // 1. Get the base image
    let avatarUrl = character.avatar;
    if (!avatarUrl) {
        // No avatar — generate a placeholder canvas instead
        const canvas = document.createElement('canvas');
        canvas.width = 400;
        canvas.height = 600;
        const ctx = canvas.getContext('2d');
        ctx.fillStyle = character.color || '#66ccff';
        ctx.fillRect(0, 0, 400, 600);
        ctx.fillStyle = '#ffffff';
        ctx.font = 'bold 80px Arial';
        ctx.textAlign = 'center';
        ctx.fillText(character.name?.[0]?.toUpperCase() || '?', 200, 320);
        avatarUrl = canvas.toDataURL('image/png');
    } else if (!avatarUrl.startsWith('data:') && !avatarUrl.startsWith('http') && !avatarUrl.startsWith('blob:')) {
        avatarUrl = `/characters/${avatarUrl}`;
    }

    // Load the image to normalize it as PNG bytes
    const img = new Image();
    img.crossOrigin = 'Anonymous';

    const pngArrayBuffer = await new Promise((resolve, reject) => {
        img.onload = () => {
            const canvas = document.createElement('canvas');
            canvas.width = img.width;
            canvas.height = img.height;
            const ctx = canvas.getContext('2d');
            ctx.drawImage(img, 0, 0);
            canvas.toBlob((blob) => {
                blob.arrayBuffer().then(resolve);
            }, 'image/png');
        };
        img.onerror = () => reject(new Error("Failed to load avatar image"));
        img.src = avatarUrl;
    });

    const uint8 = new Uint8Array(pngArrayBuffer);

    // 2. Prepare the tEXt chunk data
    // tEXt format: Keyword + null byte + Text
    const keyword = "chara";
    const textData = btoa(unescape(encodeURIComponent(JSON.stringify(v2Data)))); // Base64-encoded UTF-8 string

    const encoder = new TextEncoder();
    const keywordBytes = encoder.encode(keyword);
    const textBytes = encoder.encode(textData);

    const chunkData = new Uint8Array(keywordBytes.length + 1 + textBytes.length);
    chunkData.set(keywordBytes, 0);
    chunkData.set([0], keywordBytes.length); // Null terminator
    chunkData.set(textBytes, keywordBytes.length + 1);

    const chunkType = encoder.encode("tEXt");

    // 3. Assemble the chunk: Length (4) + Type (4) + Data (N) + CRC (4)
    const chunkFull = new Uint8Array(4 + 4 + chunkData.length + 4);
    const view = new DataView(chunkFull.buffer);

    view.setUint32(0, chunkData.length); // Length
    chunkFull.set(chunkType, 4); // Type
    chunkFull.set(chunkData, 8); // Data

    // CRC is computed over Type + Data
    const crcContent = new Uint8Array(4 + chunkData.length);
    crcContent.set(chunkType, 0);
    crcContent.set(chunkData, 4);
    view.setUint32(4 + 4 + chunkData.length, crc32(crcContent)); // CRC

    // 4. Insert the chunk into the PNG right after the IHDR chunk
    // Standard offset after IHDR: 8 (sig) + 4 (len) + 4 (type) + 13 (data) + 4 (crc) = 33
    const resultPng = new Uint8Array(uint8.length + chunkFull.length);
    resultPng.set(uint8.subarray(0, 33), 0);
    resultPng.set(chunkFull, 33);
    resultPng.set(uint8.subarray(33), 33 + chunkFull.length);

    const blob = new Blob([resultPng], { type: 'image/png' });
    await saveFile(fileName, blob, 'image/png', 'characters');
}
