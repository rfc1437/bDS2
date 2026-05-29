/*
 * Self-contained client-side search UI for generated blog output.
 *
 * Exposes a global `PagefindUI` constructor that the bundled
 * `search-runtime.js` instantiates. It fetches the per-language fragment
 * index (`index.json`) co-located with this script, performs full-text
 * matching over the indexed post fragments, and renders ranked results.
 *
 * No external/CDN dependencies — everything needed ships in this file.
 */
(function () {
  "use strict";

  // Resolve the sibling index.json relative to this script's own URL so the
  // same bundle works for every language directory (e.g. /pagefind/,
  // /de/pagefind/) without baking the path in at generation time.
  var scriptSrc = (document.currentScript && document.currentScript.src) || "";

  function resolveIndexUrl(src) {
    try {
      return new URL("index.json", src).href;
    } catch (err) {
      return "index.json";
    }
  }

  function tokenize(value) {
    return (value || "")
      .toLowerCase()
      .split(/[^\p{L}\p{N}]+/u)
      .filter(function (token) {
        return token.length > 0;
      });
  }

  function PagefindUI(options) {
    options = options || {};
    this.element =
      typeof options.element === "string"
        ? document.querySelector(options.element)
        : options.element;

    if (!this.element) {
      return;
    }

    var translations = options.translations || {};
    this.placeholder = translations.placeholder || "Search";
    this.zeroResults = translations.zero_results || "No results found";
    this.indexUrl = options.indexUrl || resolveIndexUrl(scriptSrc);
    this.pages = null;
    this.loadPromise = null;

    this.render();
  }

  PagefindUI.prototype.render = function () {
    var self = this;
    this.element.classList.add("pagefind-ui");
    this.element.innerHTML = "";

    var form = document.createElement("form");
    form.className = "pagefind-ui__form";
    form.setAttribute("role", "search");
    form.addEventListener("submit", function (event) {
      event.preventDefault();
    });

    var input = document.createElement("input");
    input.type = "search";
    input.className = "pagefind-ui__search-input";
    input.setAttribute("autocomplete", "off");
    input.placeholder = this.placeholder;
    input.setAttribute("aria-label", this.placeholder);

    var results = document.createElement("div");
    results.className = "pagefind-ui__results";

    form.appendChild(input);
    this.element.appendChild(form);
    this.element.appendChild(results);

    this.input = input;
    this.results = results;

    var debounce = null;
    input.addEventListener("input", function () {
      window.clearTimeout(debounce);
      debounce = window.setTimeout(function () {
        self.search(input.value);
      }, 120);
    });
  };

  PagefindUI.prototype.load = function () {
    if (this.pages) {
      return Promise.resolve(this.pages);
    }
    if (this.loadPromise) {
      return this.loadPromise;
    }

    var self = this;
    this.loadPromise = fetch(this.indexUrl, { credentials: "same-origin" })
      .then(function (response) {
        if (!response.ok) {
          throw new Error("pagefind index request failed: " + response.status);
        }
        return response.json();
      })
      .then(function (data) {
        self.pages = (data && data.pages) || [];
        return self.pages;
      })
      .catch(function () {
        self.pages = [];
        return self.pages;
      });

    return this.loadPromise;
  };

  PagefindUI.prototype.search = function (query) {
    var self = this;
    var terms = tokenize(query);

    if (terms.length === 0) {
      this.results.innerHTML = "";
      return;
    }

    this.load().then(function (pages) {
      var matches = [];

      for (var i = 0; i < pages.length; i++) {
        var page = pages[i];
        var title = (page.title || "").toLowerCase();
        var body = (page.text || "").toLowerCase();
        var score = 0;
        var matchedAll = true;

        for (var t = 0; t < terms.length; t++) {
          var term = terms[t];
          var bodyHits = body.split(term).length - 1;
          var titleHits = title.split(term).length - 1;

          if (bodyHits === 0 && titleHits === 0) {
            matchedAll = false;
            break;
          }

          // Title matches are weighted more heavily than body matches.
          score += bodyHits + titleHits * 5;
        }

        if (matchedAll) {
          matches.push({ page: page, score: score });
        }
      }

      matches.sort(function (a, b) {
        return b.score - a.score;
      });

      self.renderResults(matches.slice(0, 10), terms);
    });
  };

  PagefindUI.prototype.renderResults = function (matches, terms) {
    this.results.innerHTML = "";

    if (matches.length === 0) {
      var message = document.createElement("p");
      message.className = "pagefind-ui__message";
      message.textContent = this.zeroResults;
      this.results.appendChild(message);
      return;
    }

    var list = document.createElement("ol");
    list.className = "pagefind-ui__result-list";

    for (var i = 0; i < matches.length; i++) {
      var page = matches[i].page;

      var item = document.createElement("li");
      item.className = "pagefind-ui__result";

      var link = document.createElement("a");
      link.className = "pagefind-ui__result-link";
      link.href = page.url;
      link.textContent = page.title || page.url;

      var excerpt = document.createElement("p");
      excerpt.className = "pagefind-ui__result-excerpt";
      buildExcerpt(excerpt, page.text || "", terms);

      item.appendChild(link);
      item.appendChild(excerpt);
      list.appendChild(item);
    }

    this.results.appendChild(list);
  };

  // Build an excerpt around the first matching term and highlight all terms
  // with <mark>, using safe text nodes (never innerHTML on untrusted text).
  function buildExcerpt(target, text, terms) {
    var lower = text.toLowerCase();
    var firstHit = -1;

    for (var t = 0; t < terms.length; t++) {
      var idx = lower.indexOf(terms[t]);
      if (idx !== -1 && (firstHit === -1 || idx < firstHit)) {
        firstHit = idx;
      }
    }

    var start = firstHit === -1 ? 0 : Math.max(0, firstHit - 60);
    var snippet = text.slice(start, start + 220);
    if (start > 0) {
      snippet = "…" + snippet;
    }
    if (start + 220 < text.length) {
      snippet = snippet + "…";
    }

    highlightInto(target, snippet, terms);
  }

  function highlightInto(target, snippet, terms) {
    var escaped = terms
      .map(function (term) {
        return term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      })
      .filter(function (term) {
        return term.length > 0;
      });

    if (escaped.length === 0) {
      target.appendChild(document.createTextNode(snippet));
      return;
    }

    var pattern = new RegExp("(" + escaped.join("|") + ")", "giu");
    var lastIndex = 0;
    var match;

    while ((match = pattern.exec(snippet)) !== null) {
      if (match.index > lastIndex) {
        target.appendChild(
          document.createTextNode(snippet.slice(lastIndex, match.index))
        );
      }
      var mark = document.createElement("mark");
      mark.textContent = match[0];
      target.appendChild(mark);
      lastIndex = match.index + match[0].length;

      // Guard against zero-length matches looping forever.
      if (match.index === pattern.lastIndex) {
        pattern.lastIndex++;
      }
    }

    if (lastIndex < snippet.length) {
      target.appendChild(document.createTextNode(snippet.slice(lastIndex)));
    }
  }

  window.PagefindUI = PagefindUI;
})();
