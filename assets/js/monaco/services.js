import { ensureMonacoTheme } from "./theme.js";
import { registerLiquidLanguage, registerMarkdownWithMacrosLanguage } from "./languages.js";

let monacoLoaderPromise;
const monacoEditors = new Map();

const monacoWorkerUrls = {
  editor: "/assets/monaco/editor.worker.js",
  css: "/assets/monaco/css.worker.js",
  html: "/assets/monaco/html.worker.js",
  json: "/assets/monaco/json.worker.js",
  ts: "/assets/monaco/ts.worker.js"
};

const workerNameForLanguage = (label) => {
  switch (label) {
    case "css":
    case "scss":
    case "less":
      return "css";
    case "html":
    case "handlebars":
    case "razor":
      return "html";
    case "json":
      return "json";
    case "typescript":
    case "javascript":
      return "ts";
    default:
      return "editor";
  }
};

const ensureMonacoEnvironment = () => {
  if (globalThis.MonacoEnvironment?.getWorker) {
    return;
  }

  globalThis.MonacoEnvironment = {
    ...globalThis.MonacoEnvironment,
    getWorker(_workerId, label) {
      const workerName = workerNameForLanguage(label);
      return new Worker(monacoWorkerUrls[workerName], { name: label, type: "module" });
    }
  };
};

export const loadMonaco = () => {
  ensureMonacoEnvironment();

  if (window.monaco?.editor) {
    ensureMonacoTheme(window.monaco);
    registerLiquidLanguage(window.monaco);
    registerMarkdownWithMacrosLanguage(window.monaco);
    return Promise.resolve(window.monaco);
  }

  if (monacoLoaderPromise) {
    return monacoLoaderPromise;
  }

  monacoLoaderPromise = import("/assets/monaco.js")
    .then((monaco) => {
      window.monaco = monaco;
      if (!monaco.editor) throw new Error("Monaco loaded but monaco.editor is missing");
      ensureMonacoTheme(monaco);
      registerLiquidLanguage(monaco);
      registerMarkdownWithMacrosLanguage(monaco);
      return monaco;
    })
    .catch((error) => {
      console.error("Monaco load failed:", error);
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
