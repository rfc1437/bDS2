const root = document.getElementById("bds-shell-app");
const bootstrapNode = document.getElementById("bds-shell-bootstrap");

if (!root || !bootstrapNode) {
  throw new Error("Missing shell bootstrap payload");
}

const SIDEBAR_STORAGE_KEY = "bds-panel-sidebar";
const ASSISTANT_STORAGE_KEY = "bds-panel-assistant-sidebar";
const TASK_STATUS_POLL_MS = 1500;
const bootstrap = JSON.parse(bootstrapNode.textContent);
const isMac = typeof navigator !== "undefined" && navigator.platform.toLowerCase().includes("mac");
const state = {
  session: hydrateSession(clone(bootstrap.session)),
  status: clone(bootstrap.status),
  projects: normalizeProjects(bootstrap.projects),
  projectMenuOpen: false,
  taskStatus: normalizeTaskStatus(bootstrap.task_status),
  handledTaskResults: {},
  outputEntries: [],
  gitLogEntries: [],
  uiLanguage: readStoredUiLanguage(bootstrap.i18n?.ui_language || bootstrap.status.right.ui_language),
  supportedUiLanguages: bootstrap.i18n?.supported_ui_languages || [],
  tabMeta: {},
};

function translationsForLanguage(language) {
  return bootstrap.i18n?.catalogs?.[language] || bootstrap.i18n?.catalogs?.en || {};
}

function t(key, bindings = {}) {
  const catalog = translationsForLanguage(state.uiLanguage);
  let text = catalog[key] || key;

  Object.entries(bindings).forEach(([binding, value]) => {
    text = text.replaceAll(`%{${binding}}`, String(value));
  });

  return text;
}

function tText(value, bindings = {}) {
  return t(String(value), bindings);
}

bindNativeMenuBridge();
bindGlobalHotkeys();
scheduleTaskPolling();
void fetchProjects();
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
  const menuBarClass = isMac ? "window-titlebar-menu-bar is-hidden" : "window-titlebar-menu-bar";

  root.querySelector(".window-titlebar").innerHTML = `
    <div class="${menuBarClass}">
      ${bootstrap.menu_groups
        .map((group) => `<button class="window-titlebar-menu-button" type="button">${escapeHtml(tText(group.label))}</button>`)
        .join("")}
    </div>
    <div class="window-titlebar-drag-region"></div>
    <div class="window-titlebar-title" data-testid="window-title">${escapeHtml(bootstrap.title)}</div>
    <div class="window-titlebar-actions">
      ${renderTitlebarAction("toggle-sidebar", "toggle-sidebar", t("Toggle sidebar"), `
        <span class="window-titlebar-sidebar-icon ${state.session.sidebar_visible ? "is-active" : "is-inactive"}">
          <span class="window-titlebar-sidebar-pane"></span>
        </span>
      `)}
      ${renderTitlebarAction("toggle-panel", "toggle-panel", t("Toggle panel"), `
        <span class="window-titlebar-panel-icon ${state.session.panel.visible ? "is-active" : "is-inactive"}">
          <span class="window-titlebar-panel-pane"></span>
        </span>
      `)}
      ${renderTitlebarAction("toggle-assistant-sidebar", "toggle-assistant", t("Toggle assistant"), `
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
      aria-label="${escapeHtml(tText(view.label))}"
      title="${escapeHtml(tText(view.label))}"
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
        <strong>${escapeHtml(tText(data.title))}</strong>
        <span class="sidebar-subtitle">${escapeHtml(tText(data.subtitle))}</span>
      </div>
    </div>
    <div class="sidebar-content">
      ${data.sections
        .map(
          (section) => `
            <section class="sidebar-section">
              <div class="sidebar-section-header">
                <span data-testid="sidebar-section-title">${escapeHtml(tText(section.title))}</span>
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
      data-open-title="${escapeHtmlAttribute(tText(item.title))}"
      type="button"
    >
      <strong>${escapeHtml(tText(item.title))}</strong>
      <span>${escapeHtml(tText(item.meta || view.label))}</span>
      ${item.badge ? `<span class="sidebar-badge">${escapeHtml(tText(item.badge))}</span>` : ""}
    </button>
  `;
}

function renderTabs() {
  const tabs = state.session.tabs;
  const node = root.querySelector(".tab-bar");

  if (tabs.length === 0) {
    node.innerHTML = `<div class="tab-bar-empty">${escapeHtml(t("Dashboard"))}</div>`;
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
      <span class="tab-title">${escapeHtml(tText(meta.title))}</span>
      <span class="tab-close" data-close-tab="${tab.type}:${tab.id}" role="button" aria-label="${escapeHtmlAttribute(t("Close %{title}", { title: tText(meta.title) }))}" title="${escapeHtmlAttribute(t("Close tab"))}">×</span>
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
                <strong data-testid="editor-meta-label">${escapeHtml(tText(item.label))}</strong>
                <span>${escapeHtml(tText(item.value))}</span>
              </section>
            `
          )
          .join("")}
      </aside>
    </div>
  `;
}

function renderEditorBody(route) {
  const meta = currentTabMeta();

  if (route === "dashboard") {
    const dashboard = bootstrap.content.dashboard;
    return `
      <section class="editor-section">
        <ul class="editor-list compact">
          ${dashboard.summary_cards
            .map((card) => `<li><strong>${escapeHtml(tText(card.label))}:</strong> ${escapeHtml(card.value)} <span>${escapeHtml(tText(card.detail))}</span></li>`)
            .join("")}
        </ul>
      </section>
      <section class="editor-section">
        <h2>${escapeHtml(t("Workbench Notes"))}</h2>
        <ul class="editor-list">
          ${dashboard.checklist.map((entry) => `<li>${escapeHtml(tText(entry))}</li>`).join("")}
        </ul>
      </section>
    `;
  }

  if (meta?.payload) {
    return renderCommandPayload(route, meta.payload);
  }

  const active = activeItem();
  return `
    <div class="editor-toolbar">
      <button class="editor-toolbar-button" type="button">${escapeHtml(t("Open"))}</button>
      <button class="editor-toolbar-button" type="button">${escapeHtml(t("Preview"))}</button>
      <button class="editor-toolbar-button" type="button">${escapeHtml(t("Metadata"))}</button>
    </div>
    <div class="editor-section">
      <h2>${escapeHtml(tText(active?.title || routeLabel(route)))}</h2>
      <p>${escapeHtml(tText(active?.meta || "Desktop workbench content routed through the Elixir shell."))}</p>
    </div>
  `;
}

function renderPanel() {
  const tabs = panelTabs();

  root.querySelector(".panel-shell").innerHTML = `
    <div class="panel-header">
      <div class="panel-tabs">
        ${tabs.map((tab) => renderPanelTab(tab)).join("")}
      </div>
    </div>
    <div class="panel-content">
      ${renderPanelBody()}
    </div>
  `;
}

function renderPanelBody() {
  if (state.session.panel.active_tab === "tasks") {
    return renderTaskPanelEntries();
  }

  if (state.session.panel.active_tab === "output") {
    return renderOutputEntries();
  }

  if (state.session.panel.active_tab === "git_log") {
    return renderGitLogEntries();
  }

  return `
    <div class="panel-entry">
      <strong>${escapeHtml(routeLabel(state.session.panel.active_tab))}</strong>
      <span>${escapeHtml(t("The shared lower panel is available for tasks, output, git details, and editor-specific diagnostics."))}</span>
    </div>
  `;
}

function renderTaskPanelEntries() {
  if (!state.taskStatus.tasks.length) {
    return `
      <div class="panel-entry panel-empty-state">
        <strong>${escapeHtml(t("Tasks"))}</strong>
        <span>${escapeHtml(t("No background tasks running"))}</span>
      </div>
    `;
  }

  return `
    <div class="task-list">
      ${state.taskStatus.tasks.map((task) => renderTaskEntry(task)).join("")}
    </div>
  `;
}

function renderTaskEntry(task) {
  const progress = typeof task.progress === "number" ? `${Math.round(task.progress * 100)}%` : null;
  const statusDetail = [task.group_name, progress].filter(Boolean).join(" • ");
  const message = task.message || statusLabel(task.status);

  return `
    <div class="panel-entry task-entry">
      <div class="task-entry-header">
        <strong>${escapeHtml(task.name)}</strong>
        <span class="task-status task-status-${escapeHtmlAttribute(task.status)}">${escapeHtml(statusLabel(task.status))}</span>
      </div>
      ${statusDetail ? `<span>${escapeHtml(statusDetail)}</span>` : ""}
      <span>${escapeHtml(message)}</span>
    </div>
  `;
}

function renderOutputEntries() {
  if (!state.outputEntries.length) {
    return `
      <div class="panel-entry panel-empty-state output-list">
        <strong>${escapeHtml(t("Output"))}</strong>
        <span>${escapeHtml(t("No shell output yet"))}</span>
      </div>
    `;
  }

  return `
    <div class="output-list">
      ${state.outputEntries
        .map(
          (entry) => `
            <div class="panel-entry output-item">
              <strong>${escapeHtml(entry.title)}</strong>
              <span>${escapeHtml(entry.message)}</span>
              ${entry.details ? `<pre class="output-item-details">${escapeHtml(entry.details)}</pre>` : ""}
            </div>
          `
        )
        .join("")}
    </div>
  `;
}

function renderGitLogEntries() {
  return `
    <div class="git-log-list">
      <div class="panel-entry">
        <strong>${escapeHtml(t("Git Log"))}</strong>
        <span>${escapeHtml(t("Working tree integration is not wired yet in the shell, but the tab is selectable and ready for command output."))}</span>
      </div>
    </div>
  `;
}

function renderAssistant() {
  root.querySelector(".assistant-sidebar").innerHTML = `
    <div class="assistant-header">
      <strong>${escapeHtml(t("Assistant"))}</strong>
    </div>
    <div class="assistant-content">
      ${bootstrap.content.assistant_cards
        .map(
          (card) => `
            <section class="assistant-card">
              <strong>${escapeHtml(tText(card.label))}</strong>
              <span>${escapeHtml(tText(card.text))}</span>
            </section>
          `
        )
        .join("")}
    </div>
  `;
}

function renderStatusBar() {
  const status = state.status;
  const taskOverflow = state.taskStatus.running_task_overflow;
  const taskMessage = state.taskStatus.running_task_message || t("Idle");
  const postCount = status.right.post_count_value ?? status.right.post_count;
  const mediaCount = status.right.media_count_value ?? status.right.media_count;

  root.querySelector(".status-bar").innerHTML = `
    <div class="status-bar-left">
      ${renderProjectSelector()}
      <button class="status-bar-item status-bar-task-button" data-command="open-tasks-panel" type="button">
        <span>${escapeHtml(tText(taskMessage))}</span>
        ${taskOverflow > 0 ? `<span class="status-bar-count">+${taskOverflow}</span>` : ""}
      </button>
    </div>
    <div class="status-bar-right">
      <span class="status-bar-item">${escapeHtml(typeof postCount === "number" ? t("%{count} posts", { count: postCount }) : tText(postCount))}</span>
      <span class="status-bar-item">${escapeHtml(typeof mediaCount === "number" ? t("%{count} media", { count: mediaCount }) : tText(mediaCount))}</span>
      <span class="status-bar-item theme-badge">${escapeHtml(status.right.theme_badge)}</span>
      <button class="status-bar-item offline-badge${status.right.offline_mode ? " active" : ""}" data-command="toggle-offline-mode" type="button" title="${escapeHtmlAttribute(t("Toggle offline mode"))}">✈</button>
      <label class="status-bar-item language-badge">
        <span>${escapeHtml(t("UI"))}</span>
        <select class="status-bar-language-select" data-command="set-ui-language">${renderLanguageOptions()}</select>
      </label>
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
  root.querySelectorAll("button[data-command]").forEach((button) => {
    button.onclick = () => {
      const command = button.dataset.command;
      if (command === "create-project") {
        void createProject();
        return;
      }
      if (command === "open-tasks-panel") {
        openTasksPanel();
        render();
        return;
      }
      if (command === "toggle-offline-mode") {
        executeShellCommand("toggle_offline_mode");
        return;
      }
      executeShellCommand(command.replace(/-/g, "_"));
    };
  });

  root.querySelectorAll("[data-project-menu-trigger]").forEach((button) => {
    button.onclick = (event) => {
      event.stopPropagation();
      toggleProjectMenu();
    };
  });

  root.querySelectorAll("[data-project-id]").forEach((button) => {
    button.onclick = () => {
      void selectProject(button.dataset.projectId);
    };
  });

  root.querySelectorAll("[data-project-create]").forEach((button) => {
    button.onclick = () => {
      void createProject();
    };
  });

  root.querySelectorAll("[data-project-import]").forEach((button) => {
    button.onclick = () => {
      void importExistingProject();
    };
  });

  root.querySelectorAll("[data-command='set-ui-language']").forEach((select) => {
    select.onchange = (event) => {
      setUiLanguage(event.target.value);
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

  root.querySelectorAll("[data-close-tab]").forEach((button) => {
    button.onclick = (event) => {
      event.stopPropagation();
      const [type, id] = button.dataset.closeTab.split(":");
      closeSpecificTab(type, id);
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

  bindProjectMenuDismiss();
}

function bindNativeMenuBridge() {
  if (window.__BDS_NATIVE_MENU_BRIDGE__) {
    return;
  }

  window.__BDS_NATIVE_MENU_BRIDGE__ = true;
  window.addEventListener("bds:native-menu-action", (event) => {
    handleNativeMenuAction(event.detail?.action);
  });
}

function bindGlobalHotkeys() {
  if (window.__BDS_KEYBOARD_BOUND__) {
    return;
  }

  window.__BDS_KEYBOARD_BOUND__ = true;
  window.addEventListener("keydown", (event) => {
    if (!(event.metaKey || event.ctrlKey) || event.altKey) {
      return;
    }

    if (event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement || event.target instanceof HTMLSelectElement) {
      return;
    }

    const key = event.key.toLowerCase();
    let command = null;

    switch (key) {
      case "b":
        command = "toggle_sidebar";
        break;
      case "j":
        command = "toggle_panel";
        break;
      case "1":
        command = "view_posts";
        break;
      case "2":
        command = "view_media";
        break;
      case "\\":
        command = "toggle_assistant_sidebar";
        break;
      case "w":
        command = "close_tab";
        break;
      default:
        command = null;
    }

    if (!command) {
      return;
    }

    event.preventDefault();
    executeShellCommand(command);
  });
}

function scheduleTaskPolling() {
  window.setInterval(fetchTaskStatus, TASK_STATUS_POLL_MS);
  void fetchTaskStatus();
}

async function fetchTaskStatus() {
  try {
    const response = await fetch("/api/tasks", {
      headers: { Accept: "application/json" },
      cache: "no-store",
    });

    if (!response.ok) {
      return;
    }

    const next = normalizeTaskStatus(await response.json());

    if (JSON.stringify(next) === JSON.stringify(state.taskStatus)) {
      return;
    }

    state.taskStatus = next;
    state.status.left.running_task_message = next.running_task_message;
    state.status.left.running_task_overflow = next.running_task_overflow;
    applyCompletedTaskResults(next.tasks);
    render();
  } catch (_error) {
    // Keep the shell usable if task polling is temporarily unavailable.
  }
}

function applyCompletedTaskResults(tasks) {
  pruneHandledTaskResults(tasks);

  tasks.forEach((task) => {
    if (task.status !== "completed" || state.handledTaskResults[task.id]) {
      return;
    }

    if (!task.result || typeof task.result !== "object" || typeof task.result.kind !== "string") {
      return;
    }

    state.handledTaskResults[task.id] = true;
    applyShellCommandResult(task.result);
  });
}

function pruneHandledTaskResults(tasks) {
  const visibleTaskIds = new Set(tasks.map((task) => task.id));

  Object.keys(state.handledTaskResults).forEach((taskId) => {
    if (!visibleTaskIds.has(taskId)) {
      delete state.handledTaskResults[taskId];
    }
  });
}

async function fetchProjects() {
  try {
    const response = await fetch("/api/projects", {
      headers: { Accept: "application/json" },
      cache: "no-store",
    });

    if (!response.ok) {
      return;
    }

    state.projects = normalizeProjects(await response.json());
    if (!state.projects.active_project_id && state.projects.projects.length) {
      state.projects.active_project_id = state.projects.projects[0].id;
    }
    render();
  } catch (_error) {
    // Keep the shell usable if project loading is temporarily unavailable.
  }
}

async function chooseProjectFolder() {
  try {
    const response = await fetch("/api/project-folder", {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ prompt: t("Select existing blog folder") }),
    });

    const payload = await response.json();

    if (!response.ok || payload.status === "error") {
      appendOutputEntry(t("Open Existing Blog"), payload.error?.message || t("Command failed with HTTP %{status}", { status: response.status }));
      setPanelTab("output");
      render();
      return null;
    }

    if (payload.status === "cancel") {
      return null;
    }

    return payload;
  } catch (error) {
    appendOutputEntry(t("Open Existing Blog"), error?.message || String(error));
    setPanelTab("output");
    render();
    return null;
  }
}

async function createProject(options = {}) {
  const suggestedName = options.name ? String(options.name).trim() : "";
  const name = suggestedName || window.prompt(t("New project name"), t("New Project"));
  if (!name || !name.trim()) {
    return;
  }

  closeProjectMenu();

  try {
    const response = await fetch("/api/projects", {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        name: name.trim(),
        description: options.description,
        data_path: options.dataPath,
      }),
    });

    const payload = await response.json();

    if (!response.ok || payload.status !== "ok") {
      appendOutputEntry(t("Create Project"), payload.error?.message || t("Command failed with HTTP %{status}", { status: response.status }));
      setPanelTab("output");
      render();
      return;
    }

    await fetchProjects();
    appendOutputEntry(t("Create Project"), t("Activated %{name}", { name: payload.project.name }));
    render();
  } catch (error) {
    appendOutputEntry(t("Create Project"), error?.message || String(error));
    setPanelTab("output");
    render();
  }
}

async function importExistingProject() {
  closeProjectMenu();

  const selection = await chooseProjectFolder();

  if (!selection) {
    return;
  }

  if (selection.existing_project_id) {
    await selectProject(selection.existing_project_id);
    return;
  }

  await createProject({
    name: selection.name,
    description: selection.description,
    dataPath: selection.path,
  });
}

async function selectProject(projectId) {
  if (!projectId || projectId === state.projects.active_project_id) {
    closeProjectMenu();
    return;
  }

  closeProjectMenu();

  try {
    const response = await fetch("/api/projects", {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ project_id: projectId }),
    });

    const payload = await response.json();

    if (!response.ok || payload.status !== "ok") {
      appendOutputEntry(t("Select Project"), payload.error?.message || t("Command failed with HTTP %{status}", { status: response.status }));
      setPanelTab("output");
      render();
      return;
    }

    await fetchProjects();
    appendOutputEntry(t("Select Project"), t("Activated %{name}", { name: payload.project.name }));
    render();
  } catch (error) {
    appendOutputEntry(t("Select Project"), error?.message || String(error));
    setPanelTab("output");
    render();
  }
}

function openTasksPanel() {
  state.session.panel.visible = true;
  state.session.panel.active_tab = "tasks";
}

function handleNativeMenuAction(action) {
  executeShellCommand(action);
}

function executeShellCommand(action) {
  if (!action) {
    return;
  }

  if (executeLocalShellCommand(action)) {
    render();
    return;
  }

  void executeBackendShellCommand(action);
}

function executeLocalShellCommand(action) {
  switch (action) {
    case "toggle_sidebar":
      state.session.sidebar_visible = !state.session.sidebar_visible;
      persistSessionWidths();
      return true;
    case "toggle_panel":
      state.session.panel.visible = !state.session.panel.visible;
      if (state.session.panel.visible && !state.session.panel.active_tab) {
        state.session.panel.active_tab = "tasks";
      }
      return true;
    case "toggle_assistant_sidebar":
      state.session.assistant_sidebar_visible = !state.session.assistant_sidebar_visible;
      persistSessionWidths();
      return true;
    case "view_posts":
      state.session.active_view = "posts";
      state.session.sidebar_visible = true;
      return true;
    case "view_media":
      state.session.active_view = "media";
      state.session.sidebar_visible = true;
      return true;
    case "close_tab":
      closeActiveTab();
      return true;
    case "edit_preferences":
      openSingletonTab("settings");
      return true;
    case "edit_menu":
      openSingletonTab("menu_editor");
      return true;
    case "documentation":
      openSingletonTab("documentation");
      return true;
    case "api_documentation":
      openSingletonTab("api_documentation");
      return true;
    case "regenerate_calendar":
      appendOutputEntry(t("Regenerate Calendar"), t("Calendar regeneration is not wired yet, but the base shell now surfaces the command and keeps the Output tab selectable."));
      setPanelTab("output");
      return true;
    case "fill_missing_translations":
      appendOutputEntry(t("Fill Missing Translations"), t("Translation fill is not wired yet, but the command is now routed into Output instead of being ignored."));
      setPanelTab("output");
      return true;
    case "toggle_offline_mode":
      state.status.right.offline_mode = !state.status.right.offline_mode;
      return true;
    default:
      return false;
  }
}

async function executeBackendShellCommand(action) {
  try {
    const response = await fetch("/api/commands", {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ action }),
    });

    if (!response.ok) {
      appendOutputEntry(routeLabel(action), t("Command failed with HTTP %{status}", { status: response.status }));
      setPanelTab("output");
      render();
      return;
    }

    const payload = await response.json();

    if (payload.status !== "ok") {
      applyShellCommandError(action, payload.error || { message: "Unknown shell command error" });
      return;
    }

    applyShellCommandResult(payload.result);
  } catch (error) {
    applyShellCommandError(action, { message: error?.message || String(error) });
  }
}

function applyShellCommandResult(result) {
  if (!result) {
    return;
  }

  switch (result.kind) {
    case "task_queued":
      appendOutputEntry(result.title, result.message);
      setPanelTab(result.panel_tab || "tasks");
      void fetchTaskStatus();
      break;
    case "open_url":
      appendOutputEntry(tText(result.title), tText(result.url || result.message || "Opened URL"));
      setPanelTab("output");

      if (result.url) {
        window.open(result.url, "_blank", "noopener");
      }

      break;
    case "open_editor":
      openSingletonTab(result.route, {
        title: result.title,
        subtitle: result.subtitle,
        editorMeta: result.editorMeta,
        payload: result.payload,
      });
      return;
    case "output":
      appendOutputEntry(tText(result.title), tText(result.message), result.details);
      setPanelTab(result.panel_tab || "output");
      break;
    default:
      appendOutputEntry(routeLabel(result.action || "output"), tText(result.message || "Command completed"));
      setPanelTab("output");
      break;
  }

  render();
}

function applyShellCommandError(action, error) {
  appendOutputEntry(routeLabel(action), error?.message || t("Command failed"));
  setPanelTab("output");
  render();
}

function setPanelTab(tab) {
  state.session.panel.visible = true;
  state.session.panel.active_tab = tab;
}

function appendOutputEntry(title, message, details = "") {
  state.outputEntries = [{ title, message, details }, ...state.outputEntries].slice(0, 20);
}

function openSingletonTab(type, meta = {}) {
  openTab(type, type, meta.title || routeLabel(type), false, meta);
}

function closeActiveTab() {
  const active = currentTabRef();
  if (!active) {
    return;
  }

  const index = state.session.tabs.findIndex((tab) => tab.type === active.type && tab.id === active.id);
  if (index < 0) {
    return;
  }

  state.session.tabs.splice(index, 1);

  if (state.session.tabs.length === 0) {
    state.session.active_tab = null;
    return;
  }

  if (index < state.session.tabs.length) {
    const next = state.session.tabs[index];
    state.session.active_tab = { type: next.type, id: next.id };
  } else {
    const next = state.session.tabs[state.session.tabs.length - 1];
    state.session.active_tab = { type: next.type, id: next.id };
  }
}

function closeSpecificTab(type, id) {
  const index = state.session.tabs.findIndex((tab) => tab.type === type && tab.id === id);

  if (index < 0) {
    return;
  }

  const wasActive = state.session.active_tab?.type === type && state.session.active_tab?.id === id;
  state.session.tabs.splice(index, 1);
  delete state.tabMeta[`${type}:${id}`];

  if (!state.session.tabs.length) {
    state.session.active_tab = null;
    return;
  }

  if (!wasActive) {
    return;
  }

  const next = state.session.tabs[Math.min(index, state.session.tabs.length - 1)];
  state.session.active_tab = { type: next.type, id: next.id };
}

function openTab(type, id, title, transient, meta = {}) {
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

  state.tabMeta[`${type}:${id}`] = { title, ...meta };
  state.session.active_tab = { type, id };
  render();
}

function currentTabMeta() {
  const tab = currentTabRef();
  return tab ? state.tabMeta[`${tab.type}:${tab.id}`] : null;
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
    return { title: tText(item.title) };
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
  const meta = currentTabMeta();
  return meta?.editorMeta || bootstrap.content.editor_meta[currentRoute()] || bootstrap.content.editor_meta.dashboard;
}

function editorTitle() {
  const meta = currentTabMeta();
  if (meta?.title) {
    return tText(meta.title);
  }

  const item = activeItem();
  return tText(item?.title || bootstrap.content.dashboard.title);
}

function editorSubtitle(route) {
  const meta = currentTabMeta();
  if (meta?.subtitle) {
    return tText(meta.subtitle);
  }

  if (route === "dashboard") {
    return tText(bootstrap.content.dashboard.subtitle);
  }

  const item = activeItem();
  return tText(item?.meta || "Desktop workbench content routed through the Elixir shell.");
}

function routeLabel(route) {
  if (!route) {
    return t("Dashboard");
  }

  if (route === "output") {
    return t("Output");
  }

  if (route === "git_log") {
    return t("Git Log");
  }

  if (route === "open_in_browser") {
    return t("Open in Browser");
  }

  if (route === "open_data_folder") {
    return t("Open Data Folder");
  }

  if (route === "upload_site") {
    return t("Upload Site");
  }

  return tText(
    bootstrap.registry.editor_routes.find((item) => item.id === route)?.title ||
    sidebarViews().find((item) => item.id === route)?.label ||
    titleCase(route)
  );
}

function renderCommandPayload(route, payload) {
  switch (route) {
    case "metadata_diff":
      return `
        <section class="editor-section">
          <ul class="editor-list compact">
            <li><strong>${escapeHtml(t("Diffs"))}:</strong> ${escapeHtml(String(payload.summary?.diff_count || 0))}</li>
            <li><strong>${escapeHtml(t("Orphans"))}:</strong> ${escapeHtml(String(payload.summary?.orphan_count || 0))}</li>
          </ul>
        </section>
        <section class="editor-section">
          <h2>${escapeHtml(t("Diff Reports"))}</h2>
          ${renderKeyedEntries(payload.diff_reports, ["entity_type", "entity_id", "differences"])}
        </section>
        <section class="editor-section">
          <h2>${escapeHtml(t("Orphan Reports"))}</h2>
          ${renderKeyedEntries(payload.orphan_reports, ["entity_type", "path"])}
        </section>
      `;
    case "site_validation":
      return `
        <section class="editor-section">
          <ul class="editor-list compact">
            <li><strong>${escapeHtml(t("Missing"))}:</strong> ${escapeHtml(String(payload.summary?.missing_count || 0))}</li>
            <li><strong>${escapeHtml(t("Extra"))}:</strong> ${escapeHtml(String(payload.summary?.extra_count || 0))}</li>
            <li><strong>${escapeHtml(t("Stale"))}:</strong> ${escapeHtml(String(payload.summary?.stale_count || 0))}</li>
          </ul>
        </section>
        <section class="editor-section">
          <h2>${escapeHtml(t("Missing Pages"))}</h2>
          ${renderStringList(payload.missing_pages, t("No missing pages"))}
        </section>
        <section class="editor-section">
          <h2>${escapeHtml(t("Extra Pages"))}</h2>
          ${renderStringList(payload.extra_pages, t("No extra pages"))}
        </section>
        <section class="editor-section">
          <h2>${escapeHtml(t("Stale Pages"))}</h2>
          ${renderStringList(payload.stale_pages, t("No stale pages"))}
        </section>
      `;
    case "translation_validation":
      return `
        <section class="editor-section">
          <ul class="editor-list compact">
            <li><strong>${escapeHtml(t("Missing"))}:</strong> ${escapeHtml(String(payload.summary?.missing_count || 0))}</li>
            <li><strong>${escapeHtml(t("Orphan Files"))}:</strong> ${escapeHtml(String(payload.summary?.orphan_count || 0))}</li>
            <li><strong>${escapeHtml(t("Do Not Translate"))}:</strong> ${escapeHtml(String(payload.summary?.do_not_translate_count || 0))}</li>
          </ul>
        </section>
        <section class="editor-section">
          <h2>${escapeHtml(t("Missing Translations"))}</h2>
          ${renderKeyedEntries(payload.missing, ["post_id", "language"])}
        </section>
        <section class="editor-section">
          <h2>${escapeHtml(t("Orphan Files"))}</h2>
          ${renderStringList(payload.orphan_files, t("No orphan translation files"))}
        </section>
      `;
    case "find_duplicates":
      return `
        <section class="editor-section">
          <ul class="editor-list compact">
            <li><strong>${escapeHtml(t("Pairs"))}:</strong> ${escapeHtml(String(payload.summary?.pair_count || 0))}</li>
          </ul>
        </section>
        <section class="editor-section">
          <h2>${escapeHtml(t("Duplicate Candidates"))}</h2>
          ${renderKeyedEntries(payload.pairs, ["title_a", "title_b", "score"])}
        </section>
      `;
    default:
      return `
        <section class="editor-section">
          <pre>${escapeHtml(JSON.stringify(payload, null, 2))}</pre>
        </section>
      `;
  }
}

function renderStringList(items, emptyMessage) {
  if (!items || !items.length) {
    return `<p>${escapeHtml(emptyMessage)}</p>`;
  }

  return `<ul class="editor-list">${items.map((item) => `<li>${escapeHtml(String(item))}</li>`).join("")}</ul>`;
}

function renderKeyedEntries(items, keys) {
  if (!items || !items.length) {
    return `<p>${escapeHtml(t("No items"))}</p>`;
  }

  return `
    <div class="panel-entry-list">
      ${items
        .map((item) => `
          <div class="panel-entry">
            ${keys
              .filter((key) => item[key] !== undefined)
              .map((key) => `<span><strong>${escapeHtml(titleCase(key))}:</strong> ${escapeHtml(formatPayloadValue(item[key]))}</span>`)
              .join("")}
          </div>
        `)
        .join("")}
    </div>
  `;
}

function formatPayloadValue(value) {
  if (Array.isArray(value)) {
    return value.map((entry) => formatPayloadValue(entry)).join(", ");
  }

  if (value && typeof value === "object") {
    return JSON.stringify(value);
  }

  return String(value);
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

function normalizeTaskStatus(taskStatus) {
  return {
    active_count: taskStatus?.active_count || 0,
    running_count: taskStatus?.running_count || 0,
    pending_count: taskStatus?.pending_count || 0,
    running_task_message: taskStatus?.running_task_message || null,
    running_task_overflow: taskStatus?.running_task_overflow || 0,
    tasks: Array.isArray(taskStatus?.tasks) ? taskStatus.tasks : [],
  };
}

function normalizeProjects(projectsPayload) {
  return {
    active_project_id: projectsPayload?.active_project_id || null,
    projects: Array.isArray(projectsPayload?.projects) ? projectsPayload.projects : [],
  };
}

function panelTabs() {
  return ["tasks", "output", "git_log", state.session.panel.active_tab].filter(uniqueValue);
}

function renderPanelTab(tab) {
  if (tab === "tasks") {
    return `<button class="panel-tab ${state.session.panel.active_tab === "tasks" ? "active" : ""}" data-panel-tab="tasks" type="button">${escapeHtml(t("Tasks"))}</button>`;
  }

  if (tab === "output") {
    return `<button class="panel-tab ${state.session.panel.active_tab === "output" ? "active" : ""}" data-panel-tab="output" type="button">${escapeHtml(t("Output"))}</button>`;
  }

  if (tab === "git_log") {
    return `<button class="panel-tab ${state.session.panel.active_tab === "git_log" ? "active" : ""}" data-panel-tab="git_log" type="button">${escapeHtml(t("Git Log"))}</button>`;
  }

  return `<button class="panel-tab ${state.session.panel.active_tab === tab ? "active" : ""}" data-panel-tab="${tab}" type="button">${escapeHtml(routeLabel(tab))}</button>`;
}

function renderLanguageOptions() {
  return state.supportedUiLanguages
    .map((language) => {
      const selected = language.code === state.uiLanguage ? " selected" : "";
      return `<option value="${escapeHtmlAttribute(language.code)}"${selected}>${escapeHtml(language.flag || language.code.toUpperCase())}</option>`;
    })
    .join("");
}

function renderProjectSelector() {
  const activeProject = currentProject();

  return `
    <div class="project-selector${state.projectMenuOpen ? " is-open" : ""}">
      <button class="project-selector-trigger" data-project-menu-trigger type="button" title="${escapeHtmlAttribute(t("Switch project"))}">
        <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" class="project-icon">
          <path d="M14.5 3H7.71l-.85-.85A.5.5 0 0 0 6.5 2h-5a.5.5 0 0 0-.5.5v11a.5.5 0 0 0 .5.5h13a.5.5 0 0 0 .5-.5v-10a.5.5 0 0 0-.5-.5zm-13 1h5.29l.85.85c.1.1.23.15.36.15h6.5v9h-13V4z"></path>
        </svg>
        <span class="project-name">${escapeHtml(activeProject?.name || "My Blog")}</span>
        <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor" class="dropdown-arrow">
          <path d="M4.5 5.5L8 9l3.5-3.5h-7z"></path>
        </svg>
      </button>
      ${state.projectMenuOpen ? renderProjectDropdown() : ""}
    </div>
  `;
}

function renderProjectDropdown() {
  return `
    <div class="project-dropdown">
      <div class="project-dropdown-header">
        <span>${escapeHtml(t("Projects"))}</span>
      </div>
      <div class="project-list">
        ${state.projects.projects.map((project) => renderProjectItem(project)).join("")}
      </div>
      <div class="project-dropdown-footer">
        <button class="existing-project-btn" data-project-import type="button">
          <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor">
            <path d="M1.75 3A1.75 1.75 0 013.5 1.25h3.92c.46 0 .9.18 1.22.5l1.1 1.1c.09.1.22.15.35.15h2.41A1.75 1.75 0 0114.25 4.75v6.5A1.75 1.75 0 0112.5 13h-9A1.75 1.75 0 011.75 11.25v-8.5zm1.75-.25a.75.75 0 00-.75.75v8.5c0 .41.34.75.75.75h9c.41 0 .75-.34.75-.75v-6.5a.75.75 0 00-.75-.75h-2.41a1.7 1.7 0 01-1.06-.44l-1.1-1.1a.74.74 0 00-.52-.21H3.5z"></path>
          </svg>
          ${escapeHtml(t("Open Existing Blog"))}
        </button>
        <button class="create-project-btn" data-project-create type="button">
          <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor">
            <path d="M14 7v1H8v6H7V8H1V7h6V1h1v6h6z"></path>
          </svg>
          ${escapeHtml(t("New Project"))}
        </button>
      </div>
    </div>
  `;
}

function renderProjectItem(project) {
  const active = project.id === state.projects.active_project_id;

  return `
    <button class="project-item ${active ? "active" : ""}" data-project-id="${escapeHtmlAttribute(project.id)}" type="button">
      <span class="project-item-name">${escapeHtml(project.name)}</span>
      ${active ? `<span class="project-check-icon">✓</span>` : ""}
    </button>
  `;
}

function currentProject() {
  return state.projects.projects.find((project) => project.id === state.projects.active_project_id) || state.projects.projects[0] || null;
}

function toggleProjectMenu() {
  state.projectMenuOpen = !state.projectMenuOpen;
  render();
}

function closeProjectMenu() {
  if (!state.projectMenuOpen) {
    return;
  }

  state.projectMenuOpen = false;
  render();
}

function bindProjectMenuDismiss() {
  if (window.__BDS_PROJECT_MENU_DISMISS_BOUND__) {
    return;
  }

  window.__BDS_PROJECT_MENU_DISMISS_BOUND__ = true;
  document.addEventListener("mousedown", (event) => {
    if (!state.projectMenuOpen) {
      return;
    }

    const selector = root.querySelector(".project-selector");
    if (selector && !selector.contains(event.target)) {
      closeProjectMenu();
    }
  });
}

function setUiLanguage(nextLanguage) {
  state.uiLanguage = nextLanguage;
  state.status.right.ui_language = nextLanguage;
  localStorage.setItem("bds-ui-language", nextLanguage);
}

function readStoredUiLanguage(fallback) {
  const stored = localStorage.getItem("bds-ui-language");
  return stored || fallback || "en";
}

function statusLabel(status) {
  switch (status) {
    case "running":
      return t("Running");
    case "pending":
      return t("Queued");
    default:
      return tText(titleCase(status || "task"));
  }
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