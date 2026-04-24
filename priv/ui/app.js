const shell = document.getElementById("bds-shell-app");
const bootstrap = JSON.parse(document.getElementById("bds-shell-bootstrap").textContent);
const bootstrap = JSON.parse(document.getElementById('bds-bootstrap').textContent);

const state = {
  ...bootstrap,
};

const root = document.getElementById('app');

function render() {
  root.style.setProperty('--sidebar-width', state.sidebarVisible ? `${state.sidebarWidth}px` : '0px');
  root.style.setProperty('--assistant-width', state.assistantVisible ? `${state.assistantWidth}px` : '0px');

  renderMenuBar();
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

function renderMenuBar() {
  const menuBar = root.querySelector('.window-titlebar-menu-bar');
  menuBar.innerHTML = state.menuGroups
    .map((group) => `<button class="window-titlebar-menu-button">${group.label}</button>`)
    .join('');
}

function renderActivityBar() {
  const node = root.querySelector('.activity-bar');
  const top = state.sidebarViews.filter((view) => view.group === 'top');
  const bottom = state.sidebarViews.filter((view) => view.group === 'bottom');

  node.innerHTML = `
    <div class="activity-bar-top">${top.map(renderActivityButton).join('')}</div>
    <div class="activity-bar-bottom">${bottom.map(renderActivityButton).join('')}</div>
  `;
}

function renderActivityButton(view) {
  const active = state.sidebarVisible && state.activeView === view.id;
  return `<button class="activity-bar-item ${active ? 'active' : ''}" data-activity="${view.id}" title="${view.label}">${view.label.slice(0, 1)}</button>`;
}

function renderSidebar() {
  const view = state.sidebarViews.find((entry) => entry.id === state.activeView) || state.sidebarViews[0];
  const node = root.querySelector('.sidebar');

  node.innerHTML = `
    <div class="sidebar-header">
      <span>${view.label}</span>
      <span>${view.items.length}</span>
    </div>
    <div class="sidebar-content">
      ${view.items
        .map((item, index) => {
          const itemId = `${view.id}:${index}`;
          const active = state.activeTabId === itemId;
          return `
            <button class="sidebar-item ${active ? 'active' : ''}" data-open-tab="${itemId}">
              <strong>${item}</strong>
              <span>${view.label} entry</span>
            </button>
          `;
        })
        .join('')}
    </div>
  `;
}

function renderTabs() {
  const node = root.querySelector('.tab-bar');
  node.innerHTML = `<div class="tab-bar-tabs">${state.tabs.map(renderTab).join('')}</div>`;
}

function renderTab(tab) {
  const active = tab.id === state.activeTabId;
  const dirtyMarker = tab.dirty ? '<span class="tab-dirty-indicator">●</span>' : '<span class="tab-close">×</span>';
  return `
    <div class="tab ${active ? 'active' : ''} ${tab.pinned ? '' : 'transient'}" data-tab="${tab.id}">
      <span class="tab-title">${tab.title}</span>
      ${dirtyMarker}
    </div>
  `;
}

function renderEditor() {
  const node = root.querySelector('.editor-shell');
  const activeTab = state.tabs.find((tab) => tab.id === state.activeTabId) || state.tabs[0];

  node.innerHTML = `
    <div class="editor-frame">
      <section class="editor-main">
        <h1 class="editor-title">${activeTab.title}</h1>
        <div class="editor-subtitle">${activeTab.kind} editor surface routed through the desktop shell</div>
        <div class="editor-toolbar">
          <button type="button">Publish</button>
          <button type="button">Preview</button>
          <button type="button">Metadata</button>
        </div>
        <p class="editor-paragraph">This desktop shell now runs inside an Elixir Desktop window instead of a standalone browser page. The frame, activity bar, tab strip, status bar and resizable side areas match the old application structure so the next slice can replace placeholders with the real editors and lists.</p>
        <p class="editor-paragraph">Preview tabs, dirty state and shell routing still come from the shared Elixir workbench modules. The runtime boundary is now a desktop window backed by a local shell server.</p>
      </section>
      <aside class="editor-meta">
        <div class="assistant-card">
          <strong>Document State</strong>
          <span>${activeTab.dirty ? 'Unsaved changes' : 'Clean'}</span>
        </div>
        <div class="assistant-card">
          <strong>Publishing</strong>
          <span>Main language: en</span>
        </div>
        <div class="assistant-card">
          <strong>Filesystem</strong>
          <span>Metadata flush pending wiring</span>
        </div>
      </aside>
    </div>
  `;
}

function renderPanel() {
  const node = root.querySelector('.panel-shell');
  const tabs = ['problems', 'search', 'tasks'];

  node.innerHTML = `
    <div class="panel-header">
      <div class="panel-tabs">
        ${tabs
          .map((tab) => `<button class="panel-tab ${state.panelTab === tab ? 'active' : ''}" data-panel-tab="${tab}">${tab}</button>`)
          .join('')}
      </div>
      <span>${state.panelVisible ? 'Visible' : 'Hidden'}</span>
    </div>
    <div class="panel-content">
      <div class="panel-entry">
        <strong>${state.panelTab}</strong>
        <span>Shared bottom panel host for problems, search, tasks and later runtime details.</span>
      </div>
    </div>
  `;
}

function renderAssistant() {
  const node = root.querySelector('.assistant-sidebar');
  node.innerHTML = `
    <div class="assistant-header">
      <span>Assistant</span>
      <span>Project context</span>
    </div>
    <div class="assistant-content">
      <div class="assistant-card">
        <strong>Next shell work</strong>
        <span>Swap sidebar placeholders with real project data views.</span>
      </div>
      <div class="assistant-card">
        <strong>Offline gate</strong>
        <span>Automatic AI remains gated by airplane mode.</span>
      </div>
      <div class="assistant-card">
        <strong>Desktop runtime</strong>
        <span>Window, menu bar and launch path now come from Elixir Desktop.</span>
      </div>
    </div>
  `;
}

function renderStatusBar() {
  const node = root.querySelector('.status-bar');
  node.innerHTML = `
    <div class="status-bar-left">${state.statusBar.left.map(renderStatusItem).join('')}</div>
    <div class="status-bar-right">${state.statusBar.right.map(renderStatusItem).join('')}</div>
  `;
}

function renderStatusItem(item) {
  return `<div class="status-bar-item">${item.label}</div>`;
}

function applyVisibility() {
  root.querySelector('.sidebar-shell').classList.toggle('is-hidden', !state.sidebarVisible);
  root.querySelector('.assistant-sidebar-shell').classList.toggle('is-hidden', !state.assistantVisible);
  root.querySelector('.panel-shell').classList.toggle('is-hidden', !state.panelVisible);
}

function bindEvents() {
  root.querySelectorAll('[data-activity]').forEach((button) => {
    button.onclick = () => {
      const next = button.getAttribute('data-activity');
      if (state.activeView === next && state.sidebarVisible) {
        state.sidebarVisible = false;
      } else {
        state.activeView = next;
        state.sidebarVisible = true;
      }
      render();
    };
  });

  root.querySelectorAll('[data-open-tab]').forEach((button) => {
    button.onclick = () => {
      const tabId = button.getAttribute('data-open-tab');
      let tab = state.tabs.find((entry) => entry.id === tabId);
      if (!tab) {
        tab = {
          id: tabId,
          title: tabId.split(':').pop(),
          kind: state.activeView,
          pinned: false,
          dirty: false,
        };
        state.tabs.push(tab);
      }
      state.activeTabId = tab.id;
      render();
    };
  });

  root.querySelectorAll('[data-tab]').forEach((tab) => {
    tab.onclick = () => {
      state.activeTabId = tab.getAttribute('data-tab');
      render();
    };
  });

  root.querySelectorAll('[data-command]').forEach((button) => {
    button.onclick = () => {
      const command = button.getAttribute('data-command');
      if (command === 'toggle-sidebar') {
        state.sidebarVisible = !state.sidebarVisible;
      }
      if (command === 'toggle-panel') {
        state.panelVisible = !state.panelVisible;
      }
      render();
    };
  });

  root.querySelectorAll('[data-panel-tab]').forEach((button) => {
    button.onclick = () => {
      state.panelTab = button.getAttribute('data-panel-tab');
      state.panelVisible = true;
      render();
    };
  });

  root.querySelectorAll('[data-resize]').forEach((handle) => {
    handle.onpointerdown = (event) => {
      const target = handle.getAttribute('data-resize');
      const startX = event.clientX;
      const startWidth = target === 'sidebar' ? state.sidebarWidth : state.assistantWidth;
      handle.classList.add('is-dragging');

      const onMove = (moveEvent) => {
        const delta = moveEvent.clientX - startX;
        if (target === 'sidebar') {
          state.sidebarWidth = clamp(startWidth + delta, 220, 520);
        } else {
          state.assistantWidth = clamp(startWidth - delta, 280, 520);
        }
        render();
      };

      const onUp = () => {
        handle.classList.remove('is-dragging');
        window.removeEventListener('pointermove', onMove);
        window.removeEventListener('pointerup', onUp);
      };

      window.addEventListener('pointermove', onMove);
      window.addEventListener('pointerup', onUp);
    };
  });
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

render();
function renderStatusBar() {
  const active = activeTab();
  const dirty = active && rootState.dirty_tabs.some(entry => sameTab(entry, active));
  const postStatus = active && active.type === "post" ? (dirty ? "draft" : "published") : null;
  const tokenUsage = active && active.type === "chat" ? "I 120 · O 42 · C 8" : null;

  statusBar.innerHTML = `
    <div class="status-left">
      <select data-action="project-select">
        <option selected>${rootState.project}</option>
      </select>
      <span class="status-pill">${rootState.running_task_message}${rootState.running_task_overflow ? ` +${rootState.running_task_overflow}` : ""}</span>
    </div>
    <div class="status-right">
      ${postStatus ? `<span class="status-chip status-post" data-status="${postStatus}">${postStatus}</span>` : ""}
      <span class="status-chip">${rootState.post_count} posts</span>
      <span class="status-chip">${rootState.media_count} media</span>
      ${tokenUsage ? `<span class="status-chip">${tokenUsage}</span>` : ""}
      <select data-action="theme-select">
        ${["zinc", "amber", "jade", "sand"].map(theme => `<option value="${theme}" ${theme === rootState.theme_badge ? "selected" : ""}>${theme}</option>`).join("")}
      </select>
      <button class="offline-toggle" data-action="toggle-offline" data-active="${String(rootState.offline_mode)}">${rootState.offline_mode ? "Offline" : "Online"}</button>
      <select data-action="language-select">
        ${["en", "de", "fr", "it", "es"].map(language => `<option value="${language}" ${language === rootState.ui_language ? "selected" : ""}>${language.toUpperCase()}</option>`).join("")}
      </select>
      <span class="status-pill">bDS</span>
    </div>
  `;
}

function wireGlobalEvents() {
  document.addEventListener("click", handleClick);
  document.addEventListener("dblclick", handleDoubleClick);
  document.addEventListener("keydown", handleKeyDown);
  document.addEventListener("change", handleChange);
  document.querySelectorAll('[data-role="resize-handle"]').forEach(handle => {
    handle.addEventListener("pointerdown", startResize);
  });
}

function handleClick(event) {
  const commandButton = event.target.closest("[data-command]");
  if (commandButton) {
    event.preventDefault();
    executeCommand(commandButton.dataset.command);
    return;
  }

  const menuTrigger = event.target.closest("[data-menu-trigger]");
  if (menuTrigger) {
    const id = menuTrigger.dataset.menuTrigger;
    openMenu = openMenu === id ? null : id;
    render();
    return;
  }

  if (!event.target.closest(".menu-group")) {
    if (openMenu !== null) {
      openMenu = null;
      renderTitleBar();
    }
  }

  const activity = event.target.closest("[data-activity]");
  if (activity) {
    clickActivity(activity.dataset.activity);
    return;
  }

  const activate = event.target.closest("[data-tab-activate]");
  if (activate) {
    const [type, id] = activate.dataset.tabActivate.split(":");
    rootState.active_tab = { type, id };
    normalizePanel();
    render();
    return;
  }

  const closeButton = event.target.closest("[data-tab-close]");
  if (closeButton) {
    const [type, id] = closeButton.dataset.tabClose.split(":");
    closeTab(type, id);
    return;
  }

  const demoButton = event.target.closest("[data-open-demo]");
  if (demoButton) {
    openDemoFromView(demoButton.dataset.openDemo);
    return;
  }

  const action = event.target.closest("[data-action]");
  if (action) {
    handleAction(action.dataset.action);
    return;
  }

  const panelTab = event.target.closest("[data-panel-tab]");
  if (panelTab && !panelTab.disabled) {
    rootState.panel.active_tab = panelTab.dataset.panelTab;
    render();
  }
}

function handleDoubleClick(event) {
  const tab = event.target.closest("[data-tab-type][data-tab-id]");
  if (!tab) return;

  const type = tab.dataset.tabType;
  const id = tab.dataset.tabId;
  const found = rootState.tabs.find(entry => entry.type === type && entry.id === id);

  if (found && found.is_transient) {
    found.is_transient = false;
    render();
  }
}

function handleKeyDown(event) {
  const primary = event.metaKey || event.ctrlKey;
  if (!primary) return;

  const key = event.key.toLowerCase();

  if (key === "b") {
    event.preventDefault();
    executeCommand("toggle_sidebar");
  }

  if (key === "w") {
    event.preventDefault();
    executeCommand("close_tab");
  }
}

function handleChange(event) {
  const action = event.target.dataset.action;
  if (!action) return;

  if (action === "theme-select") {
    rootState.theme_badge = event.target.value;
    render();
  }

  if (action === "language-select") {
    rootState.ui_language = event.target.value;
    render();
  }
}

function startResize(event) {
  const target = event.currentTarget.dataset.target;
  const initialX = event.clientX;
  const initialWidth = target === "sidebar" ? rootState.sidebar_width : rootState.assistant_sidebar_width;

  const move = moveEvent => {
    const delta = moveEvent.clientX - initialX;

    if (target === "sidebar") {
      rootState.sidebar_width = clamp(initialWidth + delta, 200, 500);
    } else {
      rootState.assistant_sidebar_width = clamp(initialWidth - delta, 280, 640);
    }

    render();
  };

  const stop = () => {
    window.removeEventListener("pointermove", move);
    window.removeEventListener("pointerup", stop);
  };

  window.addEventListener("pointermove", move);
  window.addEventListener("pointerup", stop);
}

function executeCommand(command) {
  if (command === "toggle_sidebar") {
    rootState.sidebar_visible = !rootState.sidebar_visible;
  }

  if (command === "toggle_panel") {
    rootState.panel.visible = !rootState.panel.visible;
  }

  if (command === "toggle_assistant_sidebar") {
    rootState.assistant_sidebar_visible = !rootState.assistant_sidebar_visible;
  }

  if (command === "close_tab" && rootState.active_tab) {
    closeTab(rootState.active_tab.type, rootState.active_tab.id);
    return;
  }

  if (command === "settings") {
    openTab("settings", "settings", "pin");
  }

  if (command === "documentation") {
    openTab("documentation", "documentation", "pin");
  }

  if (command === "api_documentation") {
    openTab("api_documentation", "api_documentation", "pin");
  }

  normalizePanel();
  render();
}

function handleAction(action) {
  if (action === "toggle-dirty") {
    const active = activeTab();
    if (!active || active.type !== "post") return;

    const index = rootState.dirty_tabs.findIndex(entry => sameTab(entry, active));
    if (index >= 0) {
      rootState.dirty_tabs.splice(index, 1);
    } else {
      rootState.dirty_tabs.push({ type: active.type, id: active.id });
    }
    render();
    return;
  }

  if (action === "pin-active") {
    const active = activeTab();
    if (!active) return;
    const found = rootState.tabs.find(tab => sameTab(tab, active));
    if (found) found.is_transient = false;
    render();
    return;
  }

  if (action === "toggle-offline") {
    rootState.offline_mode = !rootState.offline_mode;
    render();
    return;
  }

  if (action === "reset-session") {
    localStorage.removeItem(sessionKey);
    location.reload();
    return;
  }

  if (action === "open-chat") {
    openTab("chat", "conversation-demo", "pin");
  }
}

function clickActivity(id) {
  if (rootState.active_view === id) {
    rootState.sidebar_visible = !rootState.sidebar_visible;
  } else {
    rootState.active_view = id;
    rootState.sidebar_visible = true;
  }
  render();
}

function openDemoFromView(mode) {
  const view = registry.sidebar_views.find(entry => entry.id === rootState.active_view) || registry.sidebar_views[0];
  const type = view.editor_route;
  const isSingleton = !!view.singleton;
  const id = isSingleton ? type : `${rootState.active_view}-demo-${view.activity_group === "bottom" ? "tool" : "item"}`;
  const intent = mode === "pin" ? "pin" : "preview";

  if (mode === "background") {
    openTab(type, id, intent, true);
  } else {
    openTab(type, id, intent, false);
  }
}

function openTab(type, id, intent, background) {
  const existing = rootState.tabs.find(tab => tab.type === type && tab.id === id);
  const singleton = !!routeMeta(type)?.singleton;
  const sticky = type === "chat" || type === "import" || singleton;
  const transient = !sticky && intent === "preview";

  if (existing) {
    if (intent === "pin") existing.is_transient = false;
    if (!background) rootState.active_tab = { type, id };
    normalizePanel();
    render();
    return;
  }

  if (transient) {
    const replacementIndex = rootState.tabs.findIndex(tab => tab.type === type && tab.is_transient);
    const newTab = { type, id, is_transient: true };
    if (replacementIndex >= 0) {
      rootState.tabs.splice(replacementIndex, 1, newTab);
    } else {
      rootState.tabs.push(newTab);
    }
  } else {
    rootState.tabs.push({ type, id, is_transient: false });
  }

  if (!background) {
    rootState.active_tab = { type, id };
  }

  normalizePanel();
  render();
}

function closeTab(type, id) {
  const index = rootState.tabs.findIndex(tab => tab.type === type && tab.id === id);
  if (index < 0) return;

  rootState.tabs.splice(index, 1);
  rootState.dirty_tabs = rootState.dirty_tabs.filter(tab => !(tab.type === type && tab.id === id));

  if (rootState.active_tab && rootState.active_tab.type === type && rootState.active_tab.id === id) {
    if (rootState.tabs[index]) {
      rootState.active_tab = { type: rootState.tabs[index].type, id: rootState.tabs[index].id };
    } else if (rootState.tabs[index - 1]) {
      rootState.active_tab = { type: rootState.tabs[index - 1].type, id: rootState.tabs[index - 1].id };
    } else {
      rootState.active_tab = null;
    }
  }

  normalizePanel();
  render();
}

function normalizePanel() {
  const route = activeTab() ? activeTab().type : "dashboard";
  if (!panelAvailable(route, rootState.panel.active_tab)) {
    rootState.panel.active_tab = "tasks";
  }
}

function panelAvailable(route, tab) {
  if (tab === "tasks" || tab === "output") return true;
  if (tab === "post_links") return route === "post";
  if (tab === "git_log") return route === "post" || route === "media";
  return false;
}

function activeTab() {
  if (!rootState.active_tab) return null;
  return rootState.tabs.find(tab => sameTab(tab, rootState.active_tab)) || null;
}

function routeMeta(id) {
  return registry.editor_routes.find(route => route.id === id) || null;
}

function sameTab(left, right) {
  return !!left && !!right && left.type === right.type && left.id === right.id;
}

function tabTitle(tab) {
  const meta = routeMeta(tab.type);
  const prefix = meta ? meta.title : titleCase(tab.type);
  if (meta && meta.singleton) return prefix;
  return `${prefix} ${tab.id}`;
}

function labelForPanel(tab) {
  return {
    tasks: "Tasks",
    output: "Output",
    post_links: "Post Links",
    git_log: "Git Log"
  }[tab] || titleCase(tab);
}

function labelForCommand(id) {
  return id
    .split("_")
    .map(titleCase)
    .join(" ");
}

function compactLabel(label) {
  return label.split(" ").map(part => part[0]).join("").slice(0, 3).toUpperCase();
}

function titleCase(value) {
  return String(value)
    .split(/[_\s-]+/)
    .filter(Boolean)
    .map(part => part[0].toUpperCase() + part.slice(1))
    .join(" ");
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, Number(value) || min));
}

function safeParse(value) {
  try {
    return value ? JSON.parse(value) : null;
  } catch (_error) {
    return null;
  }
}
