defmodule BDS.Rendering.I18n do
  @moduledoc false

  @supported_languages ~w(en de fr it es)

  @flags %{
    "en" => "🇬🇧",
    "de" => "🇩🇪",
    "fr" => "🇫🇷",
    "it" => "🇮🇹",
    "es" => "🇪🇸"
  }

  @catalog %{
    "en" => %{
      "render.archive" => "Archive",
      "render.pagination.label" => "Pagination",
      "render.pagination.newer" => "newer",
      "render.pagination.older" => "older",
      "render.notFound.message" => "The requested preview page could not be found.",
      "render.notFound.back" => "Back to preview home",
      "render.photoArchive.empty" => "No photos found for this archive.",
      "render.gallery.empty" => "No linked images found.",
      "render.tagCloud.empty" => "No tags found.",
      "render.tagCloud.ariaLabel" => "Tag cloud",
      "render.calendar.open" => "Open calendar",
      "render.calendar.close" => "Close calendar",
      "render.calendar.title" => "Archive calendar",
      "render.calendar.loading" => "Loading calendar…",
      "render.calendar.error" => "Calendar data could not be loaded.",
      "render.taxonomy.ariaLabel" => "Taxonomy",
      "render.backlinks.label" => "Linked from",
      "render.backlinks.ariaLabel" => "Backlinks",
      "render.languageSwitcher.ariaLabel" => "Language",
      "render.video.youtubeTitle" => "YouTube video",
      "render.video.vimeoTitle" => "Vimeo video",
      "render.search.placeholder" => "Search...",
      "render.search.ariaLabel" => "Site search",
      "render.month.1" => "January",
      "render.month.2" => "February",
      "render.month.3" => "March",
      "render.month.4" => "April",
      "render.month.5" => "May",
      "render.month.6" => "June",
      "render.month.7" => "July",
      "render.month.8" => "August",
      "render.month.9" => "September",
      "render.month.10" => "October",
      "render.month.11" => "November",
      "render.month.12" => "December"
    },
    "de" => %{
      "render.archive" => "Archiv",
      "render.pagination.label" => "Seitennummerierung",
      "render.pagination.newer" => "neuer",
      "render.pagination.older" => "älter",
      "render.notFound.message" => "Die angeforderte Vorschauseite konnte nicht gefunden werden.",
      "render.notFound.back" => "Zurück zur Vorschau-Startseite",
      "render.photoArchive.empty" => "Keine Fotos für dieses Archiv gefunden.",
      "render.gallery.empty" => "Keine verknüpften Bilder gefunden.",
      "render.tagCloud.empty" => "Keine Tags gefunden.",
      "render.tagCloud.ariaLabel" => "Tag-Wolke",
      "render.calendar.open" => "Kalender öffnen",
      "render.calendar.close" => "Kalender schließen",
      "render.calendar.title" => "Archivkalender",
      "render.calendar.loading" => "Kalender wird geladen …",
      "render.calendar.error" => "Kalenderdaten konnten nicht geladen werden.",
      "render.taxonomy.ariaLabel" => "Taxonomie",
      "render.backlinks.label" => "Verlinkt von",
      "render.backlinks.ariaLabel" => "Rückverweise",
      "render.languageSwitcher.ariaLabel" => "Sprache",
      "render.video.youtubeTitle" => "YouTube-Video",
      "render.video.vimeoTitle" => "Vimeo-Video",
      "render.search.placeholder" => "Suchen...",
      "render.search.ariaLabel" => "Seitensuche",
      "render.month.1" => "Januar",
      "render.month.2" => "Februar",
      "render.month.3" => "März",
      "render.month.4" => "Apr.",
      "render.month.5" => "Mai",
      "render.month.6" => "Juni",
      "render.month.7" => "Juli",
      "render.month.8" => "Aug.",
      "render.month.9" => "Sept.",
      "render.month.10" => "Oktober",
      "render.month.11" => "Nov.",
      "render.month.12" => "Dezember"
    },
    "fr" => %{
      "render.archive" => "Archives",
      "render.pagination.label" => "Navigation paginée",
      "render.pagination.newer" => "plus récent",
      "render.pagination.older" => "plus ancien",
      "render.notFound.message" => "La page d’aperçu demandée est introuvable.",
      "render.notFound.back" => "Retour à l’accueil de l’aperçu",
      "render.photoArchive.empty" => "Aucune photo trouvée pour cette archive.",
      "render.gallery.empty" => "Aucune image liée trouvée.",
      "render.tagCloud.empty" => "Aucun tag trouvé.",
      "render.tagCloud.ariaLabel" => "Nuage de tags",
      "render.calendar.open" => "Ouvrir le calendrier",
      "render.calendar.close" => "Fermer le calendrier",
      "render.calendar.title" => "Calendrier des archives",
      "render.calendar.loading" => "Chargement du calendrier…",
      "render.calendar.error" => "Impossible de charger les données du calendrier.",
      "render.taxonomy.ariaLabel" => "Taxonomie",
      "render.backlinks.label" => "Lié depuis",
      "render.backlinks.ariaLabel" => "Rétroliens",
      "render.languageSwitcher.ariaLabel" => "Langue",
      "render.video.youtubeTitle" => "Vidéo YouTube",
      "render.video.vimeoTitle" => "Vidéo Vimeo",
      "render.search.placeholder" => "Rechercher...",
      "render.search.ariaLabel" => "Recherche du site",
      "render.month.1" => "janvier",
      "render.month.2" => "février",
      "render.month.3" => "mars",
      "render.month.4" => "avril",
      "render.month.5" => "mai",
      "render.month.6" => "juin",
      "render.month.7" => "juillet",
      "render.month.8" => "août",
      "render.month.9" => "septembre",
      "render.month.10" => "octobre",
      "render.month.11" => "novembre",
      "render.month.12" => "décembre"
    },
    "it" => %{
      "render.archive" => "Archivio",
      "render.pagination.label" => "Paginazione",
      "render.pagination.newer" => "più recente",
      "render.pagination.older" => "più vecchio",
      "render.notFound.message" => "La pagina di anteprima richiesta non è stata trovata.",
      "render.notFound.back" => "Torna alla home di anteprima",
      "render.photoArchive.empty" => "Nessuna foto trovata per questo archivio.",
      "render.gallery.empty" => "Nessuna immagine collegata trovata.",
      "render.tagCloud.empty" => "Nessun tag trovato.",
      "render.tagCloud.ariaLabel" => "Nuvola di tag",
      "render.calendar.open" => "Apri calendario",
      "render.calendar.close" => "Chiudi calendario",
      "render.calendar.title" => "Calendario archivio",
      "render.calendar.loading" => "Caricamento calendario…",
      "render.calendar.error" => "Impossibile caricare i dati del calendario.",
      "render.taxonomy.ariaLabel" => "Tassonomia",
      "render.backlinks.label" => "Collegato da",
      "render.backlinks.ariaLabel" => "Retrocollegamenti",
      "render.languageSwitcher.ariaLabel" => "Lingua",
      "render.video.youtubeTitle" => "Video YouTube",
      "render.video.vimeoTitle" => "Video Vimeo",
      "render.search.placeholder" => "Cerca...",
      "render.search.ariaLabel" => "Ricerca nel sito",
      "render.month.1" => "gennaio",
      "render.month.2" => "febbraio",
      "render.month.3" => "marzo",
      "render.month.4" => "aprile",
      "render.month.5" => "maggio",
      "render.month.6" => "giugno",
      "render.month.7" => "luglio",
      "render.month.8" => "agosto",
      "render.month.9" => "settembre",
      "render.month.10" => "ottobre",
      "render.month.11" => "novembre",
      "render.month.12" => "dicembre"
    },
    "es" => %{
      "render.archive" => "Archivo",
      "render.pagination.label" => "Paginación",
      "render.pagination.newer" => "más reciente",
      "render.pagination.older" => "más antiguo",
      "render.notFound.message" => "No se pudo encontrar la página de vista previa solicitada.",
      "render.notFound.back" => "Volver al inicio de vista previa",
      "render.photoArchive.empty" => "No se encontraron fotos para este archivo.",
      "render.gallery.empty" => "No se encontraron imágenes vinculadas.",
      "render.tagCloud.empty" => "No se encontraron etiquetas.",
      "render.tagCloud.ariaLabel" => "Nube de etiquetas",
      "render.calendar.open" => "Abrir calendario",
      "render.calendar.close" => "Cerrar calendario",
      "render.calendar.title" => "Calendario de archivo",
      "render.calendar.loading" => "Cargando calendario…",
      "render.calendar.error" => "No se pudieron cargar los datos del calendario.",
      "render.taxonomy.ariaLabel" => "Taxonomía",
      "render.backlinks.label" => "Enlazado desde",
      "render.backlinks.ariaLabel" => "Retroenlaces",
      "render.languageSwitcher.ariaLabel" => "Idioma",
      "render.video.youtubeTitle" => "Vídeo de YouTube",
      "render.video.vimeoTitle" => "Vídeo de Vimeo",
      "render.search.placeholder" => "Buscar...",
      "render.search.ariaLabel" => "Buscar en el sitio",
      "render.month.1" => "enero",
      "render.month.2" => "febrero",
      "render.month.3" => "marzo",
      "render.month.4" => "abril",
      "render.month.5" => "mayo",
      "render.month.6" => "junio",
      "render.month.7" => "julio",
      "render.month.8" => "agosto",
      "render.month.9" => "septiembre",
      "render.month.10" => "octubre",
      "render.month.11" => "noviembre",
      "render.month.12" => "diciembre"
    }
  }

  def normalize_language(language) do
    language
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.split("-", parts: 2)
    |> List.first()
    |> case do
      value when value in @supported_languages -> value
      _other -> "en"
    end
  end

  def translate(language, key) do
    normalized_language = normalize_language(language)
    @catalog[normalized_language][key] || @catalog["en"][key] || key
  end

  def flag(language) do
    normalized_language = normalize_language(language)
    Map.get(@flags, normalized_language, String.upcase(normalized_language))
  end
end
