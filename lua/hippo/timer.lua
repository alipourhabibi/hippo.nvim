-- Time tracking. The activities, the running timer and the log all live in one
-- note, so they survive a restart and the phone can read them too:
--
--   ## Activities
--   - acme 30$/h
--   ## Running
--   - acme since 2026-10-29 09:10: fixing the login bug
--   ## Log
--   | date | start | end | time | activity | what |
local vault = require("hippo.vault")

local M = {}

local function cfg()
    return require("hippo").config.timer
end

function M.note()
    return vault.file(cfg().note)
end

local function skeleton()
    return {
        "---",
        "created: " .. vault.date(0),
        "tags: [time]",
        "---",
        "# timings",
        "",
        "## Activities",
        "",
        "## Running",
        "",
        "## Log",
        "",
        "| date | start | end | time | activity | what |",
        "|---|---|---|---|---|---|",
    }
end

function M.format(mins)
    local h, m = math.floor(mins / 60), mins % 60
    if h == 0 then
        return m .. "m"
    end
    return h .. "h" .. (m > 0 and (m .. "m") or "")
end

-- time is "HH:MM" or "HH:MM:SS"
local function epoch(date, time)
    local y, mo, d = date:match("(%d+)-(%d+)-(%d+)")
    local h, mi, s = time:match("(%d+):(%d+):?(%d*)")
    return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = tonumber(s) or 0 })
end

-- "- acme 30$/h" gives { name = "acme", rate = 30, currency = "$" }
function M.activities(lines)
    local start, last = vault.section(lines, "## Activities")
    local out = {}
    for i = (start or 0) + 1, last or 0 do
        local item = lines[i]:match("^%s*[-*+]%s+(.-)%s*$")
        if item and item ~= "" then
            local rate, currency = item:match("([%d%.]+)%s*(%S-)/h$")
            table.insert(out, {
                name = rate and vim.trim((item:gsub("%s*[%d%.]+%s*%S-/h$", ""))) or item,
                rate = tonumber(rate),
                currency = currency,
            })
        end
    end
    return out
end

-- the running timer, with the row it sits on
function M.running(lines)
    local start, last = vault.section(lines, "## Running")
    for i = (start or 0) + 1, last or 0 do
        local name, date, time, what =
            lines[i]:match("^%s*[-*+]%s+(.-)%s+since%s+(%d%d%d%d%-%d%d%-%d%d)%s+(%d%d?:%d%d:?%d*):?%s*(.-)%s*$")
        if name then
            return { name = name, date = date, time = time, what = what, row = i }
        end
    end
end

-- seconds a running timer has been going
function M.seconds(r)
    return math.max(0, os.time() - epoch(r.date, r.time))
end

-- minutes a running timer has been going
function M.elapsed(r)
    return math.floor(M.seconds(r) / 60)
end

-- every row of the log table
function M.log(lines)
    local out = {}
    for _, line in ipairs(lines) do
        local date, s, e, name, what = line:match(
            "^|%s*(%d%d%d%d%-%d%d%-%d%d)%s*|%s*(%d%d?:%d%d)%s*|%s*(%d%d?:%d%d)%s*|[^|]*|%s*(.-)%s*|%s*(.-)%s*|%s*$"
        )
        if date then
            local mins = math.floor((epoch(date, e) - epoch(date, s)) / 60)
            if mins < 0 then
                mins = mins + 24 * 60 -- went past midnight
            end
            table.insert(out, { date = date, start = s, finish = e, mins = mins, name = name, what = (what:gsub("\\|", "|")) })
        end
    end
    return out
end

function M.read()
    return vault.read(M.note())
end

-- make the note when it is missing, so there is a place to write activities
local function ensure()
    if not vim.uv.fs_stat(M.note()) then
        vault.edit(M.note(), function(buf)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, skeleton())
        end)
    end
end

function M.start(name, what)
    ensure()
    local line = ("- %s since %s: %s"):format(name, os.date("%Y-%m-%d %H:%M:%S"), what)
    vault.edit(M.note(), function(buf)
        vault.append_under(buf, "## Running", { line })
    end)
end

-- stop the running timer and log it; at is "HH:MM" when it stopped earlier than now
function M.stop(what, at)
    local logged
    vault.edit(M.note(), function(buf)
        local r = M.running(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        if not r then
            return false
        end
        local finish = os.time()
        if at then
            finish = epoch(r.date, at)
            if finish <= epoch(r.date, r.time) then
                finish = finish + 24 * 3600
            end
        end
        local mins = math.floor((finish - epoch(r.date, r.time)) / 60)
        vim.api.nvim_buf_set_lines(buf, r.row - 1, r.row, false, {})
        if not vault.section(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "## Log") then
            vault.append(buf, { "## Log", "", skeleton()[13], skeleton()[14] })
        end
        logged = ("| %s | %s | %s | %s | %s | %s |"):format(
            r.date, r.time:match("^%d+:%d+"), os.date("%H:%M", finish), M.format(mins), r.name, (what:gsub("|", "\\|"))
        )
        vault.append_under(buf, "## Log", { logged })
    end)
    return logged
end

local function done()
    require("hippo.dashboard").refresh()
end

local function ask_stop(r)
    local function finish(at)
        vim.ui.input({ prompt = "what did you do? ", default = r.what }, function(what)
            if what then
                M.stop(vim.trim(what), at)
                vim.notify("hippo: logged " .. r.name)
                done()
            end
        end)
    end
    local mins = M.elapsed(r)
    if mins <= cfg().long * 60 then
        return finish()
    end
    -- forgot to stop it, so ask when it really ended
    vim.ui.input({
        prompt = ("%s ran for %s, when did you stop? (HH:MM) "):format(r.name, M.format(mins)),
        default = os.date("%H:%M"),
    }, function(at)
        if at and at:match("^%d%d?:%d%d$") then
            finish(at)
        end
    end)
end

-- start a timer, or stop the one that is running
function M.toggle()
    local lines = M.read()
    local r = M.running(lines)
    if r then
        return ask_stop(r)
    end
    local acts = M.activities(lines)
    if #acts == 0 then
        ensure()
        vim.notify("hippo: write your activities under ## Activities first", vim.log.levels.WARN)
        return vim.cmd.edit(vim.fn.fnameescape(M.note()))
    end
    vim.ui.select(acts, {
        prompt = "start timer",
        format_item = function(a)
            return a.name
        end,
    }, function(a)
        if not a then
            return
        end
        vim.ui.input({ prompt = "what are you doing? " }, function(what)
            if what then
                M.start(a.name, vim.trim(what))
                vim.notify("hippo: timer on for " .. a.name)
                done()
            end
        end)
    end)
end

return M
