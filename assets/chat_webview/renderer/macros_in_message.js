export function formatMessageBody(
  formatter,
  text,
  isUser,
  isReasoning = false,
  useCache = true,
) {
  return formatter.format(text || '', isUser, isReasoning, useCache);
}
