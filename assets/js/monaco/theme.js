import { cssVar, normalizeMonacoColor } from "../utils/color.js";

let monacoThemeSignature = null;

export const ensureMonacoTheme = (monaco) => {
  const background = normalizeMonacoColor(
    cssVar("--vscode-editor-background", cssVar("--vscode-input-background", "#1e1e1e")),
    "#1e1e1e"
  );
  const foreground = normalizeMonacoColor(cssVar("--vscode-editor-foreground", "#d4d4d4"), "#d4d4d4");
  const lineNumber = normalizeMonacoColor(cssVar("--vscode-editorLineNumber-foreground", "#858585"), "#858585");
  const activeLineNumber = normalizeMonacoColor(
    cssVar("--vscode-editorLineNumber-activeForeground", foreground),
    foreground
  );
  const selection = normalizeMonacoColor(cssVar("--vscode-editor-selectionBackground", "#264f78"), "#264f78");
  const inactiveSelection = normalizeMonacoColor(
    cssVar("--vscode-editor-inactiveSelectionBackground", "#3a3d41"),
    "#3a3d41"
  );
  const cursor = normalizeMonacoColor(cssVar("--vscode-editorCursor-foreground", foreground), foreground);
  const border = normalizeMonacoColor(cssVar("--vscode-panel-border", "#3c3c3c"), "#3c3c3c");
  const lineHighlight = normalizeMonacoColor(
    cssVar("--vscode-editor-lineHighlightBackground", background),
    background
  );
  const signature = [background, foreground, lineNumber, activeLineNumber, selection, inactiveSelection, cursor, border].join("|");

  if (signature === monacoThemeSignature) {
    monaco.editor.setTheme("bds-theme");
    return;
  }

  monaco.editor.defineTheme("bds-theme", {
    base: "vs-dark",
    inherit: true,
    rules: [
      { token: "keyword.macro", foreground: "C586C0", fontStyle: "bold" },
      { token: "attribute.name", foreground: "9CDCFE" },
      { token: "attribute.value", foreground: "CE9178" }
    ],
    colors: {
      "editor.background": background,
      "editor.foreground": foreground,
      "editor.lineHighlightBackground": lineHighlight,
      "editorCursor.foreground": cursor,
      "editor.selectionBackground": selection,
      "editor.inactiveSelectionBackground": inactiveSelection,
      "editorLineNumber.foreground": lineNumber,
      "editorLineNumber.activeForeground": activeLineNumber,
      "editorIndentGuide.background1": border,
      "editorIndentGuide.activeBackground1": foreground,
      "editorWidget.border": border,
      "editorGutter.background": background,
      "focusBorder": border,
      "input.border": border
    }
  });

  monacoThemeSignature = signature;
  monaco.editor.setTheme("bds-theme");
};
