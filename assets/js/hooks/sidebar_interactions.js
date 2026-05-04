export const SidebarInteractions = {
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
};
