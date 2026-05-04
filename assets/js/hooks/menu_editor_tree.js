export const MenuEditorTree = {
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
};
