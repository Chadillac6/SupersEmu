# Metadata and artwork

Status: M3 server track. The server fills in titles, details and artwork automatically after import. No API keys,
no admin action, and nothing breaks when it is offline or a game isn't recognised.

## Model

Every provider writes its own row; every field is optional.

- `game_metadata (game_id, provider, …)`: `provider_ref` (the provider's ID for the game), title, region, year,
  publisher, developer, genres (JSON array), description, players, critic score (0-100) + source + URL, and attribution
  (`source_name`, `source_url`).
- `game_artwork (game_id, provider, kind, position, path, source_url)`. Kinds are `cover`, `backdrop`, `logo`, `title`
  (title screen) and `screenshot`. `position` orders screenshots. The files are content-addressed under
  `artwork/<gameID>/<provider>-<kind>-<position>-<sha256>.<ext>`.
- `metadata_jobs (game_id, provider, match_status, artwork_status, dataset_version, artwork_version)` tracks background
  work. `match_status` is `matched` or `unmatched`. A NULL status or a stale `dataset_version` gets rematched. A matched
  game whose `artwork_status` is NULL or whose `artwork_version` is stale gets its artwork refetched, without a
  rematch. When a rematch drops or changes the match, that provider's art is deleted. The manual cover is kept.
- `games` keeps what the importer found (filename title, system). `games.cover_artwork` is the manual cover override
  (`ArtworkStore.setCover`).

- Migration `v5_metadata_reviews` adds optional `reception` + `reception_source` + `reception_url` (a short critical
  reception summary), `review_name` + `review_url` (where to read full reviews) and `artwork_urls` (JSON, kind -> URL,
  for providers that find art URLs during lookup) to `game_metadata`. Existing rows keep every value and get NULLs.

`MetadataMerge` merges field by field in provider precedence order: `manual`, `igdb`, `steamgriddb`, `screenscraper`,
`thegamesdb`, `wikipedia`, then `libretro`. Unknown providers come last, and the imported values in `games` are the
final fallback. The manual cover beats every provider cover. Adding a provider means implementing `MetadataProvider`
(`lookup` + `artwork(for:)`, plus `isEnabled` if it needs a key) and adding it to `MetadataService.standard`.

## API (additive; older clients ignore the new fields)

- `GameSummary`: `publisher`, `region`, `genres`, `players`, `criticScore {score, source, url}`, `backdropPath`,
  `heroPath` (backdrop, else the first screenshot, else the title screen) and `logoPath`. `genre` stays as the first genre.
- `GameDetail`: `summary` (the description/intro) and `summarySource` (its attribution), `developer`, `logoPath`,
  `titleScreenPath`, `screenshotPaths`, `reception {text, source, url}`, `reviewLink {name, url}`,
  `sources [{provider, name, url}]`.
- `GET /v1/games/:id/artwork/:kind` (position 0) and `GET /v1/games/:id/artwork/:kind/:position`. These use the same
  permission checks, path containment and content-hash ETag as the existing cover route. Paths are only returned when
  the art exists, so clients fall back to the generated tile when a path is nil.

## libretro provider

1. Hashing. The server computes CRC32, MD5 and SHA-1 of the stored ROM. For No-Intro it also tries headerless forms:
   SNES without its 512-byte copier header, de-interleaved `.smd`, and big-endian `.z64` from `.v64`/`.n64`. For disc
   games it hashes the first disc's tracks until one matches (Redump hashes per track). Matching tries SHA-1, then MD5, then
   CRC32 together with the size.
2. Fields. Title comes from the No-Intro/Redump name ("Legend of Zelda, The - A Link to the Past (USA)" becomes "The
   Legend of Zelda - A Link to the Past"), and region from its first parenthesised group. Year, publisher, developer,
   genre and max players come from the `metadat/{releaseyear,publisher,developer,genre,maxusers}` DATs, keyed by CRC
   or, for PlayStation, by serial. All pinned DATs for a system must load before anything matches, so a failed
   download defers the match instead of leaving fields blank.
   Those supplements exist for the cartridge systems. PlayStation only has `developer`, and Sega CD has none, so disc
   games mostly get title and region. Neither DAT has descriptions or critic scores; those come from Wikipedia and IGDB (below).
3. Artwork. `Named_Boxarts` becomes `cover`, `Named_Titles` becomes `title`, and `Named_Snaps` becomes `screenshot/0`.
   Files come from `raw.githubusercontent.com/libretro-thumbnails/<System>/<commit>/…`, named by the DAT name with
   `&*/:\`<>?\|"` replaced by `_`. Multi-disc sets also try the name without " (Disc N)". Revision tags such as " (Rev 1)"
   are then omitted as a fallback, keeping region and language tags intact. Exact names always take precedence.
   libretro has no backdrops. The artwork version combines the system's thumbnail commit with the name-fallback
   algorithm version, so either change retries completed artwork jobs without rematching ROMs.
4. Background. `MetadataService` runs after every import or scan, at launch, and every 30 minutes after that. All
   requests share one rate limiter (at most one request a second). Network errors leave the job pending for the next
   pass. `supersemu-server run --no-metadata` turns the service off.

## Wikipedia provider (keyless)

Searches English Wikipedia (`w/api.php?action=query&list=search`, "<title> <console> video game") using the best title
known so far (libretro's canonical title, else the imported one). A result only counts when its title, without a
"(… video game)" qualifier, equals the game's (case, accents, punctuation and a leading "The" ignored), and its REST
page summary is a standard page whose description mentions "game". The intro is the summary's first four sentences.
The reception is the first three sentences of the `== Reception ==` section (also "Critical reception", "Reception and
legacy"), from `prop=extracts&explaintext=1`. Both are attributed with a link to the article (CC BY-SA 4.0); the app
shows "From Wikipedia" and a "Wikipedia" link.

## Keyed providers (optional)

Keys come from environment variables, else `<data-dir>/metadata.keys` (JSON, mode 0600), written with
`supersemu-server metadata set-key <name>` (reads the key from stdin, hidden when typed) and removed with
`metadata clear-key <name>`. `metadata status` says which providers are enabled and never prints a key. Keys are read
at the start of each pass, so no restart is needed. They never leave the server: no route returns them, nothing logs
them, artwork CDN downloads don't carry them, and backups skip `metadata.keys` (so a restore keeps the current keys).
Without a key the provider is skipped entirely and makes no requests.

| Provider | Keys | What it adds |
|---|---|---|
| `igdb` | `SUPERSEMU_IGDB_CLIENT_ID` + `SUPERSEMU_IGDB_CLIENT_SECRET` (Twitch app; `igdb-client-id`, `igdb-client-secret`) | `criticScore` from `aggregated_rating` (critics), else `total_rating`, and a "Read on IGN" `reviewLink` from IGDB's websites list, else an IGN search URL. No review text is quoted. |
| `steamgriddb` | `SUPERSEMU_STEAMGRIDDB_KEY` (`steamgriddb`) | High-res hero (stored as `backdrop`) and `logo` art, static PNG/JPEG only, served through the usual artwork routes. |

IGDB gets a Twitch app access token (client credentials) and reuses it until a minute before expiry; it searches
`games` by title on the console's platform and takes the result with the same title. SteamGridDB matches by
`search/autocomplete` title, then takes the top hero and logo. Without SteamGridDB, the libretro screenshot or title screen
stands in as the hero (`heroPath`), and the app's hero falls back to the cover over a blurred copy of itself.

## Datasets (pinned, downloaded at runtime, never committed)

- libretro-database commit `bf825e3ec48d43557ad024da6a7b93e512043525` (2026-10-08). Each DAT's SHA-256 is pinned in
  `MetadataCatalog.pinned`. Downloads go into `<data-dir>/metadata/libretro-database/<commit>/`, and a file whose hash
  doesn't match is discarded. The whole set is about 13 MB, 3.9 MB of it the PlayStation Redump DAT.
- libretro-thumbnails is pinned per system repo (commits as of 2026-10-10, listed in `MetadataCatalog.pinned`).
  Images are fetched one game at a time and stored only under the server's `artwork/`.
- To bump either one, change the commits and refresh the hashes with `scripts/metadata-pins.sh <commit>`.

## Licences

- libretro-database: CC BY-SA 4.0 (its `LICENSE`). The DATs are derived from No-Intro (datomatic.no-intro.org) and
  Redump (redump.org). Metadata stored on the server is attributed per game through `GameDetail.sources`. We
  don't redistribute the DATs: each server downloads them itself.
- libretro-thumbnails: the repos have no licence file. The README credits MobyGames, Fandom and volunteers, and says
  the art originates from each game's developers and publishers. We treat the images as third-party copyrighted art.
  Each user's server fetches them only for games that user owns, keeps them for personal use, and never commits or
  bundles them. If SupersEmu is ever distributed beyond Chad's household (Phase 2), this needs review.
- Wikipedia text: CC BY-SA 4.0, shown with attribution and a link to the article.
- IGDB data and SteamGridDB images: under each service's API terms, fetched per server with Chad's own keys, for
  personal use. Review the terms before Phase 2. Console logos: see `branding-assets.md`.
