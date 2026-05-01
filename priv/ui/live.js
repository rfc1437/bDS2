document.addEventListener("DOMContentLoaded", () => {
  const csrfToken = document
    .querySelector("meta[name='csrf-token']")
    .getAttribute("content");

  const SIDEBAR_STORAGE_KEY = "bds-panel-sidebar";
  const ASSISTANT_STORAGE_KEY = "bds-panel-assistant-sidebar";
  const UI_LANGUAGE_STORAGE_KEY = "bds-ui-language";
  const WORKBENCH_SESSION_STORAGE_KEY_PREFIX = "bds-workbench-";

  const parseShortcutConfig = (value) => {
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

  const parseJsonObject = (value) => {
    if (!value) {
      return null;
    }

    try {
      const parsed = JSON.parse(value);
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : null;
    } catch (_error) {
      return null;
    }
  };

  const setMediaThumbnailLoaded = (image, loaded) => {
    const thumbnail = image?.closest(".media-thumbnail");

    if (!thumbnail) {
      return;
    }

    if (loaded) {
      thumbnail.classList.add("is-loaded");
    } else {
      thumbnail.classList.remove("is-loaded");
    }
  };

  const syncMediaThumbnailState = (root) => {
    root.querySelectorAll(".media-thumbnail-image").forEach((image) => {
      setMediaThumbnailLoaded(image, Boolean(image.complete && image.naturalWidth > 0));
    });
  };

  const normalizeShortcutKey = (key) => String(key || "").toLowerCase();

  const shortcutTargetIsEditable = (event) => {
    const tag = event.target?.tagName || null;
    return event.target?.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(tag);
  };

  const shortcutMatchesEvent = (shortcut, event) => {
    const primary = event.metaKey || event.ctrlKey;

    return (
      normalizeShortcutKey(event.key) === normalizeShortcutKey(shortcut.key) &&
      primary === Boolean(shortcut.primary) &&
      event.shiftKey === Boolean(shortcut.shift) &&
      event.altKey === Boolean(shortcut.alt)
    );
  };

  const clamp = (value, min, max) => Math.max(min, Math.min(value, max));

  const readStoredSize = (key, fallback, min, max) => {
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

  const shellWidth = (selector) => {
    const shell = document.querySelector(selector);

    if (!shell) {
      return 0;
    }

    const width = Number.parseInt(shell.style.width || "0", 10);
    return Number.isNaN(width) ? Math.round(shell.getBoundingClientRect().width) : width;
  };

  const setShellWidth = (selector, width) => {
    const shell = document.querySelector(selector);

    if (shell) {
      shell.style.width = `${width}px`;
      shell.classList.remove("is-hidden");
    }
  };

  const persistWidth = (target, width) => {
    const key = target === "assistant" ? ASSISTANT_STORAGE_KEY : SIDEBAR_STORAGE_KEY;
    window.localStorage.setItem(key, String(width));
  };

  const syncTitlebarOverlayInsets = () => {
    const rootStyle = document.documentElement.style;
    const setInsets = (left, right) => {
      rootStyle.setProperty("--bds-titlebar-overlay-left", `${left}px`);
      rootStyle.setProperty("--bds-titlebar-overlay-right", `${right}px`);
    };

    const overlay = navigator.windowControlsOverlay;

    if (!overlay) {
      setInsets(0, 0);
      return () => {};
    }

    const updateInsets = () => {
      if (!overlay.visible) {
        setInsets(0, 0);
        return;
      }

      const titlebarRect = overlay.getTitlebarAreaRect();
      const viewportWidth = window.innerWidth || document.documentElement.clientWidth || titlebarRect.right;
      const leftInset = Math.max(0, Math.round(titlebarRect.left));
      const rightInset = Math.max(0, Math.round(viewportWidth - titlebarRect.right));
      setInsets(leftInset, rightInset);
    };

    const onGeometryChange = () => updateInsets();
    const onResize = () => updateInsets();

    updateInsets();
    overlay.addEventListener("geometrychange", onGeometryChange);
    window.addEventListener("resize", onResize);

    return () => {
      overlay.removeEventListener("geometrychange", onGeometryChange);
      window.removeEventListener("resize", onResize);
    };
  };

  let monacoLoaderPromise;
  let liquidLanguageRegistered = false;
  let markdownWithMacrosRegistered = false;
  let monacoThemeSignature = null;

  const cssVar = (name, fallback) => {
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

  const colorIsDark = (value) => {
    const rgb = parseRgbColor(value);

    if (!rgb) {
      return true;
    }

    const luminance = (0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b) / 255;
    return luminance < 0.5;
  };

  const loadScript = (src) =>
    new Promise((resolve, reject) => {
      const existing = document.querySelector(`script[src="${src}"]`);

      if (existing) {
        if (existing.dataset.loaded === "true") {
          resolve();
          return;
        }

        existing.addEventListener("load", () => resolve(), { once: true });
        existing.addEventListener("error", () => reject(new Error(`Failed to load ${src}`)), {
          once: true
        });
        return;
      }

      const script = document.createElement("script");
      script.src = src;
      script.async = true;
      script.addEventListener(
        "load",
        () => {
          script.dataset.loaded = "true";
          resolve();
        },
        { once: true }
      );
      script.addEventListener("error", () => reject(new Error(`Failed to load ${src}`)), {
        once: true
      });
      document.head.appendChild(script);
    });

  const diffModelPath = (filePath, side) => {
    const normalized = String(filePath || "working-tree").replace(/^\/+/, "");
    return `inmemory://model/git-diff/${side}/${normalized}`;
  };

  const registerLiquidLanguage = (monaco) => {
    if (liquidLanguageRegistered) {
      return;
    }

    monaco.languages.register({ id: "liquid" });
    monaco.languages.setLanguageConfiguration("liquid", {
      comments: {
        blockComment: ["{% comment %}", "{% endcomment %}"]
      },
      brackets: [
        ["{", "}"],
        ["[", "]"],
        ["(", ")"]
      ],
      autoClosingPairs: [
        { open: "{", close: "}" },
        { open: "[", close: "]" },
        { open: "(", close: ")" },
        { open: '"', close: '"' },
        { open: "'", close: "'" }
      ],
      surroundingPairs: [
        { open: "{", close: "}" },
        { open: "[", close: "]" },
        { open: "(", close: ")" },
        { open: '"', close: '"' },
        { open: "'", close: "'" }
      ]
    });

    monaco.languages.setMonarchTokensProvider("liquid", {
      defaultToken: "",
      tokenizer: {
        root: [
          [/\{\{-?/, { token: "delimiter.output", next: "@liquidOutput" }],
          [/\{%-?\s*comment\b[^%]*-?%\}/, { token: "comment.block", next: "@liquidComment" }],
          [/\{%-?/, { token: "delimiter.tag", next: "@liquidTag" }],
          [/<!DOCTYPE/i, "metatag"],
          [/<!--/, { token: "comment", next: "@htmlComment" }],
          [/(<)(script)/i, ["delimiter.html", "tag.html"], "@scriptTag"],
          [/(<)(style)/i, ["delimiter.html", "tag.html"], "@styleTag"],
          [/(<\/)([\w:-]+)/, ["delimiter.html", "tag.html"]],
          [/(<)([\w:-]+)/, ["delimiter.html", "tag.html"], "@htmlTag"],
          [/[^<{]+/, ""],
          [/./, ""]
        ],
        liquidOutput: [
          [/-?\}\}/, { token: "delimiter.output", next: "@pop" }],
          [/\|\s*[a-zA-Z_][\w-]*/, "keyword"],
          [/\b(?:true|false|nil|blank|empty)\b/, "keyword"],
          [/\b\d+(?:\.\d+)?\b/, "number"],
          [/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, "string"],
          [/[a-zA-Z_][\w.-]*/, "identifier"],
          [/[,:()[\]]/, "delimiter"]
        ],
        liquidTag: [
          [/-?%\}/, { token: "delimiter.tag", next: "@pop" }],
          [/\b(?:assign|capture|case|comment|cycle|decrement|echo|elsif|else|endcase|endcapture|endif|endfor|endunless|endcomment|for|if|include|increment|liquid|paginate|raw|render|tablerow|unless|when)\b/, "keyword"],
          [/\|\s*[a-zA-Z_][\w-]*/, "keyword"],
          [/\b(?:true|false|nil|blank|empty|contains)\b/, "keyword"],
          [/\b\d+(?:\.\d+)?\b/, "number"],
          [/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, "string"],
          [/[><=!]=?|\.|:/, "operator"],
          [/[a-zA-Z_][\w.-]*/, "identifier"],
          [/[,:()[\]]/, "delimiter"]
        ],
        liquidComment: [
          [/\{%-?\s*endcomment\s*-?%\}/, { token: "comment.block", next: "@pop" }],
          [/./, "comment.block"]
        ],
        htmlComment: [
          [/-->/, { token: "comment", next: "@pop" }],
          [/./, "comment"]
        ],
        htmlTag: [
          [/\/>/, { token: "delimiter.html", next: "@pop" }],
          [/>/, { token: "delimiter.html", next: "@pop" }],
          [/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, "attribute.value"],
          [/[\w:-]+/, "attribute.name"],
          [/=/, "delimiter"]
        ],
        scriptTag: [
          [/>/, { token: "delimiter.html", next: "@pop" }],
          [/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, "attribute.value"],
          [/[\w:-]+/, "attribute.name"],
          [/=/, "delimiter"]
        ],
        styleTag: [
          [/>/, { token: "delimiter.html", next: "@pop" }],
          [/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, "attribute.value"],
          [/[\w:-]+/, "attribute.name"],
          [/=/, "delimiter"]
        ]
      }
    });

    liquidLanguageRegistered = true;
  };

  const registerMarkdownWithMacrosLanguage = (monaco) => {
    if (markdownWithMacrosRegistered) {
      return;
    }

    monaco.languages.register({ id: "markdown-with-macros" });
    monaco.languages.setMonarchTokensProvider("markdown-with-macros", {
      defaultToken: "",
      tokenPostfix: ".md",
      tokenizer: {
        root: [
          [/\[\[[a-zA-Z][\w-]*/, { token: "keyword.macro", next: "@macroParams" }],
          [/^#{1,6}\s.*$/, "keyword.header"],
          [/^\s*>+/, "string.quote"],
          [/^\s*[-+*]\s/, "keyword"],
          [/^\s*\d+\.\s/, "keyword"],
          [/^\s*```\w*/, { token: "string.code", next: "@codeblock" }],
          [/\*\*[^*]+\*\*/, "strong"],
          [/\*[^*]+\*/, "emphasis"],
          [/__[^_]+__/, "strong"],
          [/_[^_]+_/, "emphasis"],
          [/`[^`]+`/, "variable"],
          [/!?\[[^\]]*\]\([^)]*\)/, "string.link"],
          [/!?\[[^\]]*\]\[[^\]]*\]/, "string.link"]
        ],
        macroParams: [
          [/\]\]/, { token: "keyword.macro", next: "@root" }],
          [/[a-zA-Z][\w-]*(?=\s*=)/, "attribute.name"],
          [/=/, "delimiter"],
          [/"[^"]*"/, "string"],
          [/\s+/, "white"],
          [/[^\]"=\s]+/, "attribute.value"]
        ],
        codeblock: [
          [/^\s*```\s*$/, { token: "string.code", next: "@root" }],
          [/.*$/, "variable.source"]
        ]
      }
    });

    markdownWithMacrosRegistered = true;
  };

  const ensureMonacoTheme = (monaco) => {
    const background = cssVar("--vscode-editor-background", cssVar("--vscode-input-background", "#1e1e1e"));
    const foreground = cssVar("--vscode-editor-foreground", "#d4d4d4");
    const lineNumber = cssVar("--vscode-editorLineNumber-foreground", "#858585");
    const activeLineNumber = cssVar("--vscode-editorLineNumber-activeForeground", foreground);
    const selection = cssVar("--vscode-editor-selectionBackground", "#264f78");
    const inactiveSelection = cssVar("--vscode-editor-inactiveSelectionBackground", "#3a3d41");
    const cursor = cssVar("--vscode-editorCursor-foreground", foreground);
    const border = cssVar("--vscode-panel-border", "#3c3c3c");
    const signature = [background, foreground, lineNumber, activeLineNumber, selection, inactiveSelection, cursor, border].join("|");

    if (signature === monacoThemeSignature) {
      monaco.editor.setTheme("bds-theme");
      return;
    }

    monaco.editor.defineTheme("bds-theme", {
      base: colorIsDark(background) ? "vs-dark" : "vs",
      inherit: true,
      rules: [
        { token: "keyword.macro", foreground: "C586C0", fontStyle: "bold" },
        { token: "attribute.name", foreground: "9CDCFE" },
        { token: "attribute.value", foreground: "CE9178" }
      ],
      colors: {
        "editor.background": background,
        "editor.foreground": foreground,
        "editor.lineHighlightBackground": cssVar("--vscode-editor-lineHighlightBackground", background),
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

  const loadMonaco = () => {
    if (window.monaco?.editor) {
      ensureMonacoTheme(window.monaco);
      registerLiquidLanguage(window.monaco);
      registerMarkdownWithMacrosLanguage(window.monaco);
      return Promise.resolve(window.monaco);
    }

    if (monacoLoaderPromise) {
      return monacoLoaderPromise;
    }

    monacoLoaderPromise = loadScript("/assets/monaco/vs/loader.js")
      .then(
        () =>
          new Promise((resolve, reject) => {
            window.require.config({ paths: { vs: "/assets/monaco/vs" } });
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

  const Hooks = {
    AppShell: {
      mounted() {
        this.shortcuts = parseShortcutConfig(this.el.dataset.shortcuts);
        this.currentProjectId = this.el.dataset.projectId || "";
        this.syncStoredLayout();
        this.syncStoredUiLanguage();
        this.destroyOverlaySync = syncTitlebarOverlayInsets();

        this.workbenchStorageKey = (projectId) =>
          projectId ? `${WORKBENCH_SESSION_STORAGE_KEY_PREFIX}${projectId}` : null;

        this.restoreStoredWorkbenchSession = () => {
          const projectId = this.el.dataset.projectId || "";
          const storageKey = this.workbenchStorageKey(projectId);

          if (!storageKey) {
            return false;
          }

          const session = parseJsonObject(window.localStorage.getItem(storageKey));

          if (!session) {
            return false;
          }

          this.pushEvent("restore_workbench_session", { session });
          return true;
        };

        this.persistWorkbenchSession = () => {
          const projectId = this.el.dataset.projectId || "";
          const storageKey = this.workbenchStorageKey(projectId);
          const session = this.el.dataset.workbenchSession;

          if (!storageKey || !session) {
            return;
          }

          window.localStorage.setItem(storageKey, session);
        };

        this.handleMouseDown = (event) => {
          const handle = event.target.closest("[data-role='resize-handle']");

          if (!handle || !this.el.contains(handle)) {
            return;
          }

          event.preventDefault();

          const target = handle.dataset.resize;
          const startX = event.clientX;
          const startWidth =
            target === "assistant"
              ? shellWidth("[data-testid='assistant-shell']")
              : shellWidth("[data-testid='sidebar-shell']");

          const min = target === "assistant" ? 280 : 200;
          const max = target === "assistant" ? 640 : 500;
          const invert = target === "assistant";

          const onMouseMove = (moveEvent) => {
            const delta = invert ? startX - moveEvent.clientX : moveEvent.clientX - startX;
            const width = clamp(startWidth + delta, min, max);
            const selector = target === "assistant" ? "[data-testid='assistant-shell']" : "[data-testid='sidebar-shell']";

            setShellWidth(selector, width);
            persistWidth(target, width);
          };

          const onMouseUp = (upEvent) => {
            const delta = invert ? startX - upEvent.clientX : upEvent.clientX - startX;
            const width = clamp(startWidth + delta, min, max);

            persistWidth(target, width);
            this.pushEvent("resize_panel", { target, width });

            window.removeEventListener("mousemove", onMouseMove);
            window.removeEventListener("mouseup", onMouseUp);
          };

          window.addEventListener("mousemove", onMouseMove);
          window.addEventListener("mouseup", onMouseUp);
        };

        this.el.addEventListener("mousedown", this.handleMouseDown);

        this.handleNativeMenuAction = (event) => {
          const action = event.detail?.action;
          const ackId = event.detail?.ackId;

          if (action) {
            this.pushEvent("native_menu_action", { action }, () => {
              if (ackId) {
                window.dispatchEvent(
                  new CustomEvent("bds:native-menu-action-ack", { detail: { ackId } })
                );
              }
            });
          }
        };

        this.handleChange = (event) => {
          const select = event.target.closest(".status-bar-language-select");

          if (select && this.el.contains(select)) {
            window.localStorage.setItem(UI_LANGUAGE_STORAGE_KEY, select.value);
          }
        };

        this.handleShortcutKeyDown = (event) => {
          if (shortcutTargetIsEditable(event)) {
            return;
          }

          const shortcut = this.shortcuts.find((candidate) => shortcutMatchesEvent(candidate, event));

          if (!shortcut) {
            return;
          }

          event.preventDefault();
          event.stopPropagation();

          this.pushEvent("shortcut", {
            key: normalizeShortcutKey(event.key),
            meta: event.metaKey,
            ctrl: event.ctrlKey,
            alt: event.altKey,
            shift: event.shiftKey,
            tag: event.target?.tagName || null,
            contentEditable: event.target?.isContentEditable || false
          });
        };

        this.handleThumbnailLoad = (event) => {
          if (event.target instanceof HTMLImageElement && event.target.classList.contains("media-thumbnail-image")) {
            setMediaThumbnailLoaded(event.target, true);
          }
        };

        this.handleThumbnailError = (event) => {
          if (event.target instanceof HTMLImageElement && event.target.classList.contains("media-thumbnail-image")) {
            setMediaThumbnailLoaded(event.target, false);
          }
        };

        window.addEventListener("bds:native-menu-action", this.handleNativeMenuAction);
        window.addEventListener("keydown", this.handleShortcutKeyDown, true);
        this.el.addEventListener("load", this.handleThumbnailLoad, true);
        this.el.addEventListener("error", this.handleThumbnailError, true);
        this.el.addEventListener("change", this.handleChange);
        syncMediaThumbnailState(this.el);
        this.restoreStoredWorkbenchSession();
      },

      updated() {
        const nextProjectId = this.el.dataset.projectId || "";

        if (nextProjectId !== this.currentProjectId) {
          this.currentProjectId = nextProjectId;

          if (this.restoreStoredWorkbenchSession()) {
            return;
          }
        }

        syncMediaThumbnailState(this.el);
        this.persistWorkbenchSession();
      },

      destroyed() {
        this.el.removeEventListener("mousedown", this.handleMouseDown);
        this.el.removeEventListener("load", this.handleThumbnailLoad, true);
        this.el.removeEventListener("error", this.handleThumbnailError, true);
        this.el.removeEventListener("change", this.handleChange);
        window.removeEventListener("bds:native-menu-action", this.handleNativeMenuAction);
        window.removeEventListener("keydown", this.handleShortcutKeyDown, true);
        if (this.destroyOverlaySync) {
          this.destroyOverlaySync();
        }
      },

      syncStoredLayout() {
        this.pushEvent("sync_layout", {
          sidebar_width: readStoredSize(SIDEBAR_STORAGE_KEY, shellWidth("[data-testid='sidebar-shell']"), 200, 500),
          assistant_sidebar_width: readStoredSize(ASSISTANT_STORAGE_KEY, 360, 280, 640)
        });
      },

      syncStoredUiLanguage() {
        const stored = window.localStorage.getItem(UI_LANGUAGE_STORAGE_KEY);

        if (stored) {
          this.pushEvent("sync_ui_language", { language: stored });
        }
      }
    },

    SidebarInteractions: {
      mounted() {
        this.handleDblClick = (event) => {
          const button = event.target.closest("[data-testid='sidebar-open-item']");

          if (!button || !this.el.contains(button)) {
            return;
          }

          this.pushEvent("pin_sidebar_item", {
            route: button.dataset.route,
            id: button.dataset.itemId,
            title: button.dataset.openTitle || "",
            subtitle: button.dataset.openSubtitle || ""
          });
        };

        this.el.addEventListener("dblclick", this.handleDblClick);
      },

      destroyed() {
        this.el.removeEventListener("dblclick", this.handleDblClick);
      }
    },

    SettingsSectionScroll: {
      mounted() {
        this.lastTargetId = null;
        this.scrollToSelectedSection();
      },

      updated() {
        this.scrollToSelectedSection();
      },

      scrollToSelectedSection() {
        const targetId = this.el.dataset.settingsScrollTarget;

        if (!targetId || targetId === this.lastTargetId) {
          return;
        }

        this.lastTargetId = targetId;

        window.requestAnimationFrame(() => {
          const target = document.getElementById(targetId);

          if (target && this.el.contains(target)) {
            target.scrollIntoView({ block: "start", behavior: "smooth" });
          }
        });
      }
    },

    ChatSurface: {
      mounted() {
        this.stickToBottom = true;
        this.scrollContainer = null;

        this.autoResize = () => {
          const textarea = this.el.querySelector(".chat-input");

          if (!textarea) {
            return;
          }

          const styles = getComputedStyle(textarea);
          const minHeight = parseFloat(styles.getPropertyValue("--chat-input-min-height")) || 20;
          const maxHeight = parseFloat(styles.getPropertyValue("--chat-input-max-height")) || 160;

          textarea.rows = 1;
          textarea.style.minHeight = `${minHeight}px`;

          if (textarea.value.trim() === "") {
            textarea.style.height = `${minHeight}px`;
            textarea.style.maxHeight = `${minHeight}px`;
            textarea.style.overflowY = "hidden";
            return;
          }

          textarea.style.maxHeight = `${maxHeight}px`;
          textarea.style.height = "0px";
          const nextHeight = Math.min(Math.max(textarea.scrollHeight, minHeight), maxHeight);
          textarea.style.height = `${nextHeight}px`;
          textarea.style.overflowY = nextHeight >= maxHeight ? "auto" : "hidden";
        };

        this.syncScrollContainer = () => {
          const nextContainer = this.el.querySelector(".chat-messages");

          if (nextContainer === this.scrollContainer) {
            return;
          }

          if (this.scrollContainer) {
            this.scrollContainer.removeEventListener("scroll", this.handleScroll);
          }

          this.scrollContainer = nextContainer;

          if (this.scrollContainer) {
            this.scrollContainer.addEventListener("scroll", this.handleScroll);
          }
        };

        this.scrollToBottom = (force = false) => {
          if (!this.scrollContainer) {
            return;
          }

          if (force || this.stickToBottom) {
            this.scrollContainer.scrollTop = this.scrollContainer.scrollHeight;
          }
        };

        this.syncExpandedSurfaces = () => {
          this.el
            .querySelectorAll(".chat-inline-surface[data-expanded='true']")
            .forEach((surface) => {
              surface.open = true;
            });
        };

        this.handleScroll = () => {
          if (!this.scrollContainer) {
            this.stickToBottom = true;
            return;
          }

          const distanceFromBottom =
            this.scrollContainer.scrollHeight -
            this.scrollContainer.scrollTop -
            this.scrollContainer.clientHeight;

          this.stickToBottom = distanceFromBottom < 48;
        };

        this.handleInput = (event) => {
          if (!event.target.closest(".chat-input")) {
            return;
          }

          this.stickToBottom = true;
          this.autoResize();
        };

        this.handleKeyDown = (event) => {
          if (!event.target.closest(".chat-input")) {
            return;
          }

          if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
            event.preventDefault();

            const sendButton = this.el.querySelector("[data-testid='chat-send-button']");

            if (sendButton && !sendButton.disabled) {
              sendButton.click();
            }
          }
        };

        this.el.addEventListener("input", this.handleInput);
        this.el.addEventListener("keydown", this.handleKeyDown);

        this.syncScrollContainer();
        this.syncExpandedSurfaces();
        this.autoResize();
        window.requestAnimationFrame(() => this.scrollToBottom(true));
      },

      updated() {
        this.syncScrollContainer();
        this.syncExpandedSurfaces();
        this.autoResize();
        window.requestAnimationFrame(() => this.scrollToBottom());
      },

      destroyed() {
        this.el.removeEventListener("input", this.handleInput);
        this.el.removeEventListener("keydown", this.handleKeyDown);

        if (this.scrollContainer) {
          this.scrollContainer.removeEventListener("scroll", this.handleScroll);
        }
      }
    },

    MenuEditorTree: {
      mounted() {
        this.dragItemId = null;
        this.dragSourceEl = null;
        this.dropTargetEl = null;
        this.dropPosition = null;

        this.clearDropTarget = () => {
          if (this.dropTargetEl) {
            this.dropTargetEl.classList.remove("is-drop-before", "is-drop-after", "is-drop-inside");
          }

          this.dropTargetEl = null;
          this.dropPosition = null;
        };

        this.setDropTarget = (row, position) => {
          if (this.dropTargetEl === row && this.dropPosition === position) {
            return;
          }

          this.clearDropTarget();
          this.dropTargetEl = row;
          this.dropPosition = position;
          row.classList.add(`is-drop-${position}`);
        };

        this.handleDragStart = (event) => {
          const handle = event.target.closest("[data-menu-drag-handle='true']");
          const row = event.target.closest("[data-menu-item-id]");

          if (!handle || !row || !this.el.contains(row)) {
            return;
          }

          this.dragItemId = row.dataset.menuItemId || null;
          this.dragSourceEl = row;
          row.classList.add("is-dragging");

          if (event.dataTransfer) {
            event.dataTransfer.effectAllowed = "move";
            event.dataTransfer.setData("text/plain", this.dragItemId || "");
          }
        };

        this.handleDragOver = (event) => {
          const row = event.target.closest("[data-menu-item-id]");

          if (!this.dragItemId || !row || !this.el.contains(row)) {
            this.clearDropTarget();
            return;
          }

          const targetItemId = row.dataset.menuItemId || "";

          if (!targetItemId || targetItemId === this.dragItemId) {
            this.clearDropTarget();
            return;
          }

          event.preventDefault();

          const rect = row.getBoundingClientRect();
          const offsetY = event.clientY - rect.top;
          const allowInside = row.dataset.menuCanDropInside === "true";
          const insideBandTop = rect.height * 0.3;
          const insideBandBottom = rect.height * 0.7;

          const position =
            allowInside && offsetY >= insideBandTop && offsetY <= insideBandBottom
              ? "inside"
              : offsetY < rect.height / 2
                ? "before"
                : "after";

          this.setDropTarget(row, position);

          if (event.dataTransfer) {
            event.dataTransfer.dropEffect = "move";
          }
        };

        this.handleDrop = (event) => {
          const row = event.target.closest("[data-menu-item-id]");

          if (!this.dragItemId || !row || !this.el.contains(row) || !this.dropPosition) {
            this.clearDropTarget();
            return;
          }

          event.preventDefault();

          this.pushEvent("menu_editor_drop_item", {
            drag_item_id: this.dragItemId,
            target_item_id: row.dataset.menuItemId,
            position: this.dropPosition
          });

          this.clearDropTarget();
        };

        this.handleDragLeave = (event) => {
          const related = event.relatedTarget;

          if (this.dropTargetEl && (!related || !this.dropTargetEl.contains(related))) {
            this.clearDropTarget();
          }
        };

        this.handleDragEnd = () => {
          if (this.dragSourceEl) {
            this.dragSourceEl.classList.remove("is-dragging");
          }

          this.dragItemId = null;
          this.dragSourceEl = null;
          this.clearDropTarget();
        };

        this.el.addEventListener("dragstart", this.handleDragStart);
        this.el.addEventListener("dragover", this.handleDragOver);
        this.el.addEventListener("drop", this.handleDrop);
        this.el.addEventListener("dragleave", this.handleDragLeave);
        this.el.addEventListener("dragend", this.handleDragEnd);
      },

      destroyed() {
        this.el.removeEventListener("dragstart", this.handleDragStart);
        this.el.removeEventListener("dragover", this.handleDragOver);
        this.el.removeEventListener("drop", this.handleDrop);
        this.el.removeEventListener("dragleave", this.handleDragLeave);
        this.el.removeEventListener("dragend", this.handleDragEnd);
      }
    },

    MonacoEditor: {
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
          .then((monaco) => {
            if (!this.host || !this.textarea) {
              return;
            }

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

        if (this.editor.getValue() !== this.textarea.value && this.lastKnownValue !== this.textarea.value) {
          this.isApplyingRemoteUpdate = true;
          this.editor.setValue(this.textarea.value);
          this.isApplyingRemoteUpdate = false;
        }

        this.lastKnownValue = this.textarea.value;
      },

      destroyed() {
        window.clearTimeout(this.syncTimer);
        this.changeSubscription?.dispose();
        this.editor?.dispose();
      }
    },

    MonacoDiffEditor: {
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
    }
  };

  const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
    params: { _csrf_token: csrfToken },
    hooks: Hooks,
    metadata: {
      keydown: (event) => ({
        key: event.key,
        meta: event.metaKey,
        ctrl: event.ctrlKey,
        alt: event.altKey,
        shift: event.shiftKey,
        tag: event.target?.tagName || null,
        contentEditable: event.target?.isContentEditable || false
      })
    }
  });

  liveSocket.connect();
  window.liveSocket = liveSocket;
});