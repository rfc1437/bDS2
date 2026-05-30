defmodule BDS.Desktop.MenuEditor.HomeItemProtectionTest do
  use ExUnit.Case, async: true

  alias BDS.Desktop.ShellLive.MenuEditor.{TreeOps, TreePredicates}

  @home_id TreeOps.home_item_id()
  @other_id "some-other-item"

  defp home_state do
    %{
      items: [
        TreeOps.home_item(),
        %{item_id: @other_id, kind: :page, label: "About", slug: "about", children: [], is_home: false}
      ],
      selected_id: @home_id,
      draft: nil
    }
  end

  defp other_state do
    %{
      items: [
        TreeOps.home_item(),
        %{item_id: @other_id, kind: :page, label: "About", slug: "about", children: [], is_home: false}
      ],
      selected_id: @other_id,
      draft: nil
    }
  end

  describe "TreePredicates" do
    test "can_move_up? returns false for home item" do
      items = home_state().items
      refute TreePredicates.can_move_up?(items, @home_id)
    end

    test "can_move_down? returns false for home item" do
      items = home_state().items
      refute TreePredicates.can_move_down?(items, @home_id)
    end

    test "can_indent? returns false for home item" do
      items = home_state().items
      refute TreePredicates.can_indent?(items, @home_id)
    end

    test "can_unindent? returns false for home item" do
      items = home_state().items
      refute TreePredicates.can_unindent?(items, @home_id)
    end

    test "can_delete? returns false for home item" do
      refute TreePredicates.can_delete?(@home_id)
    end

    test "can_delete? returns true for non-home item" do
      assert TreePredicates.can_delete?(@other_id)
    end
  end

  describe "TreeOps" do
    test "move_selected is no-op when home item is selected" do
      state = home_state()
      assert TreeOps.move_selected(state, :up) == state
      assert TreeOps.move_selected(state, :down) == state
    end

    test "move_selected works for non-home item" do
      state = other_state()
      moved = TreeOps.move_selected(state, :up)
      assert moved != state
    end

    test "indent_selected is no-op when home item is selected" do
      state = home_state()
      assert TreeOps.indent_selected(state) == state
    end

    test "unindent_selected is no-op when home item is selected" do
      state = home_state()
      assert TreeOps.unindent_selected(state) == state
    end

    test "delete_selected is no-op when home item is selected" do
      state = home_state()
      assert TreeOps.delete_selected(state) == state
    end

    test "drop_selected is no-op when drag item is home item" do
      state = other_state()
      assert TreeOps.drop_selected(state, @home_id, @other_id, "after") == state
    end

    test "drop_selected works when neither item is home" do
      state = %{
        other_state()
        | items: [
            %{item_id: "a", kind: :page, label: "A", slug: "a", children: [], is_home: false},
            %{item_id: "b", kind: :page, label: "B", slug: "b", children: [], is_home: false}
          ],
          selected_id: "b"
      }

      dropped = TreeOps.drop_selected(state, "a", "b", "before")
      assert dropped != state
    end
  end
end
