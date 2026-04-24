const root = document.getElementById("bds-shell-app");
const bootstrapNode = document.getElementById("bds-shell-bootstrap");

if (!root || !bootstrapNode) {
  throw new Error("Missing shell bootstrap payload");
}

const SIDEBAR_STORAGE_KEY = "bds-panel-sidebar";
const ASSISTANT_STORAGE_KEY = "bds-panel-assistant-sidebar";
const bootstrap = JSON.parse(bootstrapNode.textContent);
const state = {
  session: hydrateSession(clone(bootstrap.session)),
  tabMeta: {},
};

render();

function render() {
  root.style.setProperty("--sidebar-width", state.session.sidebar_visible ? `${state.session.sidebar_width}px` : "0px");
  root.style.setProperty("--assistant-width", state.session.assistant_sidebar_visible ? `${state.session.assistant_sidebar_width}px` : "0px");

  renderTitlebar();
  renderActivityBar();
  renderSidebar();
  renderTabs();
  renderEditor();
  renderPanel();
  renderAssistant();
  renderStatusBar();
  applyVisibility();
  bindEvents();
}

function renderTitlebar() {
  root.querySelector(".window-titlebar").innerHTML = `
    <div class="window-titlebar-menu-bar">
      ${bootstrap.menu_groups
        .map((group) => `<button class="window-titlebar-menu-button" type="button">${escapeHtml(group.label)}</button>`)
        .join("")}
    </div>
    <div class="window-titlebar-drag-region"></div>
    <div class="window-titlebar-title" data-testid="window-title">${escapeHtml(bootstrap.title)}</div>
    <div class="window-titlebar-actions">
      ${renderTitlebarAction("toggle-sidebar", "toggle-sidebar", "Toggle sidebar", `
        <span class="window-titlebar-sidebar-icon ${state.session.sidebar_visible ? "is-active" : "is-inactive"}">
          <span class="window-titlebar-sidebar-pane"></span>
        </span>
      `)}
      ${renderTitlebarAction("toggle-panel", "toggle-panel", "Toggle panel", `
        <span class="window-titlebar-panel-icon ${state.session.panel.visible ? "is-active" : "is-inactive"}">
          <span class="window-titlebar-panel-pane"></span>
        </span>
      `)}
      ${renderTitlebarAction("toggle-assistant", "toggle-assistant", "Toggle assistant", `
        <span class="window-titlebar-assistant-icon ${state.session.assistant_sidebar_visible ? "is-active" : "is-inactive"}">
          <span class="window-titlebar-assistant-pane"></span>
        </span>
      `)}
    </div>
  `;
}

function renderTitlebarAction(command, testId, label, iconMarkup) {
  return `
    <button class="window-titlebar-action-button" data-command="${command}" data-testid="${testId}" type="button" aria-label="${label}" title="${label}">
      ${iconMarkup}
    </button>
  `;
}

function renderActivityBar() {
  const top = sidebarViews().filter((view) => view.activity_group === "top");
  const bottom = sidebarViews().filter((view) => view.activity_group === "bottom");

  root.querySelector(".activity-bar").innerHTML = `
    <div class="activity-bar-top">${top.map(renderActivityButton).join("")}</div>
    <div class="activity-bar-bottom">${bottom.map(renderActivityButton).join("")}</div>
  `;
}

function renderActivityButton(view) {
  const active = state.session.sidebar_visible && state.session.active_view === view.id;
  return `
    <button
      class="activity-bar-item ${active ? "active" : ""}"
      data-activity="${view.id}"
      data-view="${view.id}"
      data-active="${String(active)}"
      data-testid="activity-button"
      type="button"
      aria-label="${escapeHtml(view.label)}"
      title="${escapeHtml(view.label)}"
    >
      ${activityIcon(view.id)}
    </button>
  `;
}

function renderSidebar() {
  const view = currentSidebarView();
  const data = currentSidebarData();

  root.querySelector(".sidebar").innerHTML = `
    <div class="sidebar-header">
      <div class="sidebar-title-row">
        <strong>${escapeHtml(data.title)}</strong>
        <span class="sidebar-subtitle">${escapeHtml(data.subtitle)}</span>
      </div>
    </div>
    <div class="sidebar-content">
      ${data.sections
        .map(
          (section) => `
            <section class="sidebar-section">
              <div class="sidebar-section-header">
                <span data-testid="sidebar-section-title">${escapeHtml(section.title)}</span>
              </div>
              <div class="sidebar-section-items">
                ${section.items.map((item) => renderSidebarItem(item, view)).join("")}
              </div>
            </section>
          `
        )
        .join("")}
    </div>
  `;
}

function renderSidebarItem(item, view) {
  const tabRef = currentTabRef();
  const itemRoute = item.route || view.editor_route;
  const tabId = tabIdForItem(item, itemRoute);
  const active = tabRef && tabRef.type === itemRoute && tabRef.id === tabId;

  return `
    <button
      class="sidebar-item ${active ? "active" : ""}"
      data-open-tab="${tabId}"
      data-open-route="${itemRoute}"
      data-open-title="${escapeHtmlAttribute(item.title)}"
      type="button"
    >
      <strong>${escapeHtml(item.title)}</strong>
      <span>${escapeHtml(item.meta || view.label)}</span>
      ${item.badge ? `<span class="sidebar-badge">${escapeHtml(item.badge)}</span>` : ""}
    </button>
  `;
}

function renderTabs() {
  const tabs = state.session.tabs;
  const node = root.querySelector(".tab-bar");

  if (tabs.length === 0) {
    node.innerHTML = `<div class="tab-bar-empty">Dashboard</div>`;
    return;
  }

  node.innerHTML = `
    <div class="tab-bar-tabs">
      ${tabs.map(renderTab).join("")}
    </div>
  `;
}

function renderTab(tab) {
  const active = sameTab(tab, currentTabRef());
  const meta = tabMetadata(tab);

  return `
    <button class="tab ${active ? "active" : ""} ${tab.is_transient ? "transient" : ""}" data-tab-type="${tab.type}" data-tab-id="${tab.id}" type="button">
      <span class="tab-icon">${tabIcon(tab.type)}</span>
      <span class="tab-title">${escapeHtml(meta.title)}</span>
      <span class="tab-close" aria-hidden="true">${tab.is_transient ? "Preview" : "Pinned"}</span>
    </button>
  `;
}

function renderEditor() {
  const route = currentRoute();
  const meta = currentEditorMeta();
  const node = root.querySelector(".editor-shell");

  node.innerHTML = `
    <div class="editor-frame">
      <section class="editor-main">
        <div class="editor-kicker">${escapeHtml(routeLabel(route))}</div>
        <h1 class="editor-title" data-testid="editor-title">${escapeHtml(editorTitle())}</h1>
        <p class="editor-subtitle">${escapeHtml(editorSubtitle(route))}</p>
        ${renderEditorBody(route)}
      </section>
      <aside class="editor-meta">
        ${meta
          .map(
            (item) => `
              <section class="editor-meta-row">
                <strong data-testid="editor-meta-label">${escapeHtml(item.label)}</strong>
                <span>${escapeHtml(item.value)}</span>
              </section>
            `
          )
          .join("")}
      </aside>
    </div>
  `;
}

function renderEditorBody(route) {
  if (route === "dashboard") {
    const dashboard = bootstrap.content.dashboard;
    return `
      <section class="editor-section">
        <ul class="editor-list compact">
          ${dashboard.summary_cards
            .map((card) => `<li><strong>${escapeHtml(card.label)}:</strong> ${escapeHtml(card.value)} <span>${escapeHtml(card.detail)}</span></li>`)
            .join("")}
        </ul>
      </section>
      <section class="editor-section">
        <h2>Workbench Notes</h2>
        <ul class="editor-list">
          ${dashboard.checklist.map((entry) => `<li>${escapeHtml(entry)}</li>`).join("")}
        </ul>
      </section>
    `;
  }

  const active = activeItem();
  return `
    <div class="editor-toolbar">
      <button class="editor-toolbar-button" type="button">Open</button>
      <button class="editor-toolbar-button" type="button">Preview</button>
      <button class="editor-toolbar-button" type="button">Metadata</button>
    </div>
    <div class="editor-section">
      <h2>${escapeHtml(active?.title || routeLabel(route))}</h2>
      <p>${escapeHtml(active?.meta || "Desktop workbench content routed through the Elixir shell.")}</p>
    </div>
  `;
}

function renderPanel() {
  const tabs = [state.session.panel.active_tab, "output", "git_log"].filter(uniqueValue);

  root.querySelector(".panel-shell").innerHTML = `
    <div class="panel-header">
      <div class="panel-tabs">
        ${tabs
          .map(
            (tab) => `
              <button class="panel-tab ${state.session.panel.active_tab === tab ? "active" : ""}" data-panel-tab="${tab}" type="button">${escapeHtml(routeLabel(tab))}</button>
            `
          )
          .join("")}
      </div>
    </div>
    <div class="panel-content">
      <div class="panel-entry">
        <strong>${escapeHtml(routeLabel(state.session.panel.active_tab))}</strong>
        <span>The shared lower panel is available for tasks, output, git details, and editor-specific diagnostics.</span>
      </div>
    </div>
  `;
}

function renderAssistant() {
  root.querySelector(".assistant-sidebar").innerHTML = `
    <div class="assistant-header">
      <strong>Assistant</strong>
    </div>
    <div class="assistant-content">
      ${bootstrap.content.assistant_cards
        .map(
          (card) => `
            <section class="assistant-card">
              <strong>${escapeHtml(card.label)}</strong>
              <span>${escapeHtml(card.text)}</span>
            </section>
          `
        )
        .join("")}
    </div>
  `;
}

function renderStatusBar() {
  const status = bootstrap.status;

  root.querySelector(".status-bar").innerHTML = `
    <div class="status-bar-left">
      <span class="status-bar-item">${escapeHtml(status.left.running_task_message || "Idle")}</span>
    </div>
    <div class="status-bar-right">
      <span class="status-bar-item">${escapeHtml(status.right.post_count)}</span>
      <span class="status-bar-item">${escapeHtml(status.right.media_count)}</span>
      <span class="status-bar-item">${escapeHtml(status.right.theme_badge)}</span>
      <span class="status-bar-item">${status.right.offline_mode ? "Offline" : "Online"}</span>
      <span class="status-bar-item">${escapeHtml(status.right.ui_language.toUpperCase())}</span>
      <span class="status-bar-item brand">${escapeHtml(status.right.brand)}</span>
    </div>
  `;
}

function applyVisibility() {
  root.querySelector(".sidebar-shell").classList.toggle("is-hidden", !state.session.sidebar_visible);
  root.querySelector(".assistant-sidebar-shell").classList.toggle("is-hidden", !state.session.assistant_sidebar_visible);
  root.querySelector(".panel-shell").classList.toggle("is-hidden", !state.session.panel.visible);
}

function bindEvents() {
  root.querySelectorAll("[data-command]").forEach((button) => {
    button.onclick = () => {
      const command = button.dataset.command;
      if (command === "toggle-sidebar") {
        state.session.sidebar_visible = !state.session.sidebar_visible;
        persistSessionWidths();
      }
      if (command === "toggle-panel") {
        state.session.panel.visible = !state.session.panel.visible;
      }
      if (command === "toggle-assistant") {
        state.session.assistant_sidebar_visible = !state.session.assistant_sidebar_visible;
        persistSessionWidths();
      }
      render();
    };
  });

  root.querySelectorAll("[data-activity]").forEach((button) => {
    button.onclick = () => {
      const next = button.dataset.activity;

  bindResizeHandle("sidebar", {
    key: SIDEBAR_STORAGE_KEY,
    min: 200,
    max: 500,
    get: () => state.session.sidebar_width,
    set: (value) => {
      state.session.sidebar_width = value;
      state.session.sidebar_visible = true;
    },
  });

  bindResizeHandle("assistant", {
    key: ASSISTANT_STORAGE_KEY,
    min: 280,
    max: 640,
    get: () => state.session.assistant_sidebar_width,
    set: (value) => {
      state.session.assistant_sidebar_width = value;
      state.session.assistant_sidebar_visible = true;
    },
    invert: true,
  });
      if (state.session.active_view === next && state.session.sidebar_visible) {
        state.session.sidebar_visible = false;
      } else {
        state.session.active_view = next;
        state.session.sidebar_visible = true;
      }
      render();
    };
  });

  root.querySelectorAll("[data-open-tab]").forEach((button) => {
    button.onclick = () => {
      openTab(button.dataset.openRoute, button.dataset.openTab, button.dataset.openTitle, true);
    };

    button.ondblclick = () => {
      openTab(button.dataset.openRoute, button.dataset.openTab, button.dataset.openTitle, false);
    };
  });

  root.querySelectorAll("[data-tab-id]").forEach((button) => {
    button.onclick = () => {
      state.session.active_tab = { type: button.dataset.tabType, id: button.dataset.tabId };
      render();
    };
  });

  root.querySelectorAll("[data-panel-tab]").forEach((button) => {
    button.onclick = () => {
      state.session.panel.active_tab = button.dataset.panelTab;
      state.session.panel.visible = true;
      render();
    };
  });
}

function openTab(type, id, title, transient) {
  const existingIndex = state.session.tabs.findIndex((tab) => tab.type === type && tab.id === id);

  if (existingIndex >= 0) {
    state.session.tabs[existingIndex].is_transient = transient ? state.session.tabs[existingIndex].is_transient : false;
  } else if (transient) {
    const transientIndex = state.session.tabs.findIndex((tab) => tab.type === type && tab.is_transient);
    const nextTab = { type, id, is_transient: true };

    if (transientIndex >= 0) {
      state.session.tabs.splice(transientIndex, 1, nextTab);
    } else {
      state.session.tabs.push(nextTab);
    }
  } else {
    state.session.tabs.push({ type, id, is_transient: false });
  }

  state.tabMeta[`${type}:${id}`] = { title };
  state.session.active_tab = { type, id };
  render();
}

function activeItem() {
  const tab = currentTabRef();

  if (!tab) {
    return null;
  }

  const sections = Object.values(bootstrap.content.sidebar).flatMap((view) => view.sections);
  return sections.flatMap((section) => section.items).find((item) => tabIdForItem(item, item.route) === tab.id) || null;
}

function tabMetadata(tab) {
  const lookup = state.tabMeta[`${tab.type}:${tab.id}`];
  if (lookup) {
    return lookup;
  }

  const item = activeItem();
  if (item && tab.id === tabIdForItem(item, item.route)) {
    return { title: item.title };
  }

  return { title: routeLabel(tab.type) };
}

function currentSidebarView() {
  return sidebarViews().find((view) => view.id === state.session.active_view) || sidebarViews()[0];
}

function currentSidebarData() {
  return bootstrap.content.sidebar[state.session.active_view] || bootstrap.content.sidebar[bootstrap.registry.default_sidebar_view];
}

function currentTabRef() {
  return state.session.active_tab;
}

function currentRoute() {
  return currentTabRef()?.type || "dashboard";
}

function currentEditorMeta() {
  return bootstrap.content.editor_meta[currentRoute()] || bootstrap.content.editor_meta.dashboard;
}

function editorTitle() {
  const item = activeItem();
  return item?.title || bootstrap.content.dashboard.title;
}

function editorSubtitle(route) {
  if (route === "dashboard") {
    return bootstrap.content.dashboard.subtitle;
  }

  const item = activeItem();
  return item?.meta || `${routeLabel(route)} content loaded through the desktop shell.`;
}

function routeLabel(route) {
  if (!route) {
    return "Dashboard";
  }

  return (
    bootstrap.registry.editor_routes.find((item) => item.id === route)?.title ||
    sidebarViews().find((item) => item.id === route)?.label ||
    titleCase(route)
  );
}

function tabIdForItem(item, route) {
  if (route === "settings" || route === "tags") {
    return route;
  }

  return item.id;
}

function sidebarViews() {
  return bootstrap.registry.sidebar_views;
}

function sameTab(tab, ref) {
  return Boolean(ref) && tab.type === ref.type && tab.id === ref.id;
}

function uniqueValue(value, index, array) {
  return Boolean(value) && array.indexOf(value) === index;
}

function titleCase(value) {
  return value
    .split("_")
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function hydrateSession(session) {
  const next = session;
  next.sidebar_width = readStoredSize(SIDEBAR_STORAGE_KEY, next.sidebar_width, 200, 500);
  next.assistant_sidebar_width = readStoredSize(ASSISTANT_STORAGE_KEY, next.assistant_sidebar_width, 280, 640);
  return next;
}

function bindResizeHandle(name, options) {
  const handle = root.querySelector(`[data-resize='${name}']`);
  if (!handle) {
    return;
  }

  handle.onmousedown = (event) => {
    event.preventDefault();
    const startX = event.clientX;
    const startWidth = options.get();

    const onMouseMove = (moveEvent) => {
      const delta = options.invert ? startX - moveEvent.clientX : moveEvent.clientX - startX;
      const width = clamp(startWidth + delta, options.min, options.max);
      options.set(width);
      persistSessionWidths();
      render();
    };

    const onMouseUp = () => {
      window.removeEventListener("mousemove", onMouseMove);
      window.removeEventListener("mouseup", onMouseUp);
    };

    window.addEventListener("mousemove", onMouseMove);
    window.addEventListener("mouseup", onMouseUp);
  };
}

function persistSessionWidths() {
  localStorage.setItem(SIDEBAR_STORAGE_KEY, String(state.session.sidebar_width));
  localStorage.setItem(ASSISTANT_STORAGE_KEY, String(state.session.assistant_sidebar_width));
}

function readStoredSize(key, fallback, min, max) {
  const raw = localStorage.getItem(key);
  if (!raw) {
    return fallback;
  }

  const parsed = Number.parseInt(raw, 10);
  if (Number.isNaN(parsed)) {
    return fallback;
  }

  return clamp(parsed, min, max);
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function activityIcon(id) {
  const icons = {
    posts: '<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8l-6-6zM6 20V4h7v5h5v11H6z"></path><path d="M8 12h8v2H8zm0 4h8v2H8z"></path></svg>',
    pages: '<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M4 4h10v4h6v12H4V4zm10 1.5V9h4.5L14 5.5zM7 12h10v1.5H7V12zm0 3h10v1.5H7V15z"></path></svg>',
    media: '<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z"></path></svg>',
    scripts: '<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M20 3H4a1 1 0 0 0-1 1v11a1 1 0 0 0 1 1h7v2H8v2h8v-2h-3v-2h7a1 1 0 0 0 1-1V4a1 1 0 0 0-1-1zM5 14V5h14v9H5zm2-7.5L9.5 9 7 11.5l1.4 1.4L12.3 9 8.4 5.1 7 6.5zm6.5 5.5h4v-2h-4v2z"></path></svg>',
    templates: '<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M4 4h7v7H4V4zm9 0h7v7h-7V4zM4 13h7v7H4v-7zm9 0h7v7h-7v-7zM5.5 5.5v4h4v-4h-4zm9 0v4h4v-4h-4zm-9 9v4h4v-4h-4zm9 0v4h4v-4h-4z"></path></svg>',
    tags: '<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M21.41 11.58l-9-9C12.05 2.22 11.55 2 11 2H4c-1.1 0-2 .9-2 2v7c0 .55.22 1.05.59 1.42l9 9c.36.36.86.58 1.41.58s1.05-.22 1.41-.59l7-7c.37-.36.59-.86.59-1.41s-.23-1.06-.59-1.42zM5.5 7C4.67 7 4 6.33 4 5.5S4.67 4 5.5 4 7 4.67 7 5.5 6.33 7 5.5 7z"></path></svg>',
    chat: '<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm0 14H6l-2 2V4h16v12z"></path><circle cx="8" cy="10" r="1.5"></circle><circle cx="12" cy="10" r="1.5"></circle><circle cx="16" cy="10" r="1.5"></circle></svg>',
    import: '<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"></path></svg>',
    git: '<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M22 11.73L12.27 2a1 1 0 0 0-1.41 0L8.84 4.02l2.56 2.56a1.2 1.2 0 0 1 1.52 1.53l2.47 2.47a1.2 1.2 0 1 1-.72.67l-2.3-2.3v6.06a1.2 1.2 0 1 1-.85 0V8.9a1.2 1.2 0 0 1-.66-1.59L8.35 4.8 2 11.16a1 1 0 0 0 0 1.41L11.73 22a1 1 0 0 0 1.41 0L22 13.14a1 1 0 0 0 0-1.41z"></path></svg>',
    settings: '<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M19.14 12.94c.04-.31.06-.63.06-.94 0-.31-.02-.63-.06-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.04.31-.06.63-.06.94s.02.63.06.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"></path></svg>',
  };

  return icons[id] || icons.posts;
}

function tabIcon(type) {
  return activityIcon(type === "post" ? "posts" : type);
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function escapeHtmlAttribute(value) {
  return escapeHtml(value).replaceAll("`", "&#96;");
}