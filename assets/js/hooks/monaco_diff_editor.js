import { loadMonaco, ensureMonacoTheme, diffModelPath } from "../monaco/services.js";

export const MonacoDiffEditor = {
  mounted() {
    this.host = this.el.querySelector(".monaco-diff-editor-instance");
    this.originalInput = this.el.querySelector(".monaco-diff-original");
    this.modifiedInput = this.el.querySelector(".monaco-diff-modified");
    this.filePath = this.el.dataset.monacoDiffFilePath || "working-tree";
    this.language = this.el.dataset.monacoDiffLanguage || "plaintext";
    this.viewStyle = this.el.dataset.monacoDiffViewStyle || "inline";
    this.wordWrap = this.el.dataset.monacoDiffWordWrap || "off";
    this.hideUnchanged = this.el.dataset.monacoDiffHideUnchanged === "true";

    this.readValues = () => ({
      original: this.originalInput?.value || "",
      modified: this.modifiedInput?.value || ""
    });

    this.applyDataset = () => {
      this.filePath = this.el.dataset.monacoDiffFilePath || "working-tree";
      this.language = this.el.dataset.monacoDiffLanguage || "plaintext";
      this.viewStyle = this.el.dataset.monacoDiffViewStyle || "inline";
      this.wordWrap = this.el.dataset.monacoDiffWordWrap || "off";
      this.hideUnchanged = this.el.dataset.monacoDiffHideUnchanged === "true";
    };

    this.setModels = (monaco) => {
      const values = this.readValues();

      this.originalModel?.dispose();
      this.modifiedModel?.dispose();

      this.originalModel = monaco.editor.createModel(
        values.original,
        this.language,
        monaco.Uri.parse(diffModelPath(this.filePath, "original"))
      );

      this.modifiedModel = monaco.editor.createModel(
        values.modified,
        this.language,
        monaco.Uri.parse(diffModelPath(this.filePath, "modified"))
      );

      this.editor.setModel({ original: this.originalModel, modified: this.modifiedModel });
      this.lastFilePath = this.filePath;
    };

    loadMonaco()
      .then((monaco) => {
        if (!this.host) {
          return;
        }

        ensureMonacoTheme(monaco);

        this.editor = monaco.editor.createDiffEditor(this.host, {
          theme: "bds-theme",
          automaticLayout: true,
          readOnly: true,
          renderSideBySide: this.viewStyle === "side-by-side",
          minimap: { enabled: false },
          scrollBeyondLastLine: false,
          lineNumbers: "on",
          diffCodeLens: false,
          originalEditable: false,
          wordWrap: this.wordWrap,
          hideUnchangedRegions: { enabled: this.hideUnchanged },
          ignoreTrimWhitespace: false
        });

        this.setModels(monaco);
      })
      .catch((error) => {
        console.error("Failed to load Monaco diff editor", error);
      });
  },

  updated() {
    this.host = this.el.querySelector(".monaco-diff-editor-instance");
    this.originalInput = this.el.querySelector(".monaco-diff-original");
    this.modifiedInput = this.el.querySelector(".monaco-diff-modified");
    this.applyDataset();

    if (!this.editor) {
      return;
    }

    loadMonaco().then((monaco) => {
      ensureMonacoTheme(monaco);
      monaco.editor.setTheme("bds-theme");

      this.editor.updateOptions({
        renderSideBySide: this.viewStyle === "side-by-side",
        wordWrap: this.wordWrap,
        hideUnchangedRegions: { enabled: this.hideUnchanged }
      });

      if (this.lastFilePath !== this.filePath) {
        this.setModels(monaco);
        return;
      }

      const values = this.readValues();

      if (this.originalModel && this.originalModel.getLanguageId() !== this.language) {
        monaco.editor.setModelLanguage(this.originalModel, this.language);
      }

      if (this.modifiedModel && this.modifiedModel.getLanguageId() !== this.language) {
        monaco.editor.setModelLanguage(this.modifiedModel, this.language);
      }

      if (this.originalModel && this.originalModel.getValue() !== values.original) {
        this.originalModel.setValue(values.original);
      }

      if (this.modifiedModel && this.modifiedModel.getValue() !== values.modified) {
        this.modifiedModel.setValue(values.modified);
      }
    });
  },

  destroyed() {
    this.originalModel?.dispose();
    this.modifiedModel?.dispose();
    this.editor?.dispose();
  }
};
