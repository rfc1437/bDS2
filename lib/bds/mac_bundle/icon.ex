defmodule BDS.MacBundle.Icon do
  @moduledoc """
  Builds the macOS `AppIcon.icns` for the bDS2 bundle.

  The source artwork is the legacy app's pen icon (a gold pen on a gold disc,
  imported as `priv/desktop/macos/icon-source.svg`). The bundle icon recolours
  the **blue** pen to **red** by rotating any colour whose hue sits in the blue
  band, leaving the gold body and warm/neutral tones untouched. Recolouring the
  SVG text is fully deterministic and unit-testable; rasterisation then uses the
  bundled libvips (`Image`) so no extra system tooling is required for SVG→PNG.

  `.icns` packaging itself shells out to the macOS-only `sips`/`iconutil`.
  """

  # Hue band (degrees) that counts as "blue" and gets rotated to red.
  @blue_low 195
  @blue_high 265
  # Rotation that maps the pen's ~218–221° blues onto ~358–1° (red).
  @hue_shift 220

  # Standard macOS iconset base sizes; each is emitted at @1x and @2x.
  @iconset_sizes [16, 32, 128, 256, 512]

  @doc "Absolute path to the (blue) source SVG bundled in priv."
  @spec source_svg_path() :: String.t()
  def source_svg_path do
    Application.get_env(:bds, :mac_icon_source_svg) ||
      Path.join(:code.priv_dir(:bds), "desktop/macos/icon-source.svg")
  end

  @doc "Default output path for the generated `.icns`."
  @spec icns_path() :: String.t()
  def icns_path, do: Path.join(:code.priv_dir(:bds), "desktop/macos/AppIcon.icns")

  @doc """
  Recolour a single `#RRGGBB` value. Blue-band colours are hue-rotated to red;
  everything else is returned unchanged (byte-for-byte, no rounding drift).
  """
  @spec recolor_color(String.t()) :: String.t()
  def recolor_color("#" <> _ = hex) do
    {r, g, b} = to_rgb(hex)
    {h, s, l} = rgb_to_hsl(r, g, b)

    if h >= @blue_low and h < @blue_high do
      new_h = :math.fmod(h - @hue_shift + 360.0, 360.0)
      {nr, ng, nb} = hsl_to_rgb(new_h, s, l)
      to_hex(nr, ng, nb)
    else
      String.upcase(hex)
    end
  end

  @doc "Recolour every `#RRGGBB` literal found in an SVG (or any text)."
  @spec recolor_svg(String.t()) :: String.t()
  def recolor_svg(svg) when is_binary(svg) do
    Regex.replace(~r/#[0-9A-Fa-f]{6}/, svg, fn hex -> recolor_color(hex) end)
  end

  @doc """
  Generate the `.icns` from the source SVG. Returns `{:ok, icns_path}`.

  Steps: recolour SVG → render a 1024² PNG via libvips → emit the iconset sizes
  with `sips` → pack with `iconutil`.
  """
  @spec generate(keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate(opts \\ []) do
    source = Keyword.get(opts, :source_svg, source_svg_path())
    icns = Keyword.get(opts, :icns_path, icns_path())
    png_1024 = Keyword.get(opts, :png_path, Path.rootname(icns) <> "-1024.png")

    with {:ok, svg} <- File.read(source),
         :ok <- render_png(recolor_svg(svg), png_1024, 1024),
         {:ok, iconset} <- build_iconset(png_1024),
         :ok <- run("iconutil", ["-c", "icns", "-o", icns, iconset]) do
      File.rm_rf(iconset)
      {:ok, icns}
    end
  end

  @doc "Render an SVG string to a square PNG of `size` pixels via libvips."
  @spec render_png(String.t(), String.t(), pos_integer()) :: :ok | {:error, term()}
  def render_png(svg, png_path, size) do
    with {:ok, image} <- Image.from_binary(svg),
         {:ok, resized} <- Image.thumbnail(image, size, height: size),
         {:ok, _} <- Image.write(resized, png_path) do
      :ok
    end
  end

  defp build_iconset(png_1024) do
    iconset = Path.rootname(png_1024) <> ".iconset"
    File.rm_rf!(iconset)
    File.mkdir_p!(iconset)

    Enum.reduce_while(@iconset_sizes, {:ok, iconset}, fn base, acc ->
      with :ok <- emit_size(png_1024, iconset, base, 1),
           :ok <- emit_size(png_1024, iconset, base, 2) do
        {:cont, acc}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp emit_size(png_1024, iconset, base, scale) do
    px = base * scale
    suffix = if scale == 1, do: "#{base}x#{base}", else: "#{base}x#{base}@2x"
    out = Path.join(iconset, "icon_#{suffix}.png")
    run("sips", ["-z", Integer.to_string(px), Integer.to_string(px), png_1024, "--out", out])
  end

  defp run(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> {:error, {:command_failed, cmd, status, out}}
    end
  end

  # ---- colour space helpers -------------------------------------------------

  defp to_rgb("#" <> hex) do
    {
      String.to_integer(String.slice(hex, 0, 2), 16),
      String.to_integer(String.slice(hex, 2, 2), 16),
      String.to_integer(String.slice(hex, 4, 2), 16)
    }
  end

  defp to_hex(r, g, b) do
    "#" <> pad(r) <> pad(g) <> pad(b)
  end

  defp pad(v) do
    v
    |> max(0)
    |> min(255)
    |> Integer.to_string(16)
    |> String.upcase()
    |> String.pad_leading(2, "0")
  end

  defp rgb_to_hsl(r, g, b) do
    rf = r / 255.0
    gf = g / 255.0
    bf = b / 255.0

    max = Enum.max([rf, gf, bf])
    min = Enum.min([rf, gf, bf])
    l = (max + min) / 2.0
    d = max - min

    if d == 0.0 do
      {0.0, 0.0, l}
    else
      s = if l > 0.5, do: d / (2.0 - max - min), else: d / (max + min)

      h =
        cond do
          max == rf -> :math.fmod((gf - bf) / d + 6.0, 6.0)
          max == gf -> (bf - rf) / d + 2.0
          true -> (rf - gf) / d + 4.0
        end

      {h * 60.0, s, l}
    end
  end

  defp hsl_to_rgb(_h, s, l) when s == 0.0 do
    v = round(l * 255.0)
    {v, v, v}
  end

  defp hsl_to_rgb(h, s, l) do
    q = if l < 0.5, do: l * (1.0 + s), else: l + s - l * s
    p = 2.0 * l - q
    hk = h / 360.0

    {
      round(hue_to_channel(p, q, hk + 1.0 / 3.0) * 255.0),
      round(hue_to_channel(p, q, hk) * 255.0),
      round(hue_to_channel(p, q, hk - 1.0 / 3.0) * 255.0)
    }
  end

  defp hue_to_channel(p, q, t) do
    t = :math.fmod(t + 1.0, 1.0)

    cond do
      t < 1.0 / 6.0 -> p + (q - p) * 6.0 * t
      t < 1.0 / 2.0 -> q
      t < 2.0 / 3.0 -> p + (q - p) * (2.0 / 3.0 - t) * 6.0
      true -> p
    end
  end
end
