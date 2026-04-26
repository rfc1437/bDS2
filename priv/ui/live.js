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

  const escapeHtml = (value) =>
    String(value || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");

  const stashTokens = (source, pattern, className, tokens) =>
    source.replace(pattern, (match) => {
      const marker = `@@token_${tokens.length}@@`;
      tokens.push(`<span class="${className}">${match}</span>`);
      return marker;
    });

  const restoreTokens = (source, tokens) =>
    tokens.reduce((html, token, index) => html.replaceAll(`@@token_${index}@@`, token), source);

  const highlightCodeLine = (line, language) => {
    const tokens = [];
    let html = escapeHtml(line);

    html = stashTokens(html, /#.*/g, "token-comment", tokens);
    html = stashTokens(html, /"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/g, "token-string", tokens);
    html = html.replace(/\b\d+(?:\.\d+)?\b/g, '<span class="token-number">$&</span>');

    if (language === "elixir") {
      html = html.replace(/:\w+[!?]?/g, '<span class="token-atom">$&</span>');
      html = html.replace(
        /\b(?:defp?|do|end|fn|case|cond|if|else|with|when|receive|after|rescue|catch|try|use|alias|import|require|quote|unquote|for|in)\b/g,
        '<span class="token-keyword">$&</span>'
      );
      html = html.replace(/\b[A-Z][A-Za-z0-9_.]*\b/g, '<span class="token-module">$&</span>');
    }

    return `<span class="md-code-line">${restoreTokens(html, tokens)}</span>`;
  };

  const highlightMarkdownLine = (line) => {
    let html = escapeHtml(line);

    if (/^\s{0,3}#{1,6}\s/.test(line)) {
      html = html.replace(/^((?:\s{0,3}#{1,6}))(\s+)(.*)$/, '<span class="md-heading-marker">$1</span>$2<span class="md-heading-text">$3</span>');
    } else if (/^\s*&gt;\s?/.test(html)) {
      html = html.replace(/^(\s*&gt;)(\s?)(.*)$/, '<span class="md-quote-marker">$1</span>$2<span class="md-quote-text">$3</span>');
    } else if (/^\s*(?:[-*+]|\d+\.)\s+/.test(line)) {
      html = html.replace(/^(\s*(?:[-*+]|\d+\.))(\s+)(.*)$/, '<span class="md-list-marker">$1</span>$2<span class="md-list-text">$3</span>');
    }

    html = html.replace(/(`[^`]+`)/g, '<span class="md-inline-code">$1</span>');
    html = html.replace(/(\[[^\]]+\]\([^\)]+\))/g, '<span class="md-link">$1</span>');
    html = html.replace(/(\*\*[^*]+\*\*)/g, '<span class="md-strong">$1</span>');
    html = html.replace(/(^|[^*])(\*[^*\n]+\*)/g, '$1<span class="md-emphasis">$2</span>');

    return html;
  };

  const highlightMarkdownSource = (source) => {
    const lines = String(source || "").split("\n");
    let inFence = false;
    let fenceLanguage = "";

    return lines
      .map((line) => {
        const trimmed = line.trimStart();

        if (trimmed.startsWith("```")) {
          const nextLanguage = trimmed.slice(3).trim().toLowerCase();
          const highlightedFence = `<span class="md-fence">${escapeHtml(line)}</span>`;

          if (!inFence) {
            inFence = true;
            fenceLanguage = nextLanguage;
          } else {
            inFence = false;
            fenceLanguage = "";
          }

          return highlightedFence;
        }

        return inFence ? highlightCodeLine(line, fenceLanguage) : highlightMarkdownLine(line);
      })
      .join("\n");
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

          if (action) {
            this.pushEvent("native_menu_action", { action });
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

    PostEditorContent: {
      mounted() {
        this.textarea = this.el.querySelector("textarea");
        this.highlight = this.el.querySelector(".post-editor-markdown-highlight");

        this.renderHighlight = () => {
          if (!this.textarea || !this.highlight) {
            return;
          }

          this.highlight.innerHTML = `${highlightMarkdownSource(this.textarea.value)}\n`;
          this.highlight.scrollTop = this.textarea.scrollTop;
          this.highlight.scrollLeft = this.textarea.scrollLeft;
        };

        this.handleInput = () => this.renderHighlight();
        this.handleScroll = () => {
          if (!this.textarea || !this.highlight) {
            return;
          }

          this.highlight.scrollTop = this.textarea.scrollTop;
          this.highlight.scrollLeft = this.textarea.scrollLeft;
        };

        this.handleInsert = ({ id, content }) => {
          if (!this.textarea || !content || String(id) !== String(this.el.dataset.postEditorId)) {
            return;
          }

          const start = this.textarea.selectionStart ?? this.textarea.value.length;
          const end = this.textarea.selectionEnd ?? start;
          const before = this.textarea.value.slice(0, start);
          const after = this.textarea.value.slice(end);
          const separator = before !== "" && !before.endsWith("\n") ? "\n" : "";
          const suffix = after !== "" && !content.endsWith("\n") ? "\n" : "";
          const inserted = `${separator}${content}${suffix}`;
          const nextValue = `${before}${inserted}${after}`;

          this.textarea.focus();
          this.textarea.value = nextValue;

          const caret = before.length + inserted.length;
          this.textarea.setSelectionRange(caret, caret);
          this.textarea.dispatchEvent(new Event("input", { bubbles: true }));
          this.textarea.dispatchEvent(new Event("change", { bubbles: true }));
        };

        this.el.classList.add("is-enhanced");
        this.textarea?.addEventListener("input", this.handleInput);
        this.textarea?.addEventListener("scroll", this.handleScroll);
        this.handleEvent("post-editor-insert-content", this.handleInsert);
        this.renderHighlight();
      },

      updated() {
        this.textarea = this.el.querySelector("textarea");
        this.highlight = this.el.querySelector(".post-editor-markdown-highlight");
        this.renderHighlight();
      },

      destroyed() {
        this.textarea?.removeEventListener("input", this.handleInput);
        this.textarea?.removeEventListener("scroll", this.handleScroll);
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