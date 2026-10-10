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
- `metadata_jobs (game_id, provider, match_status, artwork_status, dataset_version)` tracks background work.
  `match_status` is `matched` or `unmatched`. A NULL status or a stale `dataset_version` gets retried, and so does
  NULL `artwork_status` on a matched game.
- `games` keeps what the importer found (filename title, system). `games.cover_artwork` is the manual cover override
  (`ArtworkStore.setCover`).

`MetadataMerge` merges field by field in provider precedence order: `manual`, `igdb`, `screenscraper`, `thegamesdb`,
then `libretro`. Unknown providers come last, and the imported values in `games` are the final fallback. The manual
cover beats every provider cover. Only `libretro` exists today. The others are placeholders in the precedence list, so
adding one means implementing `MetadataProvider` (`lookup` + `artwork(for:)`) and registering it in `MetadataService`.

## API (additive; older clients ignore the new fields)

- `GameSummary`: `publisher`, `region`, `genres`, `players`, `criticScore {score, source, url}`, `backdropPath`.
  `genre` stays as the first genre.
- `GameDetail`: `summary` (the description/intro), `developer`, `logoPath`, `titleScreenPath`, `screenshotPaths`,
  `sources [{provider, name, url}]`.
- `GET /v1/games/:id/artwork/:kind` (position 0) and `GET /v1/games/:id/artwork/:kind/:position`. These use the same
  permission checks, path containment and content-hash ETag as the existing cover route. Paths are only returned when
  the art exists, so clients fall back to the generated tile when a path is nil.

## libretro provider

1. Hashing. The server computes CRC32, MD5 and SHA-1 of the stored ROM. For No-Intro it also tries headerless forms:
   SNES without its 512-byte copier header, de-interleaved `.smd`, and big-endian `.z64` from `.v64`/`.n64`. For disc
   games it hashes the data tracks of the first disc (Redump hashes per track). Matching tries SHA-1, then MD5, then
   CRC32 together with the size.
2. Fields. Title comes from the No-Intro/Redump name ("Legend of Zelda, The - A Link to the Past (USA)" becomes "The
   Legend of Zelda - A Link to the Past"), and region from its first parenthesised group. Year, publisher, developer,
   genre and max players come from the `metadat/{releaseyear,publisher,developer,genre,maxusers}` DATs, keyed by CRC.
   Those supplements exist for the cartridge systems. PlayStation only has `developer`, and Sega CD has none, so disc
   games mostly get title and region. Neither DAT has descriptions or critic scores; those wait for a later provider.
3. Artwork. `Named_Boxarts` becomes `cover`, `Named_Titles` becomes `title`, and `Named_Snaps` becomes `screenshot/0`.
   Files come from `raw.githubusercontent.com/libretro-thumbnails/<System>/<commit>/…`, named by the DAT name with
   `&*/:\`<>?\|"` replaced by `_`. Multi-disc sets also try the name without " (Disc N)". libretro has no backdrops.
4. Background. `MetadataService` runs after every import or scan, at launch, and every 30 minutes after that. All
   requests share one rate limiter (at most one request a second). Network errors leave the job pending for the next
   pass. `supersemu-server run --no-metadata` turns the service off.

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
