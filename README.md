# mpv-jamak

**jamak** (자막, Korean for *subtitles*) is an interactive subtitle downloader
for [mpv](https://mpv.io). Pure Lua, no dependencies beyond `curl` — no
Python, no luarocks, nothing to install. It talks to the
[OpenSubtitles.com](https://www.opensubtitles.com) REST API and shows ranked
results in mpv's native console UI, drawn right over the video.

## Why another one?

- **Zero dependencies.** One Lua file using only mpv built-ins plus `curl`.
- **You pick the subtitle.** Instead of blindly loading the top match, jamak
  shows a fuzzy-filterable list (like mpv's built-in `g-s` track selector)
  with language, release name, download count, and exact-match tags — pick
  one, it loads. Wrong pick? Re-open the list and pick another; results are
  cached, no re-query.
- **Exact matching via moviehash.** Computes the OpenSubtitles 64-bit file
  hash in pure Lua, so subtitles that match your exact file rank first,
  tagged `[HASH]`.
- **Quota-aware auto mode.** Optional: on file load, files with no subtitle
  track get an automatic download *only* when an exact hash match exists —
  a free OpenSubtitles account has 10 downloads/day, and jamak never spends
  one on a guess.
- **Async everywhere.** Network calls never block playback.

## Requirements

- mpv **0.39+** (uses the `mp.input` console API)
- `curl` (any remotely recent version)
- optional: [subliminal](https://github.com/Diaoul/subliminal), used as a
  fallback only when the API returns nothing

## Installation

Clone into your mpv `scripts` directory:

```sh
git clone https://github.com/arrufat/mpv-jamak ~/.config/mpv/scripts/jamak
```

or add it as a submodule of your dotfiles:

```sh
git submodule add https://github.com/arrufat/mpv-jamak mpv/scripts/jamak
```

The directory name (`jamak`) is the script name — keep it, or your
`script-opts` file won't be found.

## Configuration

1. Create a free account at [opensubtitles.com](https://www.opensubtitles.com).
2. Register an API consumer at
   [opensubtitles.com/consumers](https://www.opensubtitles.com/consumers)
   to get an API key.
3. Copy [`jamak.conf.example`](jamak.conf.example) to
   `~/.config/mpv/script-opts/jamak.conf` and fill in the key and your
   account credentials.

> **Note:** credentials are stored in plain text — mpv has no secret store.
> Keep `jamak.conf` out of any public dotfiles repo.

Recommended `mpv.conf` companion settings, so previously downloaded
subtitles auto-load on replay:

```ini
sub-auto=fuzzy
slang=en,eng
```

## Usage

| Key | Action |
|---|---|
| `Ctrl+u` | Search using moviehash + guessed title; pick from the list. Re-press to re-show cached results instantly. |
| `Ctrl+U` | Manual search: edit the title (pre-filled), then choose a language from the full fuzzy-filterable list, then pick. |

Both are rebindable in `input.conf` via
`script-binding jamak/jamak-search` and
`script-binding jamak/jamak-search-manual`.

Results are ranked: exact hash matches first, then your configured language
priority, then download count. Downloads land next to the video as
`<video>.<lang>.srt` (or in `fallback_dir` if the directory isn't
writable), and are selected immediately.

### Auto mode

Set `auto=yes` in `jamak.conf` and, whenever a file with no subtitle track
loads, jamak searches in the background:

- exact hash match → downloads and selects it, hands-free;
- title matches only → shows a brief "N subs available — Ctrl+u to pick"
  hint and pre-caches the results, spending nothing.

Files that already have subtitles (embedded, or a sibling `.srt` picked up
by `sub-auto=fuzzy`) are skipped entirely, so each file triggers at most
one download, ever.

### Debugging

`script-message jamak-hash` shows the current file's moviehash. Run mpv
with `--msg-level=jamak=v` to see queries and result counts.

## License

[MIT](LICENSE)
