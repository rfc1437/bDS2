export const syncTitlebarOverlayInsets = () => {
  const rootStyle = document.documentElement.style;
  const setInsets = (left, right) => {
    rootStyle.setProperty("--bds-titlebar-overlay-left", `${left}px`);
    rootStyle.setProperty("--bds-titlebar-overlay-right", `${right}px`);
  };

  const overlay = navigator.windowControlsOverlay;

  if (!overlay) {
    setInsets(0, 0);
    return () => {};
  }

  const updateInsets = () => {
    if (!overlay.visible) {
      setInsets(0, 0);
      return;
    }

    const titlebarRect = overlay.getTitlebarAreaRect();
    const viewportWidth = window.innerWidth || document.documentElement.clientWidth || titlebarRect.right;
    const leftInset = Math.max(0, Math.round(titlebarRect.left));
    const rightInset = Math.max(0, Math.round(viewportWidth - titlebarRect.right));
    setInsets(leftInset, rightInset);
  };

  const onGeometryChange = () => updateInsets();
  const onResize = () => updateInsets();

  updateInsets();
  overlay.addEventListener("geometrychange", onGeometryChange);
  window.addEventListener("resize", onResize);

  return () => {
    overlay.removeEventListener("geometrychange", onGeometryChange);
    window.removeEventListener("resize", onResize);
  };
};
