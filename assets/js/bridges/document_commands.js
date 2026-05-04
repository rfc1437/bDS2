import { clamp } from "../utils/dom.js";

export const applyAppZoom = (nextZoom) => {
  const zoom = clamp(Math.round(nextZoom * 100) / 100, 0.5, 2);
  window.__bdsAppZoom = zoom;
  document.documentElement.style.zoom = String(zoom);
};

export const runDocumentCommand = (command) => {
  if (typeof document.execCommand !== "function") {
    return false;
  }

  try {
    return document.execCommand(command);
  } catch (_error) {
    return false;
  }
};
