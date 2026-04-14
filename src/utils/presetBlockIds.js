const ST_TO_INTERNAL_BLOCK_ID = {
    personaDescription: 'user_persona',
    charDescription: 'char_card',
    charPersonality: 'char_personality',
    dialogueExamples: 'example_dialogue',
    chatHistory: 'chat_history'
};

export function normalizeBlockId(blockId) {
    return ST_TO_INTERNAL_BLOCK_ID[blockId] || blockId;
}
