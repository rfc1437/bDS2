document.addEventListener("DOMContentLoaded", () => {
  const csrfToken = document
    .querySelector("meta[name='csrf-token']")
    .getAttribute("content");

  const SIDEBAR_STORAGE_KEY = "bds-panel-sidebar";
  const ASSISTANT_STORAGE_KEY = "bds-panel-assistant-sidebar";

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

  const Hooks = {
    AppShell: {
      mounted() {
        this.syncStoredLayout();

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
      },

      destroyed() {
        this.el.removeEventListener("mousedown", this.handleMouseDown);
      },

      syncStoredLayout() {
        this.pushEvent("sync_layout", {
          sidebar_width: readStoredSize(SIDEBAR_STORAGE_KEY, shellWidth("[data-testid='sidebar-shell']"), 200, 500),
          assistant_sidebar_width: readStoredSize(ASSISTANT_STORAGE_KEY, 360, 280, 640)
        });
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