// App-wide error reporter — catches JS errors and displays them as an overlay.
// Enables debugging in WKWebView where devtools are unavailable.
(function () {
  const overlay = document.createElement("div");
  overlay.id = "error-reporter";
  overlay.style.cssText =
    "position:fixed;bottom:0;left:0;right:0;max-height:200px;overflow:auto;background:#1a1a2e;color:#f0f0f0;font:12px monospace;padding:8px 12px;border-top:2px solid #e74c3c;z-index:99999;display:none;";
  overlay.innerHTML = '<strong style="color:#e74c3c">⚠ JS Errors</strong><pre id="error-reporter-log"></pre>';
  document.body.appendChild(overlay);

  const log = document.getElementById("error-reporter-log");

  const append = (msg) => {
    overlay.style.display = "block";
    log.textContent += msg + "\n";
    overlay.scrollTop = overlay.scrollHeight;
  };

  window.addEventListener("error", (e) => {
    const src = e.filename || "";
    const loc = e.lineno !== undefined ? `:${e.lineno}` : "";
    append(`[${new Date().toLocaleTimeString()}] ${e.message || e.error}\n  at ${src}${loc}`);
  });

  window.addEventListener("unhandledrejection", (e) => {
    append(`[${new Date().toLocaleTimeString()}] Unhandled rejection: ${e.reason}`);
  });

  // Also wrap console.error to catch Monaco errors
  const origError = console.error;
  console.error = (...args) => {
    origError.apply(console, args);
    append(`[${new Date().toLocaleTimeString()}] ${args.join(" ")}`);
  };
})();
