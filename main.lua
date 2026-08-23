-- jamak — subtitle downloader for mpv using the OpenSubtitles.com REST API.
-- Pure Lua + curl; optional subliminal fallback when the API finds nothing.
--
-- Keys:  Ctrl+u  search (re-press to re-show results without re-querying)
--        Ctrl+U  manual search: editable title prompt, then language picker
--                (drops cached results)
--
-- Credentials go in script-opts/jamak.conf (see jamak.conf.example).
-- Optional auto mode (auto=yes): on file load, files with no subtitle track
-- get an automatic download when a moviehash match exists.

local mp = require "mp"
local utils = require "mp.utils"
local msg = require "mp.msg"
local input = require "mp.input"

local o = {
    api_key = "",
    username = "",
    password = "",
    -- comma-separated, priority order (2-letter codes)
    languages = "en",
    -- on file load, if the file has no subtitle track: auto-download when
    -- there is an exact moviehash match, otherwise just hint that results exist
    auto = false,
    -- run subliminal when the API returns zero results
    subliminal_fallback = true,
    -- where to save subs when the video dir is unwritable (empty = cache dir)
    fallback_dir = "",
}
require("mp.options").read_options(o, "jamak")

local API = "https://api.opensubtitles.com/api/v1"
local UA = "jamak v0.1"
local TOKEN_MAX_AGE = 20 * 3600

local lang_prio = {}
do
    local i = 0
    for l in o.languages:gmatch("[^,%s]+") do
        i = i + 1
        lang_prio[l:lower()] = i
    end
end

-- ---------------------------------------------------------------- helpers

local function osd(text, dur)
    mp.osd_message("jamak: " .. text, dur or 3)
end

-- the API 301s non-canonical URLs: spaces must be "+", not "%20"
local function urlencode(s)
    return (s:gsub("[^%w%-%._~ ]", function(c)
        return string.format("%%%02X", c:byte())
    end):gsub(" ", "+"))
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function write_file(path, s)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(s)
    f:close()
    return true
end

local cache_dir_made = false
local function cache_dir()
    local base = os.getenv("XDG_CACHE_HOME")
        or utils.join_path(os.getenv("HOME") or "/tmp", ".cache")
    local dir = utils.join_path(base, "jamak")
    if not cache_dir_made then
        mp.command_native({ name = "subprocess", args = { "mkdir", "-p", utils.join_path(dir, "subs") },
                            playback_only = false })
        cache_dir_made = true
    end
    return dir
end

-- ------------------------------------------------------- coroutine plumbing
-- Async calls read linearly: `local res = await(fn, ...)` where fn takes a
-- final callback argument. Callbacks fire on mpv's main event loop.

local function run(fn)
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co)
    if not ok then
        msg.error(debug.traceback(co, err))
        osd("internal error (see console)", 4)
    end
end

local function await(fn, ...)
    local co = coroutine.running()
    local early
    local args = { ... }
    args[#args + 1] = function(...)
        if coroutine.status(co) == "suspended" then
            local ok, err = coroutine.resume(co, ...)
            if not ok then
                msg.error(debug.traceback(co, err))
                osd("internal error (see console)", 4)
            end
        else
            early = { ... }
        end
    end
    fn(unpack(args))
    if early then return unpack(early) end
    return coroutine.yield()
end

local function subprocess(args)
    local ok, res, err = await(function(cb)
        mp.command_native_async({ name = "subprocess", args = args,
                                  capture_stdout = true, capture_stderr = true,
                                  playback_only = false }, cb)
    end)
    if not ok or not res then return nil, err or "subprocess failed" end
    return res
end

-- --------------------------------------------------------------- HTTP layer

-- req = {url, method?, token?, body?}  ->  {code, body (parsed), raw}, err
local function api_request(req)
    local args = { "curl", "-sS", "--compressed", "--max-time", "15",
                   "-w", "\n%{http_code}" }
    if req.method and req.method ~= "GET" then
        args[#args + 1] = "-X"
        args[#args + 1] = req.method
    else
        args[#args + 1] = "-L"
    end
    args[#args + 1] = req.url
    local headers = {
        "Api-Key: " .. o.api_key,
        "User-Agent: " .. UA,
        "Accept: application/json",
    }
    if req.token then headers[#headers + 1] = "Authorization: Bearer " .. req.token end
    if req.body then headers[#headers + 1] = "Content-Type: application/json" end
    for _, h in ipairs(headers) do
        args[#args + 1] = "-H"
        args[#args + 1] = h
    end
    if req.body then
        args[#args + 1] = "-d"
        args[#args + 1] = req.body
    end

    local res, err = subprocess(args)
    if not res then return nil, err end
    if res.status ~= 0 then
        local detail = (res.stderr or ""):match("[^\n]+") or ("curl exit " .. res.status)
        return nil, "network error: " .. detail
    end
    local body, code = res.stdout:match("^(.*)\n(%d+)%s*$")
    if not code then return nil, "unexpected curl output" end
    return { code = tonumber(code),
             body = body ~= "" and utils.parse_json(body) or nil,
             raw = body }
end

-- ------------------------------------------------------------ token manager

local token_cache

local function token_path()
    return utils.join_path(cache_dir(), "token.json")
end

local function get_token(force)
    if not force then
        if not token_cache then
            local raw = read_file(token_path())
            token_cache = raw and utils.parse_json(raw) or nil
        end
        if token_cache and token_cache.token
            and os.time() - (token_cache.created or 0) < TOKEN_MAX_AGE then
            return token_cache.token
        end
    end
    if o.username == "" or o.password == "" then
        return nil, "no credentials — fill in script-opts/jamak.conf"
    end
    local resp, err = api_request({
        method = "POST",
        url = API .. "/login",
        body = utils.format_json({ username = o.username, password = o.password }),
    })
    if not resp then return nil, err end
    if resp.code == 401 then return nil, "bad credentials (check script-opts/jamak.conf)" end
    if resp.code == 429 then return nil, "rate limited by OpenSubtitles, try again in a minute" end
    if resp.code ~= 200 or not resp.body or not resp.body.token then
        return nil, "login failed (HTTP " .. resp.code .. ")"
    end
    token_cache = { token = resp.body.token, created = os.time(),
                    base_url = resp.body.base_url }
    write_file(token_path(), utils.format_json(token_cache))
    return token_cache.token
end

-- VIP accounts are told to use a different host in the login response
local function download_base()
    local b = token_cache and token_cache.base_url
    if b and b ~= "" and not b:find("api%.opensubtitles%.com") then
        if not b:find("://") then b = "https://" .. b end
        return b .. "/api/v1"
    end
    return API
end

-- ------------------------------------------------------------------- oshash
-- filesize + first/last 64 KiB summed as little-endian u64 mod 2^64,
-- done in four 16-bit lanes so everything stays well inside double precision.

local CHUNK = 65536

local function add64_bytes(acc, chunk, pos)
    local b1, b2, b3, b4, b5, b6, b7, b8 = chunk:byte(pos, pos + 7)
    local w = { b1 + b2 * 256, b3 + b4 * 256, b5 + b6 * 256, b7 + b8 * 256 }
    local c = 0
    for i = 1, 4 do
        local s = acc[i] + w[i] + c
        acc[i] = s % 65536
        c = math.floor(s / 65536)
    end
end

local function add64_number(acc, n)
    local c = 0
    for i = 1, 4 do
        local s = acc[i] + n % 65536 + c
        n = math.floor(n / 65536)
        acc[i] = s % 65536
        c = math.floor(s / 65536)
    end
end

local function oshash(path)
    local f = io.open(path, "rb")
    if not f then return nil, "cannot open file" end
    local size = f:seek("end")
    if not size or size < 2 * CHUNK then
        f:close()
        return nil, "file too small for hash"
    end
    local acc = { 0, 0, 0, 0 }
    add64_number(acc, size)
    for _, off in ipairs({ 0, size - CHUNK }) do
        f:seek("set", off)
        local chunk = f:read(CHUNK)
        if not chunk or #chunk < CHUNK then
            f:close()
            return nil, "read error"
        end
        for i = 1, CHUNK, 8 do
            add64_bytes(acc, chunk, i)
        end
    end
    f:close()
    return string.format("%04x%04x%04x%04x", acc[4], acc[3], acc[2], acc[1])
end

-- -------------------------------------------------------------- title guess

local NOISE = {
    "%f[%w]%d%d%d+[pi]%f[%W]",                    -- 720p 1080p 2160p 480i
    "%f[%w][12][90]%d%d%f[%W]",                   -- year
    "%f[%w][Ww][Ee][Bb]%-?[Dd]?[Ll]?%f[%W]",
    "%f[%w][Bb][Ll][Uu]%-?[Rr][Aa][Yy]%f[%W]",
    "%f[%w][Bb][DdRr][Rr][Ii][Pp]%f[%W]",         -- BDRip / BRRip
    "%f[%w][Hh][Dd][Tt][Vv]%f[%W]",
    "%f[%w][XxHh]26[45]%f[%W]",
    "%f[%w][Hh][Ee][Vv][Cc]%f[%W]",
    "%f[%w][Aa][Aa][Cc]%f[%W]",
}

local function guess_title(name)
    local t = name:gsub("%.[^.]*$", ""):gsub("[%._]+", " ")
    local cut = #t + 1
    for _, pat in ipairs(NOISE) do
        local pos = t:find(pat)
        if pos and pos > 1 and pos < cut then cut = pos end
    end
    t = t:sub(1, cut - 1)
    t = t:gsub("[%[%(].-[%]%)]", " ")
    t = t:gsub("%s+", " "):gsub("^%s+", ""):gsub("[%s%-]+$", "")
    return t
end

-- ---------------------------------------------------------- search & ranking

local function search(hash, title, languages)
    local langs = {}
    for l in (languages or o.languages):gmatch("[^,%s]+") do langs[#langs + 1] = l:lower() end
    table.sort(langs)
    -- only non-default params: the API 301s away order_by=download_count etc.
    local params = {
        "languages=" .. urlencode(table.concat(langs, ",")),
    }
    if hash then params[#params + 1] = "moviehash=" .. hash end
    if title and title ~= "" then params[#params + 1] = "query=" .. urlencode(title:lower()) end
    table.sort(params)

    local url = API .. "/subtitles?" .. table.concat(params, "&")
    msg.verbose("GET " .. url)
    local resp, err = api_request({ url = url })
    if not resp then return nil, err end
    if resp.code == 429 then return nil, "rate limited, wait a moment and retry" end
    if resp.code ~= 200 or not resp.body or type(resp.body.data) ~= "table" then
        local m = resp.body and resp.body.message
        return nil, "search failed: " .. (m or ("HTTP " .. resp.code))
    end

    local cands = {}
    for _, item in ipairs(resp.body.data) do
        local a = item.attributes or {}
        local f = a.files and a.files[1]
        if f and f.file_id then
            cands[#cands + 1] = {
                file_id = f.file_id,
                file_name = f.file_name or "",
                lang = (a.language or "?"):lower(),
                release = a.release or f.file_name or "?",
                dl = a.download_count or 0,
                hash_match = a.moviehash_match == true,
            }
        end
    end
    table.sort(cands, function(x, y)
        if x.hash_match ~= y.hash_match then return x.hash_match end
        local px = lang_prio[x.lang] or 99
        local py = lang_prio[y.lang] or 99
        if px ~= py then return px < py end
        return x.dl > y.dl
    end)
    msg.verbose(#cands .. " candidates")
    return cands
end

-- ------------------------------------------------------------ language list

local lang_list

-- full language list from the API, cached in memory and on disk (it never
-- really changes); nil if the API is unreachable and no cache exists
local function get_languages()
    if lang_list then return lang_list end
    local path = utils.join_path(cache_dir(), "languages.json")
    local raw = read_file(path)
    local parsed = raw and utils.parse_json(raw) or nil
    if type(parsed) ~= "table" or #parsed == 0 then
        local resp = api_request({ url = API .. "/infos/languages" })
        if resp and resp.code == 200 and resp.body and type(resp.body.data) == "table" then
            parsed = resp.body.data
            write_file(path, utils.format_json(parsed))
        end
    end
    if type(parsed) ~= "table" or #parsed == 0 then return nil end
    table.sort(parsed, function(a, b)
        return (a.language_name or "") < (b.language_name or "")
    end)
    lang_list = parsed
    return lang_list
end

-- --------------------------------------------------------------------- UI

local function pick(cands)
    local items = {}
    for i, c in ipairs(cands) do
        items[i] = string.format("%s[%s] %s (%d dl)",
            c.hash_match and "[HASH] " or "", c.lang, c.release, c.dl)
    end
    local idx = await(function(cb)
        input.select({ prompt = "Subtitle:", items = items, submit = cb })
    end)
    return idx and cands[idx] or nil
end

local function ask_title(default)
    return await(function(cb)
        local done = false
        input.get({
            prompt = "Search subtitles:",
            default_text = default,
            submit = function(text)
                done = true
                input.terminate()
                cb(text)
            end,
            closed = function()
                if not done then cb(nil) end
            end,
        })
    end)
end

-- language picker: configured default first, then every API language
-- (type to fuzzy-filter). Returns a languages string for search(), nil = cancel.
local function ask_language()
    local items = { "configured (" .. o.languages .. ")" }
    local codes = { o.languages }
    for _, l in ipairs(get_languages() or {}) do
        local code = (l.language_code or ""):lower()
        if code ~= "" then
            items[#items + 1] = string.format("%s  [%s]", l.language_name or code, code)
            codes[#codes + 1] = code
        end
    end
    local idx = await(function(cb)
        input.select({ prompt = "Language:", items = items, submit = cb })
    end)
    return idx and codes[idx] or nil
end

-- ---------------------------------------------------------------- download

local function writable(dir)
    local probe = utils.join_path(dir, ".jamak-probe")
    local f = io.open(probe, "w")
    if not f then return false end
    f:close()
    os.remove(probe)
    return true
end

local function sub_dest_dir(video_path, remote)
    if not remote then
        local dir = utils.split_path(video_path)
        if writable(dir) then return dir end
        osd("video dir not writable — saving elsewhere", 2)
    end
    if o.fallback_dir ~= "" then return o.fallback_dir end
    return utils.join_path(cache_dir(), "subs")
end

local function download(cand, video_path, remote)
    local token, terr = get_token(false)
    if not token then return terr end

    local body = utils.format_json({ file_id = cand.file_id })
    local resp, err = api_request({ method = "POST", url = download_base() .. "/download",
                                    token = token, body = body })
    if not resp then return err end
    if resp.code == 401 then
        token, terr = get_token(true)
        if not token then return terr end
        resp, err = api_request({ method = "POST", url = download_base() .. "/download",
                                  token = token, body = body })
        if not resp then return err end
    end
    if resp.code == 429 then return "rate limited, wait a moment and retry" end
    local b = resp.body or {}
    if resp.code ~= 200 or not b.link then
        local m = b.message or ("HTTP " .. resp.code)
        if b.reset_time then m = m .. " (quota resets " .. b.reset_time .. ")" end
        return "download refused: " .. m
    end

    local dir = sub_dest_dir(video_path, remote)
    local base = (mp.get_property("filename/no-ext") or "sub"):gsub("/", "_")
    local ext = (b.file_name or cand.file_name):match("%.([^.]+)$") or "srt"
    local dest = utils.join_path(dir, string.format("%s.%s.%s", base, cand.lang, ext))

    local res, ferr = subprocess({ "curl", "-sSL", "--max-time", "60", "-o", dest, b.link })
    if not res or res.status ~= 0 then
        return "fetch failed: " .. (ferr or (res.stderr or ""):match("[^\n]+") or "?")
    end

    mp.commandv("sub-add", dest, "select")
    local rem = b.remaining and (" — " .. b.remaining .. " downloads left today") or ""
    osd("loaded " .. (b.file_name or dest) .. rem, 4)
    return nil
end

-- ------------------------------------------------------- subliminal fallback
-- Self-contained; delete this function (and its call site + the
-- subliminal_fallback option) to drop the dependency entirely.

local SUB_EXT = { srt = true, ass = true, ssa = true, sub = true, vtt = true }

local function subliminal_fb(video_path, remote)
    if remote then
        osd("no subtitles found", 4)
        return
    end
    osd("no API results — trying subliminal…", 30)
    local dir = sub_dest_dir(video_path, remote)
    local before = {}
    for _, fn in ipairs(utils.readdir(dir, "files") or {}) do before[fn] = true end

    local args = { "subliminal", "download", "-d", dir }
    for l in o.languages:gmatch("[^,%s]+") do
        args[#args + 1] = "-l"
        args[#args + 1] = l
    end
    args[#args + 1] = video_path

    local res, err = subprocess(args)
    if not res or res.status ~= 0 then
        msg.warn(res and res.stderr or err or "")
        osd("subliminal failed (see console)", 5)
        return
    end

    local added = 0
    for _, fn in ipairs(utils.readdir(dir, "files") or {}) do
        if not before[fn] and SUB_EXT[fn:match("%.([^.]+)$") or ""] then
            mp.commandv("sub-add", utils.join_path(dir, fn), added == 0 and "select" or "auto")
            added = added + 1
        end
    end
    if added > 0 then
        osd("loaded " .. added .. " subtitle(s) via subliminal", 4)
    else
        osd("no subtitles found (API + subliminal)", 4)
    end
end

-- ------------------------------------------------------------------- main

local state = { path = nil, candidates = nil }
mp.register_event("start-file", function()
    state.path, state.candidates = nil, nil
end)

local function abs_video_path()
    local path = mp.get_property("path")
    if not path then return nil end
    if path:find("^%a[%w+.-]*://") then return path, true end
    return utils.join_path(mp.get_property("working-directory") or "", path), false
end

local function main(manual)
    if o.api_key == "" then
        osd("no api_key — copy script-opts/jamak.conf.example to jamak.conf and fill it in", 6)
        return
    end
    local path, remote = abs_video_path()
    if not path then
        osd("no file playing")
        return
    end

    local cands
    if not manual and state.path == path and state.candidates then
        cands = state.candidates
    else
        local title = guess_title(mp.get_property("filename") or mp.get_property("media-title") or "")
        local languages
        if manual then
            title = ask_title(title)
            if not title or title == "" then return end
            languages = ask_language()
            if not languages then return end
        end
        local hash
        if not remote then
            local herr
            hash, herr = oshash(path)
            if not hash then msg.verbose("oshash: " .. herr) end
        end
        osd("searching…", 30)
        local err
        cands, err = search(hash, title, languages)
        if not cands then
            osd(err, 5)
            return
        end
        if #cands == 0 then
            if o.subliminal_fallback then return subliminal_fb(path, remote) end
            osd("no subtitles found", 4)
            return
        end
        state.path, state.candidates = path, cands
        osd(#cands .. " result" .. (#cands == 1 and "" or "s"), 1)
    end

    local cand = pick(cands)
    if not cand then return end
    local err = download(cand, path, remote)
    if err then osd(err, 5) end
end

-- ---------------------------------------------------------------- auto mode

local function has_sub_track()
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == "sub" then return true end
    end
    return false
end

mp.register_event("file-loaded", function()
    if not o.auto or o.api_key == "" then return end
    run(function()
        local path, remote = abs_video_path()
        if not path or remote or has_sub_track() then return end
        local title = guess_title(mp.get_property("filename") or "")
        local hash = oshash(path)
        local cands, err = search(hash, title)
        if not cands then
            msg.warn("auto: " .. err)
            return
        end
        if #cands == 0 then
            msg.verbose("auto: no results")
            return
        end
        state.path, state.candidates = path, cands
        if hash and cands[1].hash_match then
            local derr = download(cands[1], path, remote)
            if derr then osd(derr, 5) end
        else
            osd(#cands .. " subs available — Ctrl+u to pick", 4)
        end
    end)
end)

mp.add_key_binding("Ctrl+u", "jamak-search", function()
    run(function() main(false) end)
end)
mp.add_key_binding("Ctrl+U", "jamak-search-manual", function()
    run(function() main(true) end)
end)

-- debug helper: `script-message jamak-hash` logs the current file's oshash
mp.register_script_message("jamak-hash", function()
    local path = abs_video_path()
    if not path then return end
    local h, err = oshash(path)
    msg.info("oshash(" .. path .. ") = " .. (h or ("nil (" .. err .. ")")))
    osd(h or err, 5)
end)
