defmodule BDS.Desktop.OverlayTest do
  use ExUnit.Case, async: true

  alias BDS.Desktop.Overlay

  test "post overlays build picker, translation, and gallery payloads from shell context" do
    context = sample_context()

    insert_link = Overlay.open(:post, :insert_link, context)

    assert insert_link.kind == :insert_link
    assert insert_link.active_tab == :internal
    assert Enum.map(insert_link.related_posts, & &1.post_id) == ["post-2", "post-3", "post-4"]
    assert insert_link.results == []

    insert_link = Overlay.set_search_query(insert_link, "pho")

    assert Enum.map(insert_link.results, & &1.post_id) == ["post-2"]
    assert hd(insert_link.results).canonical_url == "/2026/04/26/photo-walk"

    language_picker = Overlay.open(:post, :language_picker, context)

    assert language_picker.kind == :language_picker
    assert language_picker.source_language == "en"
    assert Enum.map(language_picker.available_targets, & &1.code) == ["de", "fr"]

    assert Enum.find(language_picker.available_targets, &(&1.code == "de")).has_existing_translation ==
             true

    gallery = Overlay.open(:post, :gallery, context)

    assert gallery.kind == :gallery
    assert gallery.post_id == "post-1"
    assert Enum.map(gallery.images, & &1.media_id) == ["media-1", "media-2"]
    assert gallery.lightbox == nil

    gallery = Overlay.select_gallery_image(gallery, "media-2")

    assert gallery.lightbox.media_id == "media-2"
    assert gallery.lightbox.current_index == 1

    gallery = Overlay.lightbox_next(gallery)
    assert gallery.lightbox.media_id == "media-1"

    gallery = Overlay.lightbox_previous(gallery)
    assert gallery.lightbox.media_id == "media-2"
  end

  test "media and tag overlays keep shared AI, destructive, and confirm semantics" do
    context = sample_context()

    ai_modal = Overlay.open(:media, :ai_suggestions, context)

    assert ai_modal.kind == :ai_suggestions
    assert Enum.all?(ai_modal.fields, & &1.accepted)

    ai_modal = Overlay.toggle_ai_field(ai_modal, "caption")
    refute Enum.find(ai_modal.fields, &(&1.key == "caption")).accepted

    delete_modal = Overlay.open(:media, :confirm_delete, context)

    assert delete_modal.kind == :confirm_delete
    assert delete_modal.entity_type == "media"
    assert delete_modal.reference_count == 2
    assert delete_modal.reference_list == ["Photo Walk", "Trip Notes"]

    confirm_dialog = Overlay.open(:tags, :confirm_merge, context)

    assert confirm_dialog.kind == :confirm_dialog
    assert confirm_dialog.title == "Merge 3 tags into travel?"
    assert confirm_dialog.message =~ "Cannot be undone"
  end

  test "ai suggestions overlay starts in loading state and updates from async results" do
    context = put_in(sample_context(), [:ai_fields, Access.all(), :loading], true)
    context = put_in(context, [:ai_fields, Access.all(), :suggested_value], "")

    ai_modal = Overlay.open(:post, :ai_suggestions, context)

    assert Enum.all?(ai_modal.fields, & &1.loading)
    assert Enum.all?(ai_modal.fields, &(&1.suggested_value == ""))

    updated =
      Overlay.set_ai_suggestions(ai_modal, %{"title" => "Better Title", "alt" => "Better Alt"})

    title_field = Enum.find(updated.fields, &(&1.key == "title"))
    assert title_field.suggested_value == "Better Title"
    refute title_field.loading

    alt_field = Enum.find(updated.fields, &(&1.key == "alt"))
    assert alt_field.suggested_value == "Better Alt"
    refute alt_field.loading

    caption_field = Enum.find(updated.fields, &(&1.key == "caption"))
    assert caption_field.suggested_value == ""
    assert caption_field.loading
  end

  test "set_ai_suggestions ignores non-string or empty values" do
    context = sample_context()
    ai_modal = Overlay.open(:post, :ai_suggestions, context)

    updated =
      Overlay.set_ai_suggestions(ai_modal, %{
        "title" => "Valid",
        "alt" => "",
        "caption" => nil,
        "extra" => ["array"]
      })

    title_field = Enum.find(updated.fields, &(&1.key == "title"))
    assert title_field.suggested_value == "Valid"

    alt_field = Enum.find(updated.fields, &(&1.key == "alt"))
    assert alt_field.suggested_value == "Street scene at dusk"

    caption_field = Enum.find(updated.fields, &(&1.key == "caption"))
    assert caption_field.suggested_value == "A busy corner at dusk"
  end

  defp sample_context do
    %{
      current_tab: %{type: :post, id: "post-1", title: "Trip Notes", subtitle: "Draft"},
      current_post_language: "en",
      posts: [
        %{
          id: "post-1",
          title: "Trip Notes",
          status: "draft",
          canonical_url: "/2026/04/26/trip-notes"
        },
        %{
          id: "post-2",
          title: "Photo Walk",
          status: "published",
          canonical_url: "/2026/04/26/photo-walk"
        },
        %{
          id: "post-3",
          title: "Travel Checklist",
          status: "draft",
          canonical_url: "/2026/04/20/travel-checklist"
        },
        %{
          id: "post-4",
          title: "Packing List",
          status: "archived",
          canonical_url: "/2026/03/18/packing-list"
        }
      ],
      media: [
        %{
          id: "media-1",
          title: "Cover Shot",
          original_name: "cover-shot.jpg",
          is_image: true,
          thumbnail_url: "/media-thumbnail/media-1",
          image_url: "/media-thumbnail/media-1?size=large",
          alt_text: "Cover shot"
        },
        %{
          id: "media-2",
          title: "Street Scene",
          original_name: "street-scene.jpg",
          is_image: true,
          thumbnail_url: "/media-thumbnail/media-2",
          image_url: "/media-thumbnail/media-2?size=large",
          alt_text: "Street scene"
        },
        %{
          id: "media-3",
          title: "Audio Memo",
          original_name: "memo.m4a",
          is_image: false,
          thumbnail_url: nil,
          image_url: nil,
          alt_text: nil
        }
      ],
      post_media_ids: ["media-1", "media-2"],
      blog_languages: ["en", "de", "fr"],
      language_names: %{"en" => "English", "de" => "Deutsch", "fr" => "Francais"},
      language_flags: %{"en" => "GB", "de" => "DE", "fr" => "FR"},
      existing_translations: %{"de" => "draft"},
      ai_fields: [
        %{
          key: "title",
          label: "Title",
          current_value: "Street Scene",
          suggested_value: "Street Scene at Dusk",
          locked: false
        },
        %{
          key: "alt",
          label: "Alt Text",
          current_value: "",
          suggested_value: "Street scene at dusk",
          locked: false
        },
        %{
          key: "caption",
          label: "Caption",
          current_value: "Busy corner",
          suggested_value: "A busy corner at dusk",
          locked: false
        }
      ],
      delete_details: %{
        entity_name: "Street Scene",
        entity_type: "media",
        reference_list: ["Photo Walk", "Trip Notes"]
      },
      merge_details: %{target: "travel", count: 3}
    }
  end
end
