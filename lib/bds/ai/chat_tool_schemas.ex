defmodule BDS.AI.ChatToolSchemas do
  @moduledoc false

  def tool_spec(name, description, parameters) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => description,
        "parameters" => parameters
      }
    }
  end

  def limit_schema do
    %{
      "type" => "object",
      "properties" => %{
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
      }
    }
  end

  def post_search_schema(require_query) do
    schema = %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string"},
        "status" => %{"type" => "string", "enum" => ["draft", "published", "archived"]},
        "category" => %{"type" => "string"},
        "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
        "language" => %{"type" => "string"},
        "missingTranslationLanguage" => %{"type" => "string"},
        "year" => %{"type" => "integer"},
        "month" => %{"type" => "integer", "minimum" => 1, "maximum" => 12},
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50},
        "offset" => %{"type" => "integer", "minimum" => 0}
      }
    }

    if require_query, do: Map.put(schema, "required", ["query"]), else: schema
  end

  def count_posts_schema do
    %{
      "type" => "object",
      "properties" => %{
        "groupBy" => %{
          "type" => "array",
          "items" => %{
            "type" => "string",
            "enum" => ["year", "month", "tag", "category", "status"]
          }
        },
        "year" => %{"type" => "integer"},
        "month" => %{"type" => "integer", "minimum" => 1, "maximum" => 12},
        "status" => %{"type" => "string", "enum" => ["draft", "published", "archived"]},
        "category" => %{"type" => "string"},
        "tags" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["groupBy"]
    }
  end

  def post_id_schema do
    %{
      "type" => "object",
      "properties" => %{"postId" => %{"type" => "string"}},
      "required" => ["postId"]
    }
  end

  def media_id_schema(extra_properties \\ %{}) do
    %{
      "type" => "object",
      "properties" => Map.merge(%{"mediaId" => %{"type" => "string"}}, extra_properties),
      "required" => ["mediaId"]
    }
  end

  def update_post_metadata_schema do
    %{
      "type" => "object",
      "properties" => %{
        "postId" => %{"type" => "string"},
        "title" => %{"type" => "string"},
        "excerpt" => %{"type" => "string"},
        "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
        "categories" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["postId"]
    }
  end

  def update_media_metadata_schema do
    %{
      "type" => "object",
      "properties" => %{
        "mediaId" => %{"type" => "string"},
        "title" => %{"type" => "string"},
        "alt" => %{"type" => "string"},
        "caption" => %{"type" => "string"},
        "tags" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["mediaId"]
    }
  end

  def render_table_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string", "description" => "Optional table title"},
        "columns" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Column header names"
        },
        "rows" => %{
          "type" => "array",
          "items" => %{"type" => "array", "items" => %{"type" => "string"}},
          "description" => "Table rows, each row is an array of cell values"
        }
      }
    }
  end

  def render_chart_schema do
    %{
      "type" => "object",
      "properties" => %{
        "chartType" => %{
          "type" => "string",
          "enum" => ["bar", "stacked-bar", "line", "area", "pie", "donut", "heatmap"],
          "description" =>
            "The type of chart to render. Use stacked-bar for multi-segment bars. Use heatmap for grid/matrix visualizations."
        },
        "title" => %{"type" => "string", "description" => "Optional chart title"},
        "series" => %{
          "type" => "array",
          "description" => "Array of data points.",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "label" => %{"type" => "string", "description" => "Data point label"},
              "value" => %{"type" => "number", "description" => "Data point value"},
              "segments" => %{
                "type" => "array",
                "description" =>
                  "Segments within this data point. Required for stacked-bar and heatmap charts.",
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "label" => %{"type" => "string"},
                    "value" => %{"type" => "number"}
                  },
                  "required" => ["label", "value"]
                }
              }
            },
            "required" => ["label"]
          }
        }
      },
      "required" => ["chartType", "series"]
    }
  end

  def render_form_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string", "description" => "Optional form title"},
        "fields" => %{
          "type" => "array",
          "description" => "Form fields to display",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "key" => %{"type" => "string", "description" => "Field identifier"},
              "label" => %{"type" => "string", "description" => "Field label shown to user"},
              "inputType" => %{
                "type" => "string",
                "enum" => ["text", "textarea", "select", "checkbox", "date", "number"],
                "description" => "Type of input control"
              },
              "placeholder" => %{"type" => "string", "description" => "Placeholder text"},
              "defaultValue" => %{"type" => "string", "description" => "Default value"},
              "options" => %{
                "type" => "array",
                "description" => "Options for select fields",
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "label" => %{"type" => "string"},
                    "value" => %{"type" => "string"}
                  }
                }
              },
              "required" => %{"type" => "boolean", "description" => "Whether the field is required"}
            },
            "required" => ["key", "label", "inputType"]
          }
        },
        "submitLabel" => %{"type" => "string", "description" => "Label for the submit button"},
        "submitAction" => %{"type" => "string", "description" => "Action to dispatch on submit"}
      }
    }
  end

  def render_card_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string", "description" => "Card title"},
        "subtitle" => %{"type" => "string", "description" => "Optional subtitle"},
        "body" => %{"type" => "string", "description" => "Card body text (supports markdown)"},
        "actions" => %{
          "type" => "array",
          "description" => "Optional action buttons on the card",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "label" => %{"type" => "string", "description" => "Button label"},
              "action" => %{"type" => "string", "description" => "Action name to dispatch"},
              "payload" => %{
                "type" => "object",
                "description" => "Optional action payload"
              }
            },
            "required" => ["label", "action"]
          }
        }
      }
    }
  end

  def render_metric_schema do
    %{
      "type" => "object",
      "properties" => %{
        "label" => %{"type" => "string", "description" => "Metric label"},
        "value" => %{"type" => "string", "description" => "Metric value (displayed prominently)"}
      }
    }
  end

  def render_list_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string", "description" => "Optional list title"},
        "items" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "List items"
        }
      }
    }
  end

  def render_tabs_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string", "description" => "Optional tabs title"},
        "tabs" => %{
          "type" => "array",
          "description" => "Array of tabs",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "label" => %{"type" => "string", "description" => "Tab label"},
              "content" => %{
                "type" => "array",
                "description" => "Content items within the tab",
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "type" => %{
                      "type" => "string",
                      "enum" => ["text", "metric", "list", "chart", "table"],
                      "description" => "Content type"
                    },
                    "text" => %{"type" => "string", "description" => "Text content (for type text)"},
                    "label" => %{"type" => "string", "description" => "Label (for type metric)"},
                    "value" => %{"type" => "string", "description" => "Display value (for type metric)"},
                    "title" => %{"type" => "string", "description" => "Title (for type list, chart, or table)"},
                    "items" => %{
                      "type" => "array",
                      "items" => %{"type" => "string"},
                      "description" => "Items (for type list)"
                    },
                    "chartType" => %{
                      "type" => "string",
                      "enum" => ["bar", "stacked-bar", "line", "area", "pie", "donut", "heatmap"],
                      "description" => "Chart type (for type chart)"
                    },
                    "series" => %{
                      "type" => "array",
                      "description" => "Data series (for type chart)"
                    },
                    "columns" => %{
                      "type" => "array",
                      "items" => %{"type" => "string"},
                      "description" => "Column headers (for type table)"
                    },
                    "rows" => %{
                      "type" => "array",
                      "items" => %{"type" => "array", "items" => %{"type" => "string"}},
                      "description" => "Table rows (for type table)"
                    }
                  },
                  "required" => ["type"]
                }
              }
            },
            "required" => ["label", "content"]
          }
        }
      }
    }
  end

  def render_mindmap_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string", "description" => "Optional mind map title"},
        "nodes" => %{
          "type" => "array",
          "description" => "Flat array of nodes. The first node is the root. Each node references children by ID.",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "id" => %{"type" => "string", "description" => "Unique node identifier"},
              "label" => %{"type" => "string", "description" => "Node label text"},
              "children" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "IDs of child nodes"
              }
            },
            "required" => ["id", "label"]
          }
        }
      }
    }
  end
end
