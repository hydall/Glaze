export function formatMessageBody(formatter, text, isUser, isReasoning = false) {
  return formatter.format(text || '', isUser, isReasoning);
}
