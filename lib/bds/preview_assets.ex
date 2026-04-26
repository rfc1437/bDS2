defmodule BDS.PreviewAssets do
  @moduledoc false

  @theme_tokens %{
    "amber" => %{light_primary: "#876400", dark_primary: "#c79400"},
    "blue" => %{light_primary: "#2060df", dark_primary: "#8999f9"},
    "cyan" => %{light_primary: "#047878", dark_primary: "#0ab1b1"},
    "fuchsia" => %{light_primary: "#c1208b", dark_primary: "#f869bf"},
    "green" => %{light_primary: "#33790f", dark_primary: "#4eb31b"},
    "grey" => %{light_primary: "#6a6a6a", dark_primary: "#9e9e9e"},
    "indigo" => %{light_primary: "#655cd6", dark_primary: "#a294e5"},
    "jade" => %{light_primary: "#007a50", dark_primary: "#00b478"},
    "lime" => %{light_primary: "#577400", dark_primary: "#82ab00"},
    "orange" => %{light_primary: "#bd3c13", dark_primary: "#f56b3d"},
    "pink" => %{light_primary: "#c72259", dark_primary: "#f7708e"},
    "pumpkin" => %{light_primary: "#9c5900", dark_primary: "#e48500"},
    "purple" => %{light_primary: "#aa40bf", dark_primary: "#d47de4"},
    "red" => %{light_primary: "#c52f21", dark_primary: "#f17961"},
    "sand" => %{light_primary: "#6e6a60", dark_primary: "#a39e8f"},
    "slate" => %{light_primary: "#5d6b89", dark_primary: "#909ebe"},
    "violet" => %{light_primary: "#8352c5", dark_primary: "#b290d9"},
    "yellow" => %{light_primary: "#756b00", dark_primary: "#ad9f00"},
    "zinc" => %{light_primary: "#646b79", dark_primary: "#969eaf"}
  }

  @highlight_stylesheet """
  .hljs { color: #e6edf3; background: transparent; display: block; overflow-x: auto; }
  .hljs-keyword, .hljs-selector-tag, .hljs-literal { color: #ff7b72; }
  .hljs-string, .hljs-attr { color: #a5d6ff; }
  .hljs-number, .hljs-title, .hljs-section { color: #f2cc60; }
  .hljs-comment, .hljs-quote { color: #8b949e; }
  .hljs-built_in, .hljs-type, .hljs-symbol { color: #7ee787; }
  """

  @highlight_script "window.hljs = window.hljs || { highlightElement: function () {} };"

  @lightbox_script "window.lightbox = window.lightbox || { option: function () {}, init: function () {} };"

  @calendar_stylesheet """
  [data-blog-calendar-root] { min-height: 12rem; }
  [data-blog-calendar-root] button { font: inherit; }
  """

  @calendar_script """
  (function () {
    function Calendar() {}
    Calendar.prototype.init = function () {};
    window.VanillaCalendar = window.VanillaCalendar || Calendar;
    window.VanillaCalendarPro = window.VanillaCalendarPro || Calendar;
  })();
  """

  @calendar_runtime """
  (function () {
    function toggle(panel, hidden) {
      if (!panel) {
        return;
      }

      if (hidden) {
        panel.setAttribute('hidden', 'hidden');
      } else {
        panel.removeAttribute('hidden');
      }
    }

    function init() {
      var toggleButton = document.querySelector('[data-blog-calendar-toggle]');
      var closeButton = document.querySelector('[data-blog-calendar-close]');
      var panel = document.querySelector('[data-blog-calendar-panel]');
      var status = document.querySelector('[data-blog-calendar-status]');

      if (!toggleButton || !panel) {
        return;
      }

      toggleButton.addEventListener('click', function () {
        var isHidden = panel.hasAttribute('hidden');
        toggle(panel, !isHidden);
        if (status && !status.dataset.previewReady) {
          status.textContent = 'Preview calendar is unavailable in draft mode.';
          status.dataset.previewReady = 'true';
        }
      });

      if (closeButton) {
        closeButton.addEventListener('click', function () {
          toggle(panel, true);
        });
      }
    }

    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', init, { once: true });
    } else {
      init();
    }
  })();
  """

  @search_runtime """
  (function () {
    function setHidden(panel, hidden) {
      if (!panel) {
        return;
      }

      if (hidden) {
        panel.setAttribute('hidden', 'hidden');
      } else {
        panel.removeAttribute('hidden');
      }
    }

    function init() {
      var toggle = document.querySelector('[data-blog-search-toggle]');
      var panel = document.querySelector('[data-blog-search-panel]');
      if (!toggle || !panel) {
        return;
      }

      toggle.addEventListener('click', function () {
        setHidden(panel, !panel.hasAttribute('hidden'));
      });

      document.addEventListener('click', function (event) {
        if (panel.hasAttribute('hidden')) {
          return;
        }

        if (panel.contains(event.target) || toggle.contains(event.target)) {
          return;
        }

        setHidden(panel, true);
      });
    }

    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', init, { once: true });
    } else {
      init();
    }
  })();
  """

  @tag_cloud_runtime """
  (function () {
    function init() {}
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', init, { once: true });
    } else {
      init();
    }
  })();
  """

  @d3_cloud_script """
  (function () {
    var layout = {
      size: function () { return layout; },
      words: function () { return layout; },
      padding: function () { return layout; },
      rotate: function () { return layout; },
      font: function () { return layout; },
      fontSize: function () { return layout; },
      on: function () { return layout; },
      start: function () { return layout; }
    };

    window.d3 = window.d3 || {};
    window.d3.layout = window.d3.layout || {};
    window.d3.layout.cloud = function () { return layout; };
  })();
  """

  def response(pathname) when is_binary(pathname) do
    case Regex.run(~r{^/assets/([^/]+)$}, pathname) do
      [_, asset_name] -> build_asset_response(asset_name)
      _other -> :error
    end
  end

  defp build_asset_response(asset_name) do
    case asset_payload(asset_name) do
      {:ok, content_type, body} -> {:ok, %{content_type: content_type, body: body}}
      :error -> :error
    end
  end

  defp asset_payload(asset_name) do
    case Regex.run(~r/^pico(?:\.([a-z]+))?\.min\.css$/, asset_name) do
      [_, theme] -> {:ok, "text/css", pico_stylesheet(theme)}
      [single] when single == asset_name -> {:ok, "text/css", pico_stylesheet(nil)}
      _other -> named_asset_payload(asset_name)
    end
  end

  defp named_asset_payload("bds.css"), do: file_asset("bds.css", "text/css")
  defp named_asset_payload("code-enhancements.js"), do: file_asset("code-enhancements.js", "application/javascript")
  defp named_asset_payload("highlight.min.css"), do: {:ok, "text/css", @highlight_stylesheet}
  defp named_asset_payload("highlight.min.js"), do: {:ok, "application/javascript", @highlight_script}
  defp named_asset_payload("lightbox.min.css"), do: {:ok, "text/css", ""}
  defp named_asset_payload("lightbox.min.js"), do: {:ok, "application/javascript", @lightbox_script}
  defp named_asset_payload("vanilla-calendar.min.css"), do: {:ok, "text/css", @calendar_stylesheet}
  defp named_asset_payload("vanilla-calendar.min.js"), do: {:ok, "application/javascript", @calendar_script}
  defp named_asset_payload("calendar-runtime.js"), do: {:ok, "application/javascript", @calendar_runtime}
  defp named_asset_payload("search-runtime.js"), do: {:ok, "application/javascript", @search_runtime}
  defp named_asset_payload("tag-cloud.js"), do: {:ok, "application/javascript", @tag_cloud_runtime}
  defp named_asset_payload("d3.layout.cloud.js"), do: {:ok, "application/javascript", @d3_cloud_script}
  defp named_asset_payload(_asset_name), do: :error

  defp file_asset(filename, content_type) do
    case File.read(asset_path(filename)) do
      {:ok, body} -> {:ok, content_type, body}
      {:error, _reason} -> :error
    end
  end

  defp asset_path(filename) do
    Application.app_dir(:bds, "priv/preview_assets/#{filename}")
  end

  defp pico_stylesheet(theme) do
    tokens = Map.get(@theme_tokens, theme || "", %{light_primary: "#2060df", dark_primary: "#8999f9"})

    """
    :root {
      color-scheme: light dark;
      --pico-font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif;
      --pico-line-height: 1.6;
      --pico-border-radius: 0.35rem;
      --pico-background-color: #ffffff;
      --pico-color: #1f2937;
      --pico-muted-color: #5d6b89;
      --pico-muted-border-color: #d6dde8;
      --pico-card-background-color: #f7f9fc;
      --pico-primary: #{tokens.light_primary};
      --pico-primary-hover: #{tokens.light_primary};
      --pico-primary-focus: rgba(32, 96, 223, 0.16);
      --pico-primary-inverse: #ffffff;
      --pico-code-background-color: #1f2937;
      --pico-code-color: #e6edf3;
      --pico-ins-color: #2f7a38;
      --pico-del-color: #b74848;
      --pico-form-element-background-color: #ffffff;
      --pico-form-element-border-color: #c7d0dd;
      --pico-form-element-color: #1f2937;
    }

    :root[data-mode='light'] {
      color-scheme: light;
    }

    :root[data-mode='dark'] {
      color-scheme: dark;
      --pico-background-color: #13171f;
      --pico-color: #e6edf3;
      --pico-muted-color: #909ebe;
      --pico-muted-border-color: #2d3645;
      --pico-card-background-color: #1b2230;
      --pico-primary: #{tokens.dark_primary};
      --pico-primary-hover: #{tokens.dark_primary};
      --pico-primary-focus: rgba(137, 153, 249, 0.18);
      --pico-code-background-color: #0f1520;
      --pico-form-element-background-color: #13171f;
      --pico-form-element-border-color: #364153;
      --pico-form-element-color: #e6edf3;
    }

    @media only screen and (prefers-color-scheme: dark) {
      :root:not([data-mode='light']) {
        color-scheme: dark;
        --pico-background-color: #13171f;
        --pico-color: #e6edf3;
        --pico-muted-color: #909ebe;
        --pico-muted-border-color: #2d3645;
        --pico-card-background-color: #1b2230;
        --pico-primary: #{tokens.dark_primary};
        --pico-primary-hover: #{tokens.dark_primary};
        --pico-primary-focus: rgba(137, 153, 249, 0.18);
        --pico-code-background-color: #0f1520;
        --pico-form-element-background-color: #13171f;
        --pico-form-element-border-color: #364153;
        --pico-form-element-color: #e6edf3;
      }
    }

    * { box-sizing: border-box; }
    html { font-family: var(--pico-font-family); background: var(--pico-background-color); color: var(--pico-color); }
    body { margin: 0; font-family: inherit; background: var(--pico-background-color); color: var(--pico-color); line-height: var(--pico-line-height); }
    h1, h2, h3, h4, h5, h6 { color: inherit; line-height: 1.2; margin: 0 0 0.75rem; }
    p, ul, ol, pre, table, blockquote { margin: 0 0 1rem; }
    a { color: var(--pico-primary); }
    a:hover, a:focus-visible { color: var(--pico-primary-hover); }
    button, [role='button'], input, textarea, select {
      font: inherit;
    }
    button, [role='button'] {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 0.35rem;
      border: 1px solid var(--pico-form-element-border-color);
      border-radius: var(--pico-border-radius);
      background: var(--pico-card-background-color);
      color: var(--pico-color);
      padding: 0.45rem 0.8rem;
      cursor: pointer;
      text-decoration: none;
    }
    input, textarea, select {
      width: 100%;
      border: 1px solid var(--pico-form-element-border-color);
      border-radius: var(--pico-border-radius);
      padding: 0.55rem 0.7rem;
      background: var(--pico-form-element-background-color);
      color: var(--pico-form-element-color);
    }
    code, pre, kbd {
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    }
    img { max-width: 100%; height: auto; }
    hr { border: 0; border-top: 1px solid var(--pico-muted-border-color); }
    table { width: 100%; border-collapse: collapse; }
    th, td { padding: 0.45rem 0.6rem; border-bottom: 1px solid var(--pico-muted-border-color); text-align: left; }
    blockquote {
      margin-left: 0;
      padding-left: 1rem;
      border-left: 4px solid var(--pico-muted-border-color);
      color: var(--pico-muted-color);
    }
    """
  end
end
