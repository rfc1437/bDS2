import { clamp } from "./dom.js";
import { SIDEBAR_STORAGE_KEY, ASSISTANT_STORAGE_KEY } from "../constants.js";

export const shellWidth = (selector) => {
  const shell = document.querySelector(selector);

  if (!shell) {
    return 0;
  }

  const width = Number.parseInt(shell.style.width || "0", 10);
  return Number.isNaN(width) ? Math.round(shell.getBoundingClientRect().width) : width;
};

export const setShellWidth = (selector, width) => {
  const shell = document.querySelector(selector);

  if (shell) {
    shell.style.width = `${width}px`;
    shell.classList.remove("is-hidden");
  }
};

export const persistWidth = (target, width) => {
  const key = target === "assistant" ? ASSISTANT_STORAGE_KEY : SIDEBAR_STORAGE_KEY;
  window.localStorage.setItem(key, String(width));
};

export const readStoredSize = (key, fallback, min, max) => {
  const raw = window.localStorage.getItem(key);

  if (!raw) {
    return fallback;
  }

  const parsed = Number.parseInt(raw, 10);

  if (Number.isNaN(parsed)) {
    return fallback;
  }

  return clamp(parsed, min, max);
};
