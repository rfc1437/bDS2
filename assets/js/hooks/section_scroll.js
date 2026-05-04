const makeSectionScrollHook = (datasetKey) => ({
  mounted() {
    this.lastTargetId = null;
    this.scrollToSelectedSection();
  },

  updated() {
    this.scrollToSelectedSection();
  },

  scrollToSelectedSection() {
    const targetId = this.el.dataset[datasetKey];

    if (!targetId || targetId === this.lastTargetId) {
      return;
    }

    this.lastTargetId = targetId;

    window.requestAnimationFrame(() => {
      const target = document.getElementById(targetId);

      if (target && this.el.contains(target)) {
        target.scrollIntoView({ block: "start", behavior: "smooth" });
      }
    });
  }
});

export const SettingsSectionScroll = makeSectionScrollHook("settingsScrollTarget");
export const TagsSectionScroll = makeSectionScrollHook("tagsScrollTarget");
