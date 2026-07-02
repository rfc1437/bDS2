// ESM entry point for Monaco. Bundled by esbuild into priv/static/assets/monaco.js
// editor.main.js loads the API AND registers all bundled languages (api.js only exposes the API)
export * from "monaco-editor/esm/vs/editor/editor.main.js";
