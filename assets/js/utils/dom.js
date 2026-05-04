export const clamp = (value, min, max) => Math.max(min, Math.min(value, max));

export const parseJsonObject = (value) => {
  if (!value) {
    return null;
  }

  try {
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : null;
  } catch (_error) {
    return null;
  }
};

export const setMediaThumbnailLoaded = (image, loaded) => {
  const thumbnail = image?.closest(".media-thumbnail");

  if (!thumbnail) {
    return;
  }

  if (loaded) {
    thumbnail.classList.add("is-loaded");
  } else {
    thumbnail.classList.remove("is-loaded");
  }
};

export const syncMediaThumbnailState = (root) => {
  root.querySelectorAll(".media-thumbnail-image").forEach((image) => {
    setMediaThumbnailLoaded(image, Boolean(image.complete && image.naturalWidth > 0));
  });
};
