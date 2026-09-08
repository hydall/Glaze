export function roleKey(role) {
  if (role === 'user') return 'user';
  if (role === 'system') return 'system';
  return 'char';
}

export function isUserRole(role) {
  return role === 'user';
}

export function memoryStatusClass(status) {
  const s = (status || '').toLowerCase();
  if (s === 'mem') return 'covered';
  if (s === 'pending') return 'pending';
  if (s === 'draft') return 'draft-memory';
  if (s === 'stale') return 'stale';
  if (s === 'rebuild') return 'needs-rebuild';
  return 'covered';
}

export function defaultName(role) {
  if (role === 'user') return 'You';
  if (role === 'system') return 'System';
  return 'Character';
}

export function formatTime(timestamp) {
  if (!timestamp) return '';
  const d = new Date(timestamp);
  const hh = String(d.getHours()).padStart(2, '0');
  const mm = String(d.getMinutes()).padStart(2, '0');
  return `${hh}:${mm}`;
}

export function formatDate(timestamp) {
  if (!timestamp) return null;
  const d = new Date(timestamp);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

export function formatDateDisplay(dateStr) {
  const date = new Date(dateStr + 'T00:00:00');
  const today = new Date();
  const yesterday = new Date(today); yesterday.setDate(yesterday.getDate() - 1);
  if (date.toDateString() === today.toDateString()) return 'Today';
  if (date.toDateString() === yesterday.toDateString()) return 'Yesterday';
  const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  return `${months[date.getMonth()]} ${date.getDate()}, ${date.getFullYear()}`;
}
