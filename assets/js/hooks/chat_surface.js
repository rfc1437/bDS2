export const ChatSurface = {
  mounted() {
    this.stickToBottom = true;
    this.scrollContainer = null;

    this.autoResize = () => {
      const textarea = this.el.querySelector(".chat-input");

      if (!textarea) {
        return;
      }

      const styles = getComputedStyle(textarea);
      const minHeight = parseFloat(styles.getPropertyValue("--chat-input-min-height")) || 20;
      const maxHeight = parseFloat(styles.getPropertyValue("--chat-input-max-height")) || 160;

      textarea.rows = 1;
      textarea.style.minHeight = `${minHeight}px`;

      if (textarea.value.trim() === "") {
        textarea.style.height = `${minHeight}px`;
        textarea.style.maxHeight = `${minHeight}px`;
        textarea.style.overflowY = "hidden";
        return;
      }

      textarea.style.maxHeight = `${maxHeight}px`;
      textarea.style.height = "0px";
      const nextHeight = Math.min(Math.max(textarea.scrollHeight, minHeight), maxHeight);
      textarea.style.height = `${nextHeight}px`;
      textarea.style.overflowY = nextHeight >= maxHeight ? "auto" : "hidden";
    };

    this.syncScrollContainer = () => {
      const nextContainer = this.el.querySelector(".chat-messages");

      if (nextContainer === this.scrollContainer) {
        return;
      }

      if (this.scrollContainer) {
        this.scrollContainer.removeEventListener("scroll", this.handleScroll);
      }

      this.scrollContainer = nextContainer;

      if (this.scrollContainer) {
        this.scrollContainer.addEventListener("scroll", this.handleScroll);
      }
    };

    this.scrollToBottom = (force = false) => {
      if (!this.scrollContainer) {
        return;
      }

      if (force || this.stickToBottom) {
        this.scrollContainer.scrollTop = this.scrollContainer.scrollHeight;
      }
    };

    this.syncExpandedSurfaces = () => {
      this.el
        .querySelectorAll(".chat-inline-surface[data-expanded='true']")
        .forEach((surface) => {
          surface.open = true;
        });
    };

    this.surfaceObserver = new MutationObserver(() => {
      this.syncExpandedSurfaces();
    });

    this.handleScroll = () => {
      if (!this.scrollContainer) {
        this.stickToBottom = true;
        return;
      }

      const distanceFromBottom =
        this.scrollContainer.scrollHeight -
        this.scrollContainer.scrollTop -
        this.scrollContainer.clientHeight;

      this.stickToBottom = distanceFromBottom < 48;
    };

    this.handleInput = (event) => {
      if (!event.target.closest(".chat-input")) {
        return;
      }

      this.stickToBottom = true;
      this.autoResize();
    };

    this.handleKeyDown = (event) => {
      if (!event.target.closest(".chat-input")) {
        return;
      }

      if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
        event.preventDefault();

        const sendButton = this.el.querySelector("[data-testid='chat-send-button']");

        if (sendButton && !sendButton.disabled) {
          sendButton.click();
        }
      }
    };

    this.el.addEventListener("input", this.handleInput);
    this.el.addEventListener("keydown", this.handleKeyDown);

    this.syncScrollContainer();
    this.syncExpandedSurfaces();
    this.surfaceObserver.observe(this.el, { childList: true, subtree: true });
    this.autoResize();
    window.requestAnimationFrame(() => this.scrollToBottom(true));
  },

  updated() {
    this.syncScrollContainer();
    this.syncExpandedSurfaces();
    this.autoResize();
    window.requestAnimationFrame(() => this.scrollToBottom());
  },

  destroyed() {
    this.surfaceObserver.disconnect();
    this.el.removeEventListener("input", this.handleInput);
    this.el.removeEventListener("keydown", this.handleKeyDown);

    if (this.scrollContainer) {
      this.scrollContainer.removeEventListener("scroll", this.handleScroll);
    }
  }
};
