export const normalizeShortcutKey = (key) => String(key || "").toLowerCase();

export const shortcutTargetIsEditable = (event) => {
  const tag = event.target?.tagName || null;
  return event.target?.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(tag);
};

export const shortcutMatchesEvent = (shortcut, event) => {
  const primary = event.metaKey || event.ctrlKey;

  return (
    normalizeShortcutKey(event.key) === normalizeShortcutKey(shortcut.key) &&
    primary === Boolean(shortcut.primary) &&
    event.shiftKey === Boolean(shortcut.shift) &&
    event.altKey === Boolean(shortcut.alt)
  );
};

export const parseShortcutConfig = (value) => {
  if (!value) {
    return [];
  }

  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed : [];
  } catch (_error) {
    return [];
  }
};
