defmodule BDS.AI.JsonContentTest do
  use ExUnit.Case, async: true

  alias BDS.AI.JsonContent

  test "decodes a bare JSON object" do
    assert %{"title" => "Sunset"} = JsonContent.decode(~s({"title": "Sunset"}))
  end

  test "decodes a JSON object wrapped in a json markdown fence" do
    content = """
    ```json
    {
      "title": "Ahornblätter im Herbstlicht",
      "alt": "Nahaufnahme von Ahornblättern",
      "caption": "Einige Ahornblätter verfärben sich."
    }
    ```
    """

    assert %{
             "title" => "Ahornblätter im Herbstlicht",
             "alt" => "Nahaufnahme von Ahornblättern",
             "caption" => "Einige Ahornblätter verfärben sich."
           } = JsonContent.decode(content)
  end

  test "decodes a JSON object wrapped in an untagged markdown fence" do
    assert %{"language_code" => "de"} =
             JsonContent.decode("```\n{\"language_code\": \"de\"}\n```")
  end

  test "decodes a fenced JSON object with an uppercase language tag" do
    assert %{"slug" => "herbst"} = JsonContent.decode("```JSON\n{\"slug\": \"herbst\"}\n```")
  end

  test "decodes a fenced JSON object surrounded by prose" do
    content = """
    Here is the requested metadata:

    ```json
    {"title": "Herbst"}
    ```

    Let me know if you need anything else.
    """

    assert %{"title" => "Herbst"} = JsonContent.decode(content)
  end

  test "decodes a bare JSON object surrounded by prose" do
    content = ~s(Sure! {"title": "Herbst", "alt": "Blätter"} Hope this helps.)

    assert %{"title" => "Herbst", "alt" => "Blätter"} = JsonContent.decode(content)
  end

  test "returns nil for content without a JSON object" do
    assert JsonContent.decode("This is not valid JSON") == nil
  end

  test "returns nil for a JSON array" do
    assert JsonContent.decode(~s([1, 2, 3])) == nil
  end

  test "returns nil for nil and non-binary input" do
    assert JsonContent.decode(nil) == nil
    assert JsonContent.decode(42) == nil
  end
end
