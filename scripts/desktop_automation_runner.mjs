import { chromium } from "playwright";
import readline from "node:readline";

const [url, screenshotDir] = process.argv.slice(2);

if (!url) {
  console.log(JSON.stringify({ status: "error", message: "missing automation url" }));
  process.exit(1);
}

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

try {
  await page.goto(url, { waitUntil: "networkidle" });
  await page.locator("#bds-shell-app").waitFor({ state: "visible" });
  await page.emulateMedia({ reducedMotion: "reduce" });
  console.log(JSON.stringify({ status: "ready", screenshotDir }));
} catch (error) {
  console.log(JSON.stringify({ status: "error", message: error.message }));
  await browser.close();
  process.exit(1);
}

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

for await (const line of rl) {
  if (!line.trim()) {
    continue;
  }

  const message = JSON.parse(line);
  const ref = message.ref;

  try {
    if (message.command === "snapshot") {
      const result = await page.evaluate(() => {
        const text = (selector) => document.querySelector(selector)?.textContent?.trim() ?? null;
        const texts = (selector, mapper) => Array.from(document.querySelectorAll(selector)).map(mapper);
        const hasClass = (selector, className) => document.querySelector(selector)?.classList.contains(className) ?? false;

        return {
          window_title: text("[data-testid='window-title']"),
          active_view: document.querySelector("[data-testid='activity-button'][data-active='true']")?.dataset.view ?? null,
          sidebar_visible: !hasClass("[data-testid='sidebar-shell']", "is-hidden"),
          sidebar_width: document.querySelector("[data-testid='sidebar-shell']")?.getBoundingClientRect().width ?? 0,
          assistant_visible: !hasClass("[data-testid='assistant-shell']", "is-hidden"),
          assistant_width: document.querySelector("[data-testid='assistant-shell']")?.getBoundingClientRect().width ?? 0,
          panel_visible: !hasClass(".panel-shell", "is-hidden"),
          editor_title: text("[data-testid='editor-title']"),
          activity_labels: texts("[data-testid='activity-button']", (node) => node.getAttribute("aria-label")),
          sidebar_sections: texts("[data-testid='sidebar-section-title']", (node) => node.textContent.trim()),
          editor_meta_labels: texts("[data-testid='editor-meta-label']", (node) => node.textContent.trim())
        };
      });

      console.log(JSON.stringify({ ref, status: "ok", result }));
      continue;
    }

    if (message.command === "click") {
      await page.locator(message.selector).click();
      await page.waitForTimeout(50);
      console.log(JSON.stringify({ ref, status: "ok", result: "ok" }));
      continue;
    }

    if (message.command === "press") {
      await page.keyboard.press(message.shortcut);
      await page.waitForTimeout(50);
      console.log(JSON.stringify({ ref, status: "ok", result: "ok" }));
      continue;
    }

    if (message.command === "drag") {
      const locator = page.locator(message.selector);
      const box = await locator.boundingBox();

      if (!box) {
        throw new Error(`unable to drag missing element: ${message.selector}`);
      }

      const startX = box.x + box.width / 2;
      const startY = box.y + box.height / 2;
      await page.mouse.move(startX, startY);
      await page.mouse.down();
      await page.mouse.move(startX + message.deltaX, startY, { steps: 10 });
      await page.mouse.up();
      await page.waitForTimeout(50);
      console.log(JSON.stringify({ ref, status: "ok", result: "ok" }));
      continue;
    }

    if (message.command === "reload") {
      await page.reload({ waitUntil: "networkidle" });
      await page.locator("#bds-shell-app").waitFor({ state: "visible" });
      await page.waitForTimeout(100);
      console.log(JSON.stringify({ ref, status: "ok", result: "ok" }));
      continue;
    }

    if (message.command === "screenshot") {
      await page.screenshot({ path: message.path, fullPage: false });
      console.log(JSON.stringify({ ref, status: "ok", result: message.path }));
      continue;
    }

    if (message.command === "close") {
      await browser.close();
      console.log(JSON.stringify({ ref, status: "ok", result: "closed" }));
      process.exit(0);
    }

    console.log(JSON.stringify({ ref, status: "error", message: `unknown command: ${message.command}` }));
  } catch (error) {
    console.log(JSON.stringify({ ref, status: "error", message: error.message }));
  }
}