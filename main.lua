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

local ensured_dirs = {}
local function ensure_dir(dir)
    if not ensured_dirs[dir] then
        -- cmd's mkdir has no -p but creates parents by default; it wants
        -- backslashes and errors harmlessly if the dir already exists
        local args = PLATFORM == "windows"
            and { "cmd", "/d", "/c", "mkdir", (dir:gsub("/", "\\")) }
            or { "mkdir", "-p", dir }
        mp.command_native({ name = "subprocess", args = args,
                            playback_only = false, capture_stderr = true })
        ensured_dirs[dir] = true
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

-- params must be sorted or the API 301-redirects to its canonical URL form
local function api_url(path, params)
    if not params or #params == 0 then return API .. path end
    table.sort(params)
    return API .. path .. "?" .. table.concat(params, "&")
end

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
        return nil, "network error: "
            .. (first_line(res.stderr) or ("curl exit " .. res.status))
    end
    local body, code = res.stdout:match("^(.*)\n(%d+)%s*$")
    if not code then return nil, "unexpected curl output" end
    code = tonumber(code)
    if code == 429 then return nil, "rate limited by OpenSubtitles, retry in a minute" end
    return { code = code,
             body = body ~= "" and utils.parse_json(body) or nil,
             raw = body }
end

local function api_error(what, resp)
    return what .. ": " .. ((resp.body and resp.body.message) or ("HTTP " .. resp.code))
end

-- ------------------------------------------------------------ token manager

local token_cache

local function get_token(force)
    if not force then
        if not token_cache then
            token_cache = utils.parse_json(read_file(utils.join_path(cache_dir(), "token.json")) or "")
        end
        if token_cache and token_cache.token
            and os.time() - (token_cache.created or 0) < TOKEN_MAX_AGE then
            return token_cache.token
        end
    end
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
    token_cache = { token = resp.body.token, created = os.time(),
                    base_url = resp.body.base_url }
    write_file(utils.join_path(cache_dir(), "token.json"), utils.format_json(token_cache))
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

-- retries once with a fresh token on 401
local function authed_request(build)
    for _, force in ipairs({ false, true }) do
        local token, terr = get_token(force)
        if not token then return nil, terr end
        local req = build()
        req.token = token
        local resp, err = api_request(req)
        if not resp then return nil, err end
        if resp.code ~= 401 then return resp end
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

local function search(hash, title, languages)
    local langs = split_langs(languages or o.languages)
    local prio = {}
    for i, l in ipairs(langs) do prio[l] = i end
    local sorted = { unpack(langs) }
    table.sort(sorted)

    local params = { "languages=" .. urlencode(table.concat(sorted, ",")) }
    if hash then params[#params + 1] = "moviehash=" .. hash end
    if title and title ~= "" then params[#params + 1] = "query=" .. urlencode(title:lower()) end
    local url = api_url("/subtitles", params)
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
            cands[#cands + 1] = {
                file_id = f.file_id,
                file_name = f.file_name or "",
                lang = (a.language or "?"):lower(),
                release = a.release or f.file_name or "?",
                dl = a.download_count or 0,
                hash_match = a.moviehash_match == true,
                hi = a.hearing_impaired == true,
                ai = a.ai_translated == true or a.machine_translated == true,
                fps = fps and fps > 0 and fps or nil,
                feature_id = fd.feature_id,
                feature_title = fd.title,
                feature_year = fd.year,
            }
        end
    end
    table.sort(cands, function(x, y)
        if x.hash_match ~= y.hash_match then return x.hash_match end
        local px, py = prio[x.lang] or 99, prio[y.lang] or 99
        if px ~= py then return px < py end
        if x.ai ~= y.ai then return y.ai end
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
    local path = utils.join_path(cache_dir(), "languages.json")
    local parsed = utils.parse_json(read_file(path) or "")
    if type(parsed) ~= "table" or #parsed == 0 then
        local resp = api_request({ url = api_url("/infos/languages") })
        if resp and resp.code == 200 and resp.body and type(resp.body.data) == "table" then
            parsed = resp.body.data
            write_file(path, utils.format_json(parsed))
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
        local feature = ""
        if feature_count > 1 and c.feature_title then
            feature = c.feature_title
                .. (c.feature_year and (" (" .. c.feature_year .. ")") or "") .. ": "
        end
        local fps = c.fps and string.format(", %gfps", c.fps) or ""
        items[i] = string.format("%s %s%s (%d dl%s)", tags, feature, c.release, c.dl, fps)
        msg.debug(items[i])
    end
    local idx = await(function(cb)
        input.select({ prompt = "Subtitle:", items = items, submit = cb })
    end)
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
    local idx = await(function(cb)
        input.select({ prompt = "Language:", items = items, submit = cb })
    end)
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
    return ensure_dir(utils.join_path(cache_dir(), "subs"))
end

local function download(cand, video_path, remote)
    local body = utils.format_json({ file_id = cand.file_id })
    local resp, err = authed_request(function()
        return { method = "POST", url = download_base() .. "/download", body = body }
    end)
    if not resp then return err end
    local b = resp.body or {}
    if resp.code ~= 200 or not b.link then
        local m = api_error("download refused", resp)
        if b.reset_time then m = m .. " (quota resets " .. b.reset_time .. ")" end
        return m
    end

    local dir = sub_dest_dir(video_path, remote)
    local base = (mp.get_property("filename/no-ext") or "sub"):gsub("/", "_")
    local ext = (b.file_name or cand.file_name):match("%.([^.]+)$") or "srt"
    local dest = utils.join_path(dir, string.format("%s.%s.%s", base, cand.lang, ext))

    local res, ferr = subprocess({ "curl", "-sSL", "--max-time", "60", "-o", dest, b.link })
    if not res or res.status ~= 0 then
        return "fetch failed: " .. (ferr or first_line(res and res.stderr) or "?")
    end

    mp.commandv("sub-add", dest, "select")
    local rem = b.remaining and (" (" .. b.remaining .. " downloads left today)") or ""
    osd("loaded " .. (b.file_name or dest) .. rem, 4)
    return nil
end

-- ------------------------------------------------------------------- main

local state = { path = nil, hash = nil, candidates = nil }
mp.register_event("start-file", function()
    state.path, state.hash, state.candidates = nil, nil, nil
end)

local function abs_video_path()
    local path = mp.get_property("path")
    if not path then return nil end
    if path:find("^%a[%w+.-]*://") then return path, true end
    return utils.join_path(mp.get_property("working-directory") or "", path), false
end

-- shared by manual and auto search; hash and non-empty results are cached
local function fetch_candidates(path, remote, title, languages)
    if state.path ~= path then
        state.path, state.hash, state.candidates = path, nil, nil
    end
    if state.hash == nil and not remote then
        local h, herr = oshash(path)
        if not h then msg.verbose("oshash: " .. herr) end
        state.hash = h or false
    end
    local cands, err = search(state.hash or nil, title, languages)
    if cands and #cands > 0 then state.candidates = cands end
    return cands, err
end

local function pick_and_download(cands, path, remote)
    local cand = pick(cands)
    if not cand then return end
    local err = download(cand, path, remote)
    if err then osd(err, 5) end
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

    local title = guess_title(mp.get_property("filename/no-ext")
        or mp.get_property("media-title") or "")
    local languages
    if manual then
        run(get_languages)  -- warm the language list while the user types
        title = ask_title(title)
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
        local title = guess_title(mp.get_property("filename/no-ext") or "")
        local cands, err = fetch_candidates(path, false, title)
        if not cands then
            msg.warn("auto: " .. err)
            return
        end
        if #cands == 0 then
            msg.verbose("auto: no results")
            return
        end
        if cands[1].hash_match then
            local derr = download(cands[1], path, false)
            if derr then osd(derr, 5) end
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
