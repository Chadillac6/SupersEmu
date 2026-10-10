# Import and library

Pipeline: staging, archive extraction (zip/7z) with path/size/recursion limits, SHA-256,
header/ROM identification, filename fallback, console detection, title normalisation,
duplicate/variant detection, multi-disc grouping (+ generated .m3u), artwork, library commit.

Rules:
- Original files are never deleted or renamed in the user's storage.
- Unknown or corrupt files go to "Needs review", never silently dropped.
- Game identity is the content hash, so renames and moves keep saves attached.

Implemented in M0 spike: SNES `.sfc`/`.smc` import from the Files picker, SHA-256 identity,
duplicate skip, title clean-up ("Super_Game (USA) [!].sfc" to "Super Game"), import summary.
