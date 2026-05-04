import { loadScript } from "../utils/script_loader.js";
import { ensureMonacoTheme } from "./theme.js";
import { registerLiquidLanguage, registerMarkdownWithMacrosLanguage } from "./languages.js";

let monacoLoaderPromise;
const monacoEditors = new Map();

export const loadMonaco = () => {
  if (window.monaco?.editor) {
    ensureMonacoTheme(window.monaco);
    registerLiquidLanguage(window.monaco);
    registerMarkdownWithMacrosLanguage(window.monaco);
    return Promise.resolve(window.monaco);
  }

  if (monacoLoaderPromise) {
    return monacoLoaderPromise;
  }

  monacoLoaderPromise = loadScript("/monaco/vs/loader.js")
    .then(
      () =>
        new Promise((resolve, reject) => {
          window.require.config({ paths: { vs: "/monaco/vs" } });
          window.require(["vs/editor/editor.main"], () => {
            ensureMonacoTheme(window.monaco);
            registerLiquidLanguage(window.monaco);
            registerMarkdownWithMacrosLanguage(window.monaco);
            resolve(window.monaco);
          }, reject);
        })
    )
    .catch((error) => {
      monacoLoaderPromise = null;
      throw error;
    });

  return monacoLoaderPromise;
};

export const registerMonacoEditor = (key, editor) => {
  if (key) {
    monacoEditors.set(key, editor);
  }
};

export const unregisterMonacoEditor = (key) => {
  if (key) {
    monacoEditors.delete(key);
  }
};

export const activeMonacoEditor = () => {
  for (const editor of monacoEditors.values()) {
    if (typeof editor?.hasTextFocus === "function" && editor.hasTextFocus()) {
      return editor;
    }
  }

  return null;
};

export const runMonacoEditorAction = (editor, actionId, triggerId = actionId) => {
  if (!editor) {
    return false;
  }

  const action = typeof editor.getAction === "function" ? editor.getAction(actionId) : null;

  if (action && typeof action.run === "function") {
    action.run();
    return true;
  }

  if (typeof editor.trigger === "function") {
    editor.trigger("bds-menu", triggerId, null);
    return true;
  }

  return false;
};

export const diffModelPath = (filePath, side) => {
  const normalized = String(filePath || "working-tree").replace(/^\/+/, "");
  return `inmemory://model/git-diff/${side}/${normalized}`;
};

export { ensureMonacoTheme };
