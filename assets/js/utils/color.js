import { clamp } from "./dom.js";

export const cssVar = (name, fallback) => {
  const value = window.getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return value || fallback;
};

const parseRgbColor = (value) => {
  if (!value) {
    return null;
  }

  const hex = value.match(/^#([0-9a-f]{6})$/i);

  if (hex) {
    return {
      r: Number.parseInt(hex[1].slice(0, 2), 16),
      g: Number.parseInt(hex[1].slice(2, 4), 16),
      b: Number.parseInt(hex[1].slice(4, 6), 16)
    };
  }

  const rgb = value.match(/^rgba?\((\d+),\s*(\d+),\s*(\d+)/i);

  if (!rgb) {
    return null;
  }

  return {
    r: Number.parseInt(rgb[1], 10),
    g: Number.parseInt(rgb[2], 10),
    b: Number.parseInt(rgb[3], 10)
  };
};

export const normalizeMonacoColor = (value, fallback) => {
  const rgb = parseRgbColor(value);

  if (!rgb) {
    return fallback;
  }

  return `#${[rgb.r, rgb.g, rgb.b]
    .map((channel) => clamp(channel, 0, 255).toString(16).padStart(2, "0"))
    .join("")}`;
};
