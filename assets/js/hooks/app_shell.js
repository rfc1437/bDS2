import {
  SIDEBAR_STORAGE_KEY,
  ASSISTANT_STORAGE_KEY,
  UI_LANGUAGE_STORAGE_KEY,
  WORKBENCH_SESSION_STORAGE_KEY_PREFIX
} from "../constants.js";
import {
  parseJsonObject,
  setMediaThumbnailLoaded,
  syncMediaThumbnailState,
  clamp
} from "../utils/dom.js";
import { shellWidth, setShellWidth, persistWidth, readStoredSize } from "../utils/layout.js";
import {
  parseShortcutConfig,
  normalizeShortcutKey,
  shortcutMatchesEvent,
  shortcutTargetIsEditable
} from "../utils/shortcuts.js";
import { syncTitlebarOverlayInsets } from "../bridges/titlebar_overlay.js";
import { runMenuRuntimeCommand } from "../bridges/menu_runtime.js";

export const AppShell = {
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

    this.handleEvent("menu-runtime-command", ({ action }) => {
      if (action) {
        runMenuRuntimeCommand(String(action));
      }
    });

    this.handleEvent("url-state", ({ path }) => {
      if (path && window.location.pathname + window.location.search !== path) {
        window.history.replaceState({}, "", path);
      }
    });

    window.addEventListener("bds:native-menu-action", this.handleNativeMenuAction);
    window.addEventListener("keydown", this.handleShortcutKeyDown, true);
    this.el.addEventListener("load", this.handleThumbnailLoad, true);
    this.el.addEventListener("error", this.handleThumbnailError, true);
    this.el.addEventListener("change", this.handleChange);
    syncMediaThumbnailState(this.el);
    this.restoreStoredWorkbenchSession();
    // Rehydration is done (any stored-session push is ordered before this):
    // tell the server it may now deliver queued deep links.
    this.pushEvent("shell_ready", {});
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
};
