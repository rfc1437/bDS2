const root = document.getElementById("bds-shell-app");
const bootstrapNode = document.getElementById("bds-shell-bootstrap");

if (!root || !bootstrapNode) {
  throw new Error("Missing shell bootstrap payload");
}

const bootstrap = JSON.parse(bootstrapNode.textContent);
const state = {
  session: clone(bootstrap.session),
  tabMeta: {},
};

render();

function render() {
  root.style.setProperty("--sidebar-width", state.session.sidebar_visible ? `${state.session.sidebar_width}px` : "0px");
  root.style.setProperty(
    "--assistant-width",
    state.session.assistant_sidebar_visible ? `${state.session.assistant_sidebar_width}px` : "0px"
  );

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
    <div class="window-titlebar-title" data-testid="window-title">${escapeHtml(bootstrap.title)}</div>
    <div class="window-titlebar-actions">
      <button class="window-titlebar-action-button" data-command="toggle-sidebar" data-testid="toggle-sidebar" type="button" aria-label="Toggle sidebar">Sidebar</button>
      <button class="window-titlebar-action-button" data-command="toggle-panel" data-testid="toggle-panel" type="button" aria-label="Toggle panel">Panel</button>
      <button class="window-titlebar-action-button" data-command="toggle-assistant" data-testid="toggle-assistant" type="button" aria-label="Toggle assistant">Assistant</button>
    </div>
  `;
}

function renderActivityBar() {
  const top = sidebarViews().filter((view) => view.activity_group === "top");
  const bottom = sidebarViews().filter((view) => view.activity_group === "bottom");

  root.querySelector(".activity-bar").innerHTML = `
    <div class="activity-bar-group">${top.map(renderActivityButton).join("")}</div>
    <div class="activity-bar-group">${bottom.map(renderActivityButton).join("")}</div>
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
      <span class="activity-bar-glyph">${escapeHtml(view.label.slice(0, 1))}</span>
    </button>
  `;
}

function renderSidebar() {
  const view = currentSidebarView();
  const data = currentSidebarData();

  root.querySelector(".sidebar").innerHTML = `
    <div class="sidebar-header">
      <div>
        <div class="sidebar-eyebrow">${escapeHtml(view.label)}</div>
        <strong>${escapeHtml(data.title)}</strong>
      </div>
      <span class="sidebar-subtitle">${escapeHtml(data.subtitle)}</span>
    </div>
    <div class="sidebar-content">
      ${data.sections
        .map(
          (section) => `
            <section class="sidebar-section">
              <div class="sidebar-section-header">
                <span data-testid="sidebar-section-title">${escapeHtml(section.title)}</span>
                <span>${section.items.length}</span>
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
              <section class="editor-meta-card">
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
      <div class="dashboard-grid">
        ${dashboard.summary_cards
          .map(
            (card) => `
              <article class="dashboard-card">
                <span>${escapeHtml(card.label)}</span>
                <strong>${escapeHtml(card.value)}</strong>
                <p>${escapeHtml(card.detail)}</p>
              </article>
            `
          )
          .join("")}
      </div>
      <div class="editor-section">
        <h2>Workbench Notes</h2>
        <ul>
          ${dashboard.checklist.map((entry) => `<li>${escapeHtml(entry)}</li>`).join("")}
        </ul>
      </div>
    `;
  }

  const active = activeItem();
  return `
    <div class="editor-toolbar">
      <button type="button">Open</button>
      <button type="button">Preview</button>
      <button type="button">Metadata</button>
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
      <span>${state.session.panel.visible ? "Visible" : "Hidden"}</span>
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
      <span>Project context</span>
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
      <span class="status-bar-item">${escapeHtml(status.right.brand)}</span>
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
      }
      if (command === "toggle-panel") {
        state.session.panel.visible = !state.session.panel.visible;
      }
      if (command === "toggle-assistant") {
        state.session.assistant_sidebar_visible = !state.session.assistant_sidebar_visible;
      }
      render();
    };
  });

  root.querySelectorAll("[data-activity]").forEach((button) => {
    button.onclick = () => {
      const next = button.dataset.activity;
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