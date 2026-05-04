import {
  loadMonaco,
  ensureMonacoTheme,
  registerMonacoEditor,
  unregisterMonacoEditor
} from "../monaco/services.js";

export const MonacoEditor = {
  mounted() {
    this.textarea = document.getElementById(this.el.dataset.monacoInputId) || this.el.querySelector("textarea");
    this.host = this.el.querySelector(".monaco-editor-instance");
    this.language = this.el.dataset.monacoLanguage || "plaintext";
    this.wordWrap = this.el.dataset.monacoWordWrap || "off";
    this.editorId = this.el.dataset.monacoEditorId || "";
    this.insertEvent = this.el.dataset.monacoInsertEvent || "";
    this.syncTimer = null;
    this.isApplyingRemoteUpdate = false;
    this.lastKnownValue = this.textarea?.value || "";

    this.syncEditorFromTextarea = () => {
      this.textarea = document.getElementById(this.el.dataset.monacoInputId) || this.el.querySelector("textarea");

      if (!this.textarea || !this.editor) {
        return;
      }

      const value = this.textarea.value || "";

      if (this.editor.getValue() !== value) {
        this.isApplyingRemoteUpdate = true;
        this.editor.setValue(value);
        this.isApplyingRemoteUpdate = false;
      }

      this.lastKnownValue = value;
    };

    this.layoutEditorSoon = () => {
      window.requestAnimationFrame(() => {
        window.requestAnimationFrame(() => {
          if (!this.editor) {
            return;
          }

          this.editor.layout();
        });
      });
    };

    this.waitForMonacoVisibleSize = () =>
      new Promise((resolve) => {
        let settled = false;
        let attempts = 0;

        const hasVisibleSize = () => {
          const rect = this.host?.getBoundingClientRect();
          return Boolean(rect && rect.width > 0 && rect.height > 0);
        };

        const finish = () => {
          if (settled) {
            return;
          }

          settled = true;
          this.visibleSizeObserver?.disconnect();
          this.visibleSizeObserver = null;
          resolve();
        };

        const check = () => {
          if (hasVisibleSize() || attempts >= 20) {
            finish();
            return;
          }

          attempts += 1;
          window.requestAnimationFrame(check);
        };

        if (hasVisibleSize()) {
          finish();
          return;
        }

        if (window.ResizeObserver && this.host) {
          this.visibleSizeObserver = new ResizeObserver(() => {
            if (hasVisibleSize()) {
              finish();
            }
          });
          this.visibleSizeObserver.observe(this.host);
        }

        window.requestAnimationFrame(check);
      });

    this.queueSync = () => {
      if (!this.textarea || !this.editor) {
        return;
      }

      window.clearTimeout(this.syncTimer);
      this.syncTimer = window.setTimeout(() => {
        if (!this.textarea || !this.editor) {
          return;
        }

        const value = this.editor.getValue();

        if (this.textarea.value === value) {
          return;
        }

        this.lastKnownValue = value;
        this.textarea.value = value;
        this.textarea.dispatchEvent(new Event("input", { bubbles: true }));
      }, 120);
    };

    this.handleInsert = ({ id, content }) => {
      if (!this.editor || !content || String(id) !== String(this.editorId)) {
        return;
      }

      const model = this.editor.getModel();
      const selection = this.editor.getSelection();

      if (!model || !selection) {
        return;
      }

      const value = this.editor.getValue();
      const start = model.getOffsetAt(selection.getStartPosition());
      const end = model.getOffsetAt(selection.getEndPosition());
      const before = value.slice(0, start);
      const after = value.slice(end);
      const separator = before !== "" && !before.endsWith("\n") ? "\n" : "";
      const suffix = after !== "" && !content.endsWith("\n") ? "\n" : "";
      const inserted = `${separator}${content}${suffix}`;
      this.editor.executeEdits("bds-insert-content", [
        {
          range: selection,
          text: inserted,
          forceMoveMarkers: true
        }
      ]);
      this.editor.focus();
    };

    loadMonaco()
      .then(async (monaco) => {
        if (!this.host || !this.textarea) {
          return;
        }

        await this.waitForMonacoVisibleSize();

        ensureMonacoTheme(monaco);

        this.editor = monaco.editor.create(this.host, {
          value: this.textarea.value || "",
          language: this.language,
          theme: "bds-theme",
          automaticLayout: true,
          minimap: { enabled: false },
          scrollBeyondLastLine: false,
          wordWrap: this.wordWrap,
          lineNumbers: "on",
          lineNumbersMinChars: 3,
          fontSize: 14,
          fontFamily: "'Cascadia Code', 'Consolas', 'Courier New', monospace",
          padding: { top: 12, bottom: 12 },
          roundedSelection: false,
          renderLineHighlight: "line",
          formatOnPaste: true,
          cursorStyle: "line",
          cursorBlinking: "smooth",
          quickSuggestions: this.language === "markdown-with-macros" ? false : true,
          tabSize: 2,
          insertSpaces: true
        });

        registerMonacoEditor(this.editorId || this.el.id, this.editor);
        monaco.editor.setTheme("bds-theme");
        this.syncEditorFromTextarea();
        this.layoutEditorSoon();

        this.changeSubscription = this.editor.onDidChangeModelContent(() => {
          if (this.isApplyingRemoteUpdate) {
            return;
          }

          this.queueSync();
        });

        if (this.insertEvent) {
          this.handleEvent(this.insertEvent, this.handleInsert);
        }
      })
      .catch((error) => {
        console.error("Failed to load Monaco editor", error);
      });
  },

  updated() {
    this.textarea = document.getElementById(this.el.dataset.monacoInputId) || this.el.querySelector("textarea");
    this.host = this.el.querySelector(".monaco-editor-instance");
    this.language = this.el.dataset.monacoLanguage || this.language || "plaintext";
    this.wordWrap = this.el.dataset.monacoWordWrap || this.wordWrap || "off";

    if (!this.editor || !this.textarea) {
      return;
    }

    loadMonaco().then((monaco) => {
      ensureMonacoTheme(monaco);
      monaco.editor.setTheme("bds-theme");

      if (this.editor.getModel()?.getLanguageId() !== this.language) {
        monaco.editor.setModelLanguage(this.editor.getModel(), this.language);
      }

      this.editor.updateOptions({ wordWrap: this.wordWrap });
    });

    this.syncEditorFromTextarea();
    this.layoutEditorSoon();
  },

  destroyed() {
    window.clearTimeout(this.syncTimer);
    this.visibleSizeObserver?.disconnect();
    this.changeSubscription?.dispose();
    unregisterMonacoEditor(this.editorId || this.el.id);
    this.editor?.dispose();
  }
};
