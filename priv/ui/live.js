document.addEventListener("DOMContentLoaded", () => {
  const csrfToken = document
    .querySelector("meta[name='csrf-token']")
    .getAttribute("content");

  const SIDEBAR_STORAGE_KEY = "bds-panel-sidebar";
  const ASSISTANT_STORAGE_KEY = "bds-panel-assistant-sidebar";
  const UI_LANGUAGE_STORAGE_KEY = "bds-ui-language";

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

  const Hooks = {
    AppShell: {
      mounted() {
        this.shortcuts = parseShortcutConfig(this.el.dataset.shortcuts);
        this.syncStoredLayout();
        this.syncStoredUiLanguage();
        this.destroyOverlaySync = syncTitlebarOverlayInsets();

        this.syncTitlebarMenuAnchor = () => {
          const titlebar = this.el.querySelector("[data-testid='window-titlebar']");
          const dropdown = this.el.querySelector("[data-testid='window-titlebar-menu-dropdown']");
          const openGroup = titlebar?.dataset.openMenuGroup;

          if (!dropdown || !titlebar || !openGroup) {
            return;
          }

          const button = this.getTitlebarMenuButtons().find((candidate) => candidate.dataset.menuGroup === openGroup);

          if (!button) {
            return;
          }

          const titlebarRect = titlebar.getBoundingClientRect();
          const buttonRect = button.getBoundingClientRect();
          const left = Math.max(6, Math.round(buttonRect.left - titlebarRect.left));

          dropdown.style.setProperty("--bds-titlebar-menu-left", `${left}px`);
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

        window.addEventListener("bds:native-menu-action", this.handleNativeMenuAction);
        window.addEventListener("keydown", this.handleShortcutKeyDown, true);
        this.el.addEventListener("change", this.handleChange);
        this.syncTitlebarMenuAnchor();
      },

      updated() {
        this.syncTitlebarMenuAnchor();
      },

      destroyed() {
        this.el.removeEventListener("mousedown", this.handleMouseDown);
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