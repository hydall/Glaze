export function formatMessageBody(formatter, text, isUser) {
  return formatter.format(text || '', isUser);
}
