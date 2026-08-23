# mpv-jamak

jamak (자막, Korean for "subtitles") is an interactive subtitle downloader
for [mpv](https://mpv.io), written in plain Lua with `curl` as its only
dependency. It searches [OpenSubtitles.com](https://www.opensubtitles.com)
and shows ranked results in mpv's console UI, drawn over the video.

## Features

* No dependencies beyond `curl`. Single Lua file, nothing to install.
* You pick the subtitle. Instead of blindly loading the top match, jamak
  shows a fuzzy-filterable list (like mpv's built-in `g-s` track selector)
  with language, release name and download count. Wrong pick? Reopen the
  list and pick another; results are cached, so there is no second query.
* Exact matching via moviehash. The OpenSubtitles 64-bit file hash is
  computed in Lua, so subtitles that match your exact file rank first,
  tagged `[HASH]`.
* Quota-aware auto mode (optional). On file load, files with no subtitle
  track get an automatic download only when an exact hash match exists.
  A free OpenSubtitles account has 10 downloads per day, and jamak never
  spends one on a guess.
* Async everywhere. Network calls never block playback.

## Requirements

* mpv 0.39 or newer (uses the `mp.input` console API)
* `curl`
* optional: [subliminal](https://github.com/Diaoul/subliminal), used as a
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

The directory name (`jamak`) is the script name. Keep it, or your
`script-opts` file won't be found.

## Configuration

1. Create a free account at [opensubtitles.com](https://www.opensubtitles.com).
2. Register an API consumer at
   [opensubtitles.com/consumers](https://www.opensubtitles.com/consumers)
   to get an API key.
3. Copy [`jamak.conf.example`](jamak.conf.example) to
   `~/.config/mpv/script-opts/jamak.conf` and fill in the key and your
   account credentials.

Note that credentials are stored in plain text, since mpv has no secret
store. Keep `jamak.conf` out of any public dotfiles repo.

Recommended `mpv.conf` settings, so previously downloaded subtitles
auto-load on replay:

```ini
sub-auto=fuzzy
slang=en,eng
```

## Usage

| Key | Action |
|---|---|
| `Ctrl+u` | Search using moviehash and guessed title, then pick from the list. Press again to reopen cached results. |
| `Ctrl+U` | Manual search: edit the title (pre-filled), choose a language from the full list, then pick. |

Both are rebindable in `input.conf` via
`script-binding jamak/jamak-search` and
`script-binding jamak/jamak-search-manual`.

Results are ranked by exact hash match, then your configured language
priority, then download count. Downloads land next to the video as
`<video>.<lang>.srt` (or in `fallback_dir` if the directory isn't
writable) and are selected immediately.

### Auto mode

With `auto=yes` in `jamak.conf`, whenever a file with no subtitle track
loads, jamak searches in the background:

* exact hash match: downloads and selects it, hands-free
* title matches only: shows a brief "N subs available" hint and caches
  the results, spending no quota

Files that already have subtitles (embedded, or a sibling `.srt` picked up
by `sub-auto=fuzzy`) are skipped entirely, so each file triggers at most
one download.

### Debugging

`script-message jamak-hash` shows the current file's moviehash. Run mpv
with `--msg-level=jamak=v` to see queries and result counts.

## License

[MIT](LICENSE)
