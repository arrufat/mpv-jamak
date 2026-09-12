# mpv-jamak

jamak (자막, Korean for "subtitles") is an interactive subtitle downloader
for [mpv](https://mpv.io): plain Lua, `curl` as the only dependency, backed
by [OpenSubtitles.com](https://www.opensubtitles.com). Needs mpv 0.39+.

![jamak's subtitle picker over Sintel](https://github.com/arrufat/mpv-jamak/releases/download/0.3.1/screenshot.jpg)

## Features

* Fuzzy-filterable picker in mpv's console UI (same look as the built-in
  `g-s` selector) instead of a blindly loaded top match. Results are
  cached: a wrong pick costs a reopen, not a re-query.
* Moviehash matching, computed in Lua: subs for your exact file rank
  first, tagged `[HASH]`, with frame-rate cross-checks against the video.
* Optional quota-aware auto mode that never spends a download on a guess
  (a free account gets 10 per day).
* Async everywhere: network calls never block playback.

## Installation

```sh
git clone https://github.com/arrufat/mpv-jamak ~/.config/mpv/scripts/jamak
```

or as a dotfiles submodule. Keep the directory name `jamak`, or your
`script-opts` file won't be found.

## Configuration

1. Create a free [opensubtitles.com](https://www.opensubtitles.com) account
   and register an API consumer at
   [opensubtitles.com/consumers](https://www.opensubtitles.com/consumers).
2. Copy [`jamak.conf.example`](jamak.conf.example) to
   `~/.config/mpv/script-opts/jamak.conf` and fill in the key and your
   credentials. They are stored in plain text; keep the file out of public
   dotfiles.

Recommended in `mpv.conf`, so downloaded subtitles auto-load on replay:

```ini
sub-auto=fuzzy
slang=en,eng,ko,kor
```

## Usage

| Key | Action |
|---|---|
| `Ctrl+u` | Search by moviehash + guessed title, pick from the list. Press again to reopen cached results. |
| `Ctrl+U` | Manual search: edit the title, choose a language, pick. |

Rebindable via `script-binding jamak/jamak-search` and
`.../jamak-search-manual`.

Ranking: hash match, language priority, human before AI-translated
(`[AI]`), matching frame rate, regular before hearing-impaired (`[HI]`,
flip with `prefer_hi=yes`), download count. A hash match that contradicts
the file name's episode code or the other hash matches is tagged `[HASH?]`
and ranks below trusted ones. Rows show downloads and fps, with the
video's fps appended on a mismatch. Downloads land next to the video as
`<video>.<lang>.srt` (or in `fallback_dir`) and load immediately.

With `auto=yes`, a video without subtitle tracks gets a hands-free
download when a trusted hash match exists; otherwise jamak only hints
that results are available. Audio files and images are skipped.

Debugging: `script-message jamak-hash` prints the file's moviehash;
`--msg-level=jamak=v` logs queries and result counts.

## License

[MIT](LICENSE)
