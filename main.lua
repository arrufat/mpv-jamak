-- jamak: subtitle downloader for mpv using the OpenSubtitles.com REST API.
--
-- Keys:  Ctrl+u  search, or reopen cached results
--        Ctrl+U  manual search: title prompt, then language picker
--
-- Credentials go in script-opts/jamak.conf (see jamak.conf.example).

local mp = require "mp"
local utils = require "mp.utils"
local msg = require "mp.msg"
local input = require "mp.input"

local o = {
    api_key = "",
    username = "",
    password = "",
    languages = "en,ko",
    auto = false,
    fallback_dir = "",
}
require("mp.options").read_options(o, "jamak")

local API = "https://api.opensubtitles.com/api/v1"
local UA = "jamak v0.1"
local TOKEN_MAX_AGE = 20 * 3600
local PLATFORM = mp.get_property_native("platform") or "linux"

-- ---------------------------------------------------------------- helpers

local function osd(text, dur)
    mp.osd_message("jamak: " .. text, dur or 3)
end

-- the API 301-redirects non-canonical URLs: spaces must be "+", not "%20"
local function urlencode(s)
    return (s:gsub("[^%w%-%._~ ]", function(c)
        return string.format("%%%02X", c:byte())
    end):gsub(" ", "+"))
end

local function first_line(s)
    return (s or ""):match("[^\n]+")
end

local function split_langs(s)
    local langs = {}
    for l in s:gmatch("[^,%s]+") do langs[#langs + 1] = l:lower() end
    return langs
end

local function read_json(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return utils.parse_json(s)
end

local function write_json(path, t)
    local f = io.open(path, "w")
    if not f then return end
    f:write(utils.format_json(t))
    f:close()
end

local function ensure_dir(dir)
    if not utils.file_info(dir) then
        -- cmd's mkdir has no -p but creates parents by default; it wants
        -- backslashes and errors harmlessly if the dir already exists
        local args = PLATFORM == "windows"
            and { "cmd", "/d", "/c", "mkdir", (dir:gsub("/", "\\")) }
            or { "mkdir", "-p", dir }
        mp.command_native({ name = "subprocess", args = args,
                            playback_only = false, capture_stderr = true })
    end
    return dir
end

local cache_dir_cached
local function cache_dir()
    if not cache_dir_cached then
        local dir = mp.command_native({ "expand-path", "~~cache/jamak" })
        if not dir or not dir:find("[/\\]") then
            -- under --no-config mpv has no cache dir and returns "jamak"
            dir = utils.join_path(os.getenv("XDG_CACHE_HOME")
                or os.getenv("LOCALAPPDATA") or os.getenv("TMPDIR") or "/tmp", "jamak")
        end
        cache_dir_cached = ensure_dir(dir)
    end
    return cache_dir_cached
end

local function cache_path(name)
    return utils.join_path(cache_dir(), name)
end

-- ------------------------------------------------------- coroutine plumbing

local function resume(co, ...)
    local ok, err = coroutine.resume(co, ...)
    if not ok then
        msg.error(debug.traceback(co, err))
        osd("internal error (see console)", 4)
    end
end

local function run(fn)
    resume(coroutine.create(fn))
end

-- await(fn): fn gets a callback; the coroutine suspends until it fires
local function await(fn)
    local co = coroutine.running()
    local early
    fn(function(...)
        if coroutine.status(co) == "suspended" then
            resume(co, ...)
        else
            early = { ... }
        end
    end)
    if early then return unpack(early) end
    return coroutine.yield()
end

-- returns the result table, or nil plus the first stderr line on failure
local function subprocess(args)
    local ok, res, err = await(function(cb)
        mp.command_native_async({ name = "subprocess", args = args,
                                  capture_stdout = true, capture_stderr = true,
                                  playback_only = false }, cb)
    end)
    if not ok or not res then return nil, err or "subprocess failed" end
    if res.status ~= 0 then
        return nil, first_line(res.stderr) or ("exit status " .. res.status)
    end
    return res
end

-- --------------------------------------------------------------- HTTP layer

-- params = {key = value}; keys are sorted and values encoded because the
-- API 301-redirects anything but its canonical URL form
local function api_url(path, params)
    local keys = {}
    for k in pairs(params or {}) do keys[#keys + 1] = k end
    if #keys == 0 then return API .. path end
    table.sort(keys)
    for i, k in ipairs(keys) do keys[i] = k .. "=" .. urlencode(tostring(params[k])) end
    return API .. path .. "?" .. table.concat(keys, "&")
end

-- req = {url, method?, token?, body?}  ->  {code, body (parsed)}, err
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
    if not res then return nil, "network error: " .. err end
    local body, code = res.stdout:match("^(.*)\n(%d+)%s*$")
    if not code then return nil, "unexpected curl output" end
    code = tonumber(code)
    if code == 429 then return nil, "rate limited by OpenSubtitles, retry in a minute" end
    return { code = code, body = body ~= "" and utils.parse_json(body) or nil }
end

local function api_error(what, resp)
    return what .. ": " .. ((resp.body and resp.body.message) or ("HTTP " .. resp.code))
end

-- ---------------------------------------------------------------- session

local session  -- {token, base, created}, mirrored in token.json

-- VIP accounts are told to use a different host in the login response
local function api_base(host)
    if not host or host == "" or host:find("api%.opensubtitles%.com") then return API end
    if not host:find("://") then host = "https://" .. host end
    return host .. "/api/v1"
end

local function cached_session()
    if not session then session = read_json(cache_path("token.json")) end
    if session and session.token and session.base
        and os.time() - (session.created or 0) < TOKEN_MAX_AGE then
        return session
    end
end

local function login()
    if o.username == "" or o.password == "" then
        return nil, "no credentials, fill in script-opts/jamak.conf"
    end
    local resp, err = api_request({
        method = "POST",
        url = api_url("/login"),
        body = utils.format_json({ username = o.username, password = o.password }),
    })
    if not resp then return nil, err end
    if resp.code == 401 then return nil, "bad credentials (check script-opts/jamak.conf)" end
    if resp.code ~= 200 or not resp.body or not resp.body.token then
        return nil, api_error("login failed", resp)
    end
    session = { token = resp.body.token, created = os.time(),
                base = api_base(resp.body.base_url) }
    write_json(cache_path("token.json"), session)
    return session
end

-- req = {path, method?, body?}; retries once with a fresh login on 401
local function authed_request(req)
    local s, err = cached_session()
    if not s then s, err = login() end
    for _ = 1, 2 do
        if not s then return nil, err end
        local resp
        resp, err = api_request({ method = req.method, url = s.base .. req.path,
                                  body = req.body, token = s.token })
        if not resp then return nil, err end
        if resp.code ~= 401 then return resp end
        s, err = login()
    end
    return nil, "authentication failed (401)"
end

-- ------------------------------------------------------------------- oshash
-- OpenSubtitles moviehash: filesize + first/last 64 KiB summed as LE u64
-- mod 2^64, in four 16-bit lanes (sums stay below 2^53; carries once at end)

local CHUNK = 65536

local function oshash(path)
    local f = io.open(path, "rb")
    if not f then return nil, "cannot open file" end
    local size = f:seek("end")
    if not size or size < 2 * CHUNK then
        f:close()
        return nil, "file too small for hash"
    end
    local a1, a2, a3, a4 = 0, 0, 0, 0
    for _, off in ipairs({ 0, size - CHUNK }) do
        f:seek("set", off)
        local chunk = f:read(CHUNK)
        if not chunk or #chunk < CHUNK then
            f:close()
            return nil, "read error"
        end
        for i = 1, CHUNK, 8 do
            local b1, b2, b3, b4, b5, b6, b7, b8 = chunk:byte(i, i + 7)
            a1 = a1 + b1 + b2 * 256
            a2 = a2 + b3 + b4 * 256
            a3 = a3 + b5 + b6 * 256
            a4 = a4 + b7 + b8 * 256
        end
    end
    f:close()
    a1 = a1 + size % 65536
    a2 = a2 + math.floor(size / 65536) % 65536
    a3 = a3 + math.floor(size / 2 ^ 32) % 65536
    a4 = a4 + math.floor(size / 2 ^ 48)
    a2 = a2 + math.floor(a1 / 65536)
    a3 = a3 + math.floor(a2 / 65536)
    a4 = a4 + math.floor(a3 / 65536)
    return string.format("%04x%04x%04x%04x",
        a4 % 65536, a3 % 65536, a2 % 65536, a1 % 65536)
end

-- -------------------------------------------------------------- title guess

local NOISE = {
    "%f[%w]%d%d%d+[pi]%f[%W]",                    -- 720p, 1080p, 480i
    "%f[%w][12][90]%d%d%f[%W]",                   -- year
    "%f[%w][Ww][Ee][Bb]%-?[Dd]?[Ll]?%f[%W]",
    "%f[%w][Bb][Ll][Uu]%-?[Rr][Aa][Yy]%f[%W]",
    "%f[%w][Bb][DdRr][Rr][Ii][Pp]%f[%W]",         -- BDRip, BRRip
    "%f[%w][Hh][Dd][Tt][Vv]%f[%W]",
    "%f[%w][XxHh]26[45]%f[%W]",
    "%f[%w][Hh][Ee][Vv][Cc]%f[%W]",
    "%f[%w][Aa][Aa][Cc]%f[%W]",
}

-- expects a name without file extension
local function guess_title(name)
    local t = name:gsub("[%._]+", " ")
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

-- "Show (S01E11) Episode Title" or "Title (Year)", nil when unknown
local function feature_label(fd)
    if not fd.title then return nil end
    if fd.feature_type == "Episode" and fd.parent_title then
        local s, e = tonumber(fd.season_number), tonumber(fd.episode_number)
        local code = s and e and string.format(" (S%02dE%02d)", s, e)
            or e and string.format(" (E%02d)", e) or ""
        return fd.parent_title .. code .. " " .. fd.title
    end
    return fd.title .. (fd.year and (" (" .. fd.year .. ")") or "")
end

local function search(hash, title, languages, vfps)
    local langs = split_langs(languages or o.languages)
    local prio = {}
    for i, l in ipairs(langs) do prio[l] = i end
    local sorted = { unpack(langs) }
    table.sort(sorted)

    local url = api_url("/subtitles", {
        languages = table.concat(sorted, ","),
        moviehash = hash or nil,
        query = title ~= "" and title:lower() or nil,
    })
    msg.verbose("GET " .. url)
    local resp, err = api_request({ url = url })
    if not resp then return nil, err end
    if resp.code ~= 200 or not resp.body or type(resp.body.data) ~= "table" then
        return nil, api_error("search failed", resp)
    end

    local cands = {}
    for _, item in ipairs(resp.body.data) do
        local a = item.attributes or {}
        local f = a.files and a.files[1]
        if f and f.file_id then
            local fd = a.feature_details or {}
            local fps = tonumber(a.fps)
            if fps and fps <= 0 then fps = nil end
            cands[#cands + 1] = {
                file_id = f.file_id,
                file_name = f.file_name or "",
                lang = (a.language or "?"):lower(),
                release = a.release or f.file_name or "?",
                dl = a.download_count or 0,
                hash_match = a.moviehash_match == true,
                hi = a.hearing_impaired == true,
                ai = a.ai_translated == true or a.machine_translated == true,
                fps = fps,
                video_fps = vfps,
                fps_mismatch = (vfps and fps and math.abs(fps - vfps) > 0.01) or false,
                feature_id = fd.feature_id,
                feature = feature_label(fd),
            }
        end
    end
    -- auto mode downloads the first of these that is a clean hash match
    table.sort(cands, function(x, y)
        if x.hash_match ~= y.hash_match then return x.hash_match end
        local px, py = prio[x.lang] or 99, prio[y.lang] or 99
        if px ~= py then return px < py end
        if x.ai ~= y.ai then return y.ai end
        if x.fps_mismatch ~= y.fps_mismatch then return y.fps_mismatch end
        return x.dl > y.dl
    end)
    msg.verbose(#cands .. " candidates")
    return cands
end

-- ------------------------------------------------------------ language list

local lang_list, lang_waiters

-- full language list from the API, cached in memory and on disk;
-- concurrent callers wait for the fetch already in flight
local function get_languages()
    if lang_list then return lang_list end
    if lang_waiters then
        lang_waiters[#lang_waiters + 1] = coroutine.running()
        coroutine.yield()
        return lang_list
    end
    lang_waiters = {}
    local path = cache_path("languages.json")
    local parsed = read_json(path)
    if type(parsed) ~= "table" or #parsed == 0 then
        local resp = api_request({ url = api_url("/infos/languages") })
        if resp and resp.code == 200 and resp.body and type(resp.body.data) == "table" then
            parsed = resp.body.data
            write_json(path, parsed)
        end
    end
    if type(parsed) == "table" and #parsed > 0 then
        table.sort(parsed, function(a, b)
            return (a.language_name or "") < (b.language_name or "")
        end)
        lang_list = parsed
    end
    local waiting = lang_waiters
    lang_waiters = nil
    for _, co in ipairs(waiting) do resume(co) end
    return lang_list
end

-- --------------------------------------------------------------------- UI

-- returns the chosen 1-based index, nil on cancel
local function choose(prompt, items)
    return await(function(cb)
        input.select({ prompt = prompt, items = items, submit = cb })
    end)
end

local function pick(cands)
    -- prefix the resolved feature only when results span more than one
    local seen, feature_count = {}, 0
    for _, c in ipairs(cands) do
        if c.feature_id and not seen[c.feature_id] then
            seen[c.feature_id] = true
            feature_count = feature_count + 1
        end
    end
    local items = {}
    for i, c in ipairs(cands) do
        local tags = (c.hash_match and "[HASH] " or "") .. "[" .. c.lang .. "]"
            .. (c.hi and " [HI]" or "") .. (c.ai and " [AI]" or "")
        local feature = feature_count > 1 and c.feature and (c.feature .. ": ") or ""
        local fps = ""
        if c.fps then
            fps = string.format(", %gfps", c.fps)
                .. (c.fps_mismatch and string.format(", video %g", c.video_fps) or "")
        end
        items[i] = string.format("%s %s%s (%d dl%s)", tags, feature, c.release, c.dl, fps)
        msg.debug(items[i])
    end
    local idx = choose("Subtitle:", items)
    return idx and cands[idx]
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

-- returns a languages string for search(), nil on cancel
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
    local idx = choose("Language:", items)
    return idx and codes[idx]
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
        osd("video dir not writable, saving elsewhere", 2)
    end
    if o.fallback_dir ~= "" then return ensure_dir(o.fallback_dir) end
    return ensure_dir(cache_path("subs"))
end

-- fetches and loads the subtitle; reports failures on the OSD
local function download(cand, video_path, remote)
    local resp, err = authed_request({
        method = "POST", path = "/download",
        body = utils.format_json({ file_id = cand.file_id }),
    })
    if not resp then
        osd(err, 5)
        return
    end
    local b = resp.body or {}
    if resp.code ~= 200 or not b.link then
        local m = api_error("download refused", resp)
        if b.reset_time then m = m .. " (quota resets " .. b.reset_time .. ")" end
        osd(m, 5)
        return
    end

    local dir = sub_dest_dir(video_path, remote)
    local base = (mp.get_property("filename/no-ext") or "sub"):gsub("/", "_")
    local ext = (b.file_name or cand.file_name):match("%.([^.]+)$") or "srt"
    local dest = utils.join_path(dir, string.format("%s.%s.%s", base, cand.lang, ext))

    local res, ferr = subprocess({ "curl", "-sSL", "--max-time", "60", "-o", dest, b.link })
    if not res then
        osd("fetch failed: " .. ferr, 5)
        return
    end

    mp.commandv("sub-add", dest, "select")
    local rem = b.remaining and (" (" .. b.remaining .. " downloads left today)") or ""
    osd("loaded " .. (b.file_name or dest) .. rem, 4)
end

-- ------------------------------------------------------------------- main

local state = {}  -- per video: path, hash (false = unhashable), candidates

local function abs_video_path()
    local path = mp.get_property("path")
    if not path then return nil end
    if path:find("^%a[%w+.-]*://") then return path, true end
    return utils.join_path(mp.get_property("working-directory") or "", path), false
end

local function default_title()
    return guess_title(mp.get_property("filename/no-ext")
        or mp.get_property("media-title") or "")
end

-- shared by manual and auto search; hash and non-empty results are cached
local function fetch_candidates(path, remote, title, languages)
    if state.path ~= path then state = { path = path } end
    if state.hash == nil and not remote then
        local h, herr = oshash(path)
        if not h then msg.verbose("oshash: " .. herr) end
        state.hash = h or false
    end
    local cands, err = search(state.hash, title or default_title(), languages,
        mp.get_property_native("container-fps"))
    if cands and #cands > 0 then state.candidates = cands end
    return cands, err
end

local function pick_and_download(cands, path, remote)
    local cand = pick(cands)
    if cand then download(cand, path, remote) end
end

local function main(manual)
    if o.api_key == "" then
        osd("no api_key, copy jamak.conf.example to script-opts/jamak.conf", 6)
        return
    end
    local path, remote = abs_video_path()
    if not path then
        osd("no file playing")
        return
    end

    if not manual and state.path == path and state.candidates then
        return pick_and_download(state.candidates, path, remote)
    end

    local title, languages
    if manual then
        run(get_languages)  -- warm the language list while the user types
        title = ask_title(default_title())
        if not title or title == "" then return end
        languages = ask_language()
        if not languages then return end
    end

    osd("searching…", 30)
    local cands, err = fetch_candidates(path, remote, title, languages)
    if not cands then
        osd(err, 5)
        return
    end
    if #cands == 0 then
        osd("no subtitles found", 4)
        return
    end
    osd(#cands .. " result" .. (#cands == 1 and "" or "s"), 1)
    pick_and_download(cands, path, remote)
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
        local cands, err = fetch_candidates(path, false)
        if not cands then
            msg.warn("auto: " .. err)
            return
        end
        if #cands == 0 then
            msg.verbose("auto: no results")
            return
        end
        -- spend quota only on a hash match whose fps doesn't conflict
        local best, conflicted
        for _, c in ipairs(cands) do
            if c.hash_match and not c.fps_mismatch then
                best = c
                break
            end
            conflicted = conflicted or c.hash_match
        end
        if best then
            download(best, path, false)
        elseif conflicted then
            osd("hash match has an fps mismatch, press Ctrl+u to pick", 4)
        else
            osd(#cands .. " subs available, press Ctrl+u to pick", 4)
        end
    end)
end)

mp.add_key_binding("Ctrl+u", "jamak-search", function()
    run(function() main(false) end)
end)
mp.add_key_binding("Ctrl+U", "jamak-search-manual", function()
    run(function() main(true) end)
end)

-- `script-message jamak-hash` logs the current file's moviehash
mp.register_script_message("jamak-hash", function()
    local path = abs_video_path()
    if not path then return end
    local h, err = oshash(path)
    msg.info("oshash(" .. path .. ") = " .. (h or ("nil (" .. err .. ")")))
    osd(h or err, 5)
end)
