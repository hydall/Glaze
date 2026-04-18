import JSZip from 'jszip';
import { parseCharacterCard } from '@/utils/characterIO.js';
import { importSillyTavernChat } from '@/core/services/chatImporter.js';
import { convertSTPreset } from '@/core/services/presetImportService.js';
import { importSTLorebook, initLorebookState, saveLorebooks } from '@/core/states/lorebookState.js';
import { db } from '@/utils/db.js';


const DB_NAME = 'SillyCradleDB';
const DB_VERSION = 7;
const STORE_KEYVALUE = 'keyvalue';
const STORE_CHARACTERS = 'characters';
const STORE_PERSONAS = 'personas';

export async function exportFullBackupAsync() {
    return new Promise((resolve, reject) => {
        const lsData = {};
        for (let i = 0; i < localStorage.length; i++) {
            const key = localStorage.key(i);
            lsData[key] = localStorage.getItem(key);
        }

        const workerCode = `
            const DB_NAME = 'SillyCradleDB';
            const DB_VERSION = 7;
            const STORE_KEYVALUE = 'keyvalue';
            const STORE_CHARACTERS = 'characters';
            const STORE_PERSONAS = 'personas';

            function openDb() {
                return new Promise((resolve, reject) => {
                    const req = indexedDB.open(DB_NAME, DB_VERSION);
                    req.onsuccess = (e) => resolve(e.target.result);
                    req.onerror = (e) => reject(e.target.error);
                });
            }

            self.onmessage = async (e) => {
                try {
                    const database = await openDb();
                    const data = {
                        _isGlazeBackup: true,
                        _glazeVersion: 1,
                        [STORE_KEYVALUE]: {},
                        [STORE_CHARACTERS]: [],
                        [STORE_PERSONAS]: [],
                        localStorage: e.data.localStorage || {}
                    };

                    const tx = database.transaction([STORE_KEYVALUE, STORE_CHARACTERS, STORE_PERSONAS], 'readonly');

                    await new Promise((res, rej) => {
                        const kvStore = tx.objectStore(STORE_KEYVALUE);
                        const kvCursor = kvStore.openCursor();
                        kvCursor.onsuccess = (ev) => {
                            const cursor = ev.target.result;
                            if (cursor) {
                                data[STORE_KEYVALUE][cursor.key] = cursor.value;
                                cursor.continue();
                            }
                        };

                        const charStore = tx.objectStore(STORE_CHARACTERS);
                        const charReq = charStore.getAll();
                        charReq.onsuccess = () => {
                            data[STORE_CHARACTERS] = charReq.result;
                        };

                        const personaStore = tx.objectStore(STORE_PERSONAS);
                        const personaReq = personaStore.getAll();
                        personaReq.onsuccess = () => {
                            data[STORE_PERSONAS] = personaReq.result;
                        };

                        tx.oncomplete = res;
                        tx.onerror = () => rej(tx.error);
                    });

                    database.close();

                    const str = JSON.stringify(data);
                    self.postMessage({ success: true, result: str });
                } catch (err) {
                    self.postMessage({ success: false, error: err.message });
                }
            };
        `;

        const blob = new Blob([workerCode], { type: 'application/javascript' });
        const worker = new Worker(URL.createObjectURL(blob));

        worker.onmessage = (e) => {
            if (e.data.success) resolve(e.data.result);
            else reject(new Error(e.data.error));
            worker.terminate();
        };
        worker.onerror = (err) => {
            reject(err);
            worker.terminate();
        };

        worker.postMessage({ localStorage: lsData });
    });
}

export async function importFullBackupAsync(jsonString) {
    return new Promise((resolve, reject) => {
        const workerCode = `
            const DB_NAME = 'SillyCradleDB';
            const DB_VERSION = 7;
            const STORE_KEYVALUE = 'keyvalue';
            const STORE_CHARACTERS = 'characters';
            const STORE_PERSONAS = 'personas';

            function openDb() {
                return new Promise((resolve, reject) => {
                    const req = indexedDB.open(DB_NAME, DB_VERSION);
                    req.onsuccess = (e) => resolve(e.target.result);
                    req.onerror = (e) => reject(e.target.error);
                });
            }

            function toPlain(data) {
                return JSON.parse(JSON.stringify(data));
            }

            self.onmessage = async (e) => {
                try {
                    const data = JSON.parse(e.data.jsonString);
                    if (typeof data !== 'object' || data === null) {
                        throw new Error("Invalid backup: file is not a valid JSON object.");
                    }
                    const hasChars = Array.isArray(data['characters']);
                    const hasPersonas = Array.isArray(data['personas']);
                    const hasKv = typeof data['keyvalue'] === 'object';

                    if (!data._isGlazeBackup && !hasChars && !hasPersonas && !hasKv) {
                        throw new Error("Invalid backup: missing required data structures. Please ensure you select a correct .glz file.");
                    }

                    const database = await openDb();

                    await new Promise((res, rej) => {
                        const tx = database.transaction([STORE_KEYVALUE, STORE_CHARACTERS, STORE_PERSONAS], 'readwrite');

                        const kvStore = tx.objectStore(STORE_KEYVALUE);
                        const charStore = tx.objectStore(STORE_CHARACTERS);
                        const personaStore = tx.objectStore(STORE_PERSONAS);

                        kvStore.clear();
                        charStore.clear();
                        personaStore.clear();

                        if (data[STORE_KEYVALUE]) {
                            for (const [key, value] of Object.entries(data[STORE_KEYVALUE])) {
                                kvStore.put(toPlain(value), key);
                            }
                        }
                        if (data[STORE_CHARACTERS]) {
                            for (const char of data[STORE_CHARACTERS]) {
                                charStore.put(toPlain(char));
                            }
                        }
                        if (data[STORE_PERSONAS]) {
                            for (const persona of data[STORE_PERSONAS]) {
                                personaStore.put(toPlain(persona));
                            }
                        }

                        tx.oncomplete = res;
                        tx.onerror = () => rej(tx.error);
                    });

                    database.close();
                    self.postMessage({ success: true, localStorageData: data.localStorage || {} });
                } catch (err) {
                    self.postMessage({ success: false, error: err.message });
                }
            };
        `;

        const blob = new Blob([workerCode], { type: 'application/javascript' });
        const worker = new Worker(URL.createObjectURL(blob));

        worker.onmessage = (e) => {
            if (e.data.success) {
                const lsData = e.data.localStorageData;
                if (lsData) {
                    localStorage.clear();
                    for (const [key, value] of Object.entries(lsData)) {
                        localStorage.setItem(key, value);
                    }
                }
                resolve();
            } else {
                reject(new Error(e.data.error));
            }
            worker.terminate();
        };
        worker.onerror = (err) => {
            reject(err);
            worker.terminate();
        };

        worker.postMessage({ jsonString });
    });
}


export { importTavoBackupFromZip } from '@/utils/tavoBackupReader.js';

