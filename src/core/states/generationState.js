import { createAsyncScope } from '@/core/utils/asyncOperationScope.js';

const scope = createAsyncScope();
const generationMeta = {};
let generationIdCounter = 0;

function buildGenerationOwnerKey(charId, sessionId = 'unknown', scopeName = 'chat') {
    return `${scopeName}:${charId}:${sessionId}`;
}

function createGenerationRequestToken(ownerKey, genId) {
    return `${ownerKey}:${genId}`;
}

function matchesExpectedState(currentMeta, expected) {
    if (!currentMeta) return false;
    if (expected === null || expected === undefined) return true;
    if (typeof expected !== 'object') {
        return currentMeta.genId === expected;
    }

    if (expected.genId !== undefined && currentMeta.genId !== expected.genId) return false;
    if (expected.requestToken !== undefined && currentMeta.requestToken !== expected.requestToken) return false;
    if (expected.ownerKey !== undefined && currentMeta.ownerKey !== expected.ownerKey) return false;
    if (expected.sessionId !== undefined && currentMeta.sessionId !== expected.sessionId) return false;
    if (expected.type !== undefined && currentMeta.type !== expected.type) return false;

    return true;
}

function getGeneratingStorageKey(charId, sessionId) {
    return `gz_generating_${charId}_${sessionId}`;
}

export function nextGenerationId() {
    generationIdCounter += 1;
    return generationIdCounter;
}

export { buildGenerationOwnerKey, createGenerationRequestToken };

export function listGeneratingCharIds() {
    return Object.keys(generationMeta);
}

export function getGenerationState(charId) {
    return generationMeta[charId] || null;
}

export function hasGenerationState(charId) {
    return !!generationMeta[charId];
}

export function setGenerationState(charId, state) {
    generationMeta[charId] = state;
    if (state?.controller) {
        const opId = `gen:${charId}`;
        if (!scope.isActive(opId)) {
            scope.register(opId, state.controller);
        }
    }
    return generationMeta[charId];
}

export function isGenerationStateCurrent(charId, expected = null) {
    return matchesExpectedState(generationMeta[charId], expected);
}

export function clearGenerationState(charId, expectedGenId = null) {
    const currentMeta = generationMeta[charId];
    if (!currentMeta) return false;
    if (!matchesExpectedState(currentMeta, expectedGenId)) return false;

    const opId = `gen:${charId}`;
    if (scope.isActive(opId)) {
        scope.complete(opId);
    }

    delete generationMeta[charId];
    return true;
}

export function markGenerationPersisted(charId, sessionId) {
    localStorage.setItem(getGeneratingStorageKey(charId, sessionId), 'true');
}

export function clearPersistedGeneration(charId, sessionId) {
    localStorage.removeItem(getGeneratingStorageKey(charId, sessionId));
}

export function getGenerationScope() {
    return scope;
}
