import { Capacitor } from '@capacitor/core';
import { Filesystem, Directory, Encoding } from '@capacitor/filesystem';
import { App } from '@capacitor/app';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';

/**
 * Saves a file to the user's device.
 * Supports both web (download) and native (filesystem) platforms.
 * @param {string} filename - The name of the file to save.
 * @param {string | Blob | Uint8Array | ArrayBuffer} content - The text content or binary data of the file.
 * @param {string} mimeType - The MIME type of the file.
 * @param {string} subFolder - Optional subfolder to save the file in (e.g. 'presets', 'characters').
 */
export async function saveFile(filename, content, mimeType = 'application/json', subFolder = '') {
    if (content !== null && typeof content === 'object' && !(content instanceof Blob) && !(content instanceof Uint8Array) && !(content instanceof ArrayBuffer)) {
        content = JSON.stringify(content);
    }
    const isBinary = content instanceof Blob || content instanceof Uint8Array || content instanceof ArrayBuffer;

    if (Capacitor.isNativePlatform()) {
        try {
            const platform = Capacitor.getPlatform();
            let directory = platform === 'android' ? Directory.ExternalStorage : Directory.Documents;
            let rootFolder = platform === 'android' ? 'Download/Glaze' : '';

            // Combine root folder with subfolder
            let folder = rootFolder;
            if (subFolder) {
                folder = folder ? `${folder}/${subFolder}` : subFolder;
            }

            let displayPath = platform === 'android' ? `Download/Glaze` : `Documents`;
            if (subFolder) displayPath += `/${subFolder}`;
            displayPath += `/${filename}`;

            const path = folder ? `${folder}/${filename}` : filename;

            let data = content;
            let encoding = Encoding.UTF8;

            if (isBinary) {
                // Convert to base64 for Capacitor Filesystem
                const blob = content instanceof Blob ? content : new Blob([content]);
                data = await blobToBase64(blob);
                encoding = undefined; // Omitting encoding tells Capacitor it's base64
            }

            // Explicitly create directory if it contains subfolders
            if (folder) {
                try {
                    await Filesystem.mkdir({
                        path: folder,
                        directory: directory,
                        recursive: true
                    });
                } catch (e) {
                    // Ignore error if folder already exists
                }
            }

            const CHUNK_SIZE = 512 * 1024; // 512KB chunks to prevent bridge crash
            if (!isBinary && typeof data === 'string' && data.length > CHUNK_SIZE) {
                await Filesystem.writeFile({
                    path: path,
                    data: '',
                    directory: directory,
                    encoding: encoding
                });

                for (let i = 0; i < data.length; i += CHUNK_SIZE) {
                    await Filesystem.appendFile({
                        path: path,
                        data: data.substring(i, i + CHUNK_SIZE),
                        directory: directory,
                        encoding: encoding
                    });
                }
            } else {
                await Filesystem.writeFile({
                    path: path,
                    data: data,
                    directory: directory,
                    encoding: encoding
                });
            }

            const t = translations[currentLang.value];

            showBottomSheet({
                title: t?.export_success || "Export Complete",
                bigInfo: {
                    icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;color:#4CAF50"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                    description: (t?.msg_saved_to || "Saved to") + " " + displayPath,
                    buttonText: t?.btn_ok || "OK",
                    onButtonClick: () => closeBottomSheet()
                }
            });
        } catch (e) {
            console.error("Native save failed", e);
            // Fallback for Android if ExternalStorage fails (perms etc)
            try {
                // Fallback to Documents if ExternalStorage fails
                let data = content;
                let encoding = Encoding.UTF8;
                if (isBinary) {
                    const blob = content instanceof Blob ? content : new Blob([content]);
                    data = await blobToBase64(blob);
                    encoding = undefined;
                }

                const path = subFolder ? `${subFolder}/${filename}` : filename;
                let displayPath = `Documents`;
                if (subFolder) displayPath += `/${subFolder}`;
                displayPath += `/${filename}`;

                if (subFolder) {
                    try {
                        await Filesystem.mkdir({
                            path: subFolder,
                            directory: Directory.Documents,
                            recursive: true
                        });
                    } catch (mkdirErr) { }
                }

                const CHUNK_SIZE = 512 * 1024;
                if (!isBinary && typeof data === 'string' && data.length > CHUNK_SIZE) {
                    await Filesystem.writeFile({
                        path: path,
                        data: '',
                        directory: Directory.Documents,
                        encoding: encoding
                    });
                    for (let i = 0; i < data.length; i += CHUNK_SIZE) {
                        await Filesystem.appendFile({
                            path: path,
                            data: data.substring(i, i + CHUNK_SIZE),
                            directory: Directory.Documents,
                            encoding: encoding
                        });
                    }
                } else {
                    await Filesystem.writeFile({
                        path: path,
                        data: data,
                        directory: Directory.Documents,
                        encoding: encoding
                    });
                }

                const t = translations[currentLang.value];
                showBottomSheet({
                    title: t?.export_success || "Export Complete",
                    bigInfo: {
                        icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;color:#4CAF50"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                        description: (t?.msg_saved_to || "Saved to") + ` ${displayPath}`,
                        buttonText: t?.btn_ok || "OK",
                        onButtonClick: () => closeBottomSheet()
                    }
                });
            } catch (e2) {
                const t = translations[currentLang.value];
                showBottomSheet({
                    title: t?.title_error || "Error",
                    bigInfo: {
                        icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;color:#ff4444"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>',
                        description: "Export failed: " + e2.message,
                        buttonText: t?.btn_ok || "OK",
                        onButtonClick: () => closeBottomSheet()
                    }
                });
            }
        }
    } else {
        // Web Platform
        const blob = isBinary ? (content instanceof Blob ? content : new Blob([content], { type: mimeType })) : new Blob([content], { type: mimeType });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = filename;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
    }
}

function blobToBase64(blob) {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onloadend = () => {
            const base64 = reader.result.split(',')[1];
            resolve(base64);
        };
        reader.onerror = reject;
        reader.readAsDataURL(blob);
    });
}
