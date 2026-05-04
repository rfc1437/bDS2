let liquidLanguageRegistered = false;
let markdownWithMacrosRegistered = false;

export const registerLiquidLanguage = (monaco) => {
  if (liquidLanguageRegistered) {
    return;
  }

  monaco.languages.register({ id: "liquid" });
  monaco.languages.setLanguageConfiguration("liquid", {
    comments: {
      blockComment: ["{% comment %}", "{% endcomment %}"]
    },
    brackets: [
      ["{", "}"],
      ["[", "]"],
      ["(", ")"]
    ],
    autoClosingPairs: [
      { open: "{", close: "}" },
      { open: "[", close: "]" },
      { open: "(", close: ")" },
      { open: '"', close: '"' },
      { open: "'", close: "'" }
    ],
    surroundingPairs: [
      { open: "{", close: "}" },
      { open: "[", close: "]" },
      { open: "(", close: ")" },
      { open: '"', close: '"' },
      { open: "'", close: "'" }
    ]
  });

  monaco.languages.setMonarchTokensProvider("liquid", {
    defaultToken: "",
    tokenizer: {
      root: [
        [/\{\{-?/, { token: "delimiter.output", next: "@liquidOutput" }],
        [/\{%-?\s*comment\b[^%]*-?%\}/, { token: "comment.block", next: "@liquidComment" }],
        [/\{%-?/, { token: "delimiter.tag", next: "@liquidTag" }],
        [/<!DOCTYPE/i, "metatag"],
        [/<!--/, { token: "comment", next: "@htmlComment" }],
        [/(<)(script)/i, ["delimiter.html", "tag.html"], "@scriptTag"],
        [/(<)(style)/i, ["delimiter.html", "tag.html"], "@styleTag"],
        [/(<\/)([\w:-]+)/, ["delimiter.html", "tag.html"]],
        [/(<)([\w:-]+)/, ["delimiter.html", "tag.html"], "@htmlTag"],
        [/[^<{]+/, ""],
        [/./, ""]
      ],
      liquidOutput: [
        [/-?\}\}/, { token: "delimiter.output", next: "@pop" }],
        [/\|\s*[a-zA-Z_][\w-]*/, "keyword"],
        [/\b(?:true|false|nil|blank|empty)\b/, "keyword"],
        [/\b\d+(?:\.\d+)?\b/, "number"],
        [/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, "string"],
        [/[a-zA-Z_][\w.-]*/, "identifier"],
        [/[,:()[\]]/, "delimiter"]
      ],
      liquidTag: [
        [/-?%\}/, { token: "delimiter.tag", next: "@pop" }],
        [/\b(?:assign|capture|case|comment|cycle|decrement|echo|elsif|else|endcase|endcapture|endif|endfor|endunless|endcomment|for|if|include|increment|liquid|paginate|raw|render|tablerow|unless|when)\b/, "keyword"],
        [/\|\s*[a-zA-Z_][\w-]*/, "keyword"],
        [/\b(?:true|false|nil|blank|empty|contains)\b/, "keyword"],
        [/\b\d+(?:\.\d+)?\b/, "number"],
        [/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, "string"],
        [/[><=!]=?|\.|:/, "operator"],
        [/[a-zA-Z_][\w.-]*/, "identifier"],
        [/[,:()[\]]/, "delimiter"]
      ],
      liquidComment: [
        [/\{%-?\s*endcomment\s*-?%\}/, { token: "comment.block", next: "@pop" }],
        [/./, "comment.block"]
      ],
      htmlComment: [
        [/-->/, { token: "comment", next: "@pop" }],
        [/./, "comment"]
      ],
      htmlTag: [
        [/\/>/, { token: "delimiter.html", next: "@pop" }],
        [/>/, { token: "delimiter.html", next: "@pop" }],
        [/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, "attribute.value"],
        [/[\w:-]+/, "attribute.name"],
        [/=/, "delimiter"]
      ],
      scriptTag: [
        [/>/, { token: "delimiter.html", next: "@pop" }],
        [/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, "attribute.value"],
        [/[\w:-]+/, "attribute.name"],
        [/=/, "delimiter"]
      ],
      styleTag: [
        [/>/, { token: "delimiter.html", next: "@pop" }],
        [/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, "attribute.value"],
        [/[\w:-]+/, "attribute.name"],
        [/=/, "delimiter"]
      ]
    }
  });

  liquidLanguageRegistered = true;
};

export const registerMarkdownWithMacrosLanguage = (monaco) => {
  if (markdownWithMacrosRegistered) {
    return;
  }

  monaco.languages.register({ id: "markdown-with-macros" });
  monaco.languages.setMonarchTokensProvider("markdown-with-macros", {
    defaultToken: "",
    tokenPostfix: ".md",
    tokenizer: {
      root: [
        [/\[\[[a-zA-Z][\w-]*/, { token: "keyword.macro", next: "@macroParams" }],
        [/^#{1,6}\s.*$/, "keyword.header"],
        [/^\s*>+/, "string.quote"],
        [/^\s*[-+*]\s/, "keyword"],
        [/^\s*\d+\.\s/, "keyword"],
        [/^\s*```\w*/, { token: "string.code", next: "@codeblock" }],
        [/\*\*[^*]+\*\*/, "strong"],
        [/\*[^*]+\*/, "emphasis"],
        [/__[^_]+__/, "strong"],
        [/_[^_]+_/, "emphasis"],
        [/`[^`]+`/, "variable"],
        [/!?\[[^\]]*\]\([^)]*\)/, "string.link"],
        [/!?\[[^\]]*\]\[[^\]]*\]/, "string.link"]
      ],
      macroParams: [
        [/\]\]/, { token: "keyword.macro", next: "@root" }],
        [/[a-zA-Z][\w-]*(?=\s*=)/, "attribute.name"],
        [/=/, "delimiter"],
        [/"[^"]*"/, "string"],
        [/\s+/, "white"],
        [/[^\]"=\s]+/, "attribute.value"]
      ],
      codeblock: [
        [/^\s*```\s*$/, { token: "string.code", next: "@root" }],
        [/.*$/, "variable.source"]
      ]
    }
  });

  markdownWithMacrosRegistered = true;
};
