export const ColourPicker = {
  mounted() {
    this._onClickAway = (e) => {
      if (!this.el.contains(e.target)) {
        this.el.querySelector(".colour-picker-popover")?.classList.add("hidden");
      }
    };
    document.addEventListener("mousedown", this._onClickAway);

    this._setupCustomInput();
  },

  updated() {
    this._setupCustomInput();
  },

  destroyed() {
    document.removeEventListener("mousedown", this._onClickAway);
  },

  _setupCustomInput() {
    const input = this.el.querySelector(".colour-picker-custom input");
    if (!input || input._cpBound) return;
    input._cpBound = true;

    const pushColor = () => {
      let val = input.value.trim();
      if (val && !val.startsWith("#")) val = "#" + val;
      if (/^#[0-9a-fA-F]{6}$/.test(val)) {
        const event = this.el.dataset.pickEvent;
        this.pushEventTo(this.el.dataset.target, event, { color: val });
        this.el.querySelector(".colour-picker-popover")?.classList.add("hidden");
      }
    };

    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        pushColor();
      }
    });

    input.addEventListener("blur", pushColor);
  }
};
