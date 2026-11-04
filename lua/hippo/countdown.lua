-- A kitchen timer: say how long, it tells me when it is done.
local M = {}

local state = { name = nil, ends = nil, done = false, win = nil, started = nil, len = nil }
local clock

local function length(secs)
    return secs < 60 and secs .. "s" or require("hippo.timer").format(math.floor(secs / 60))
end

-- a line under "## Timers" in today's note, for when it ended or I stopped it
local function record(stopped)
    local label = state.name ~= "" and state.name or "timer"
    local line = ("- %s-%s %s %s"):format(os.date("%H:%M", state.started), os.date("%H:%M"), label, length(state.len))
    if stopped then
        line = line .. (" stopped after %s"):format(length(os.time() - state.started))
    else
        line = line .. " ✓"
    end
    local vault = require("hippo.vault")
    vault.edit(vault.today(), function(buf)
        vault.append_under(buf, "## Timers", { line })
    end)
end

-- "25" is minutes, or any of "1h30m", "90s", "1h 5m"; nil when it makes no sense
function M.parse(s)
    s = vim.trim(s or "")
    if s:match("^%d+$") then
        return tonumber(s) * 60
    end
    local secs, mult = 0, { h = 3600, m = 60, s = 1 }
    local rest = s:gsub("(%d+)%s*([hms])", function(n, u)
        secs = secs + tonumber(n) * mult[u]
        return ""
    end)
    if vim.trim(rest) ~= "" or secs == 0 then
        return nil
    end
    return secs
end

local function finish()
    state.ends, state.done = nil, true
    record(false)
    local win = state.win
    require("hippo.notify").send((state.name ~= "" and state.name or "timer") .. " is done", {
        urgent = true,
        -- back to the window I started it from
        on_click = function()
            if win and vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_set_current_win(win)
            end
        end,
    })
    require("hippo.dashboard").refresh()
end

local function start(secs, name)
    state.name, state.ends, state.done = name, os.time() + secs, false
    state.started, state.len = os.time(), secs
    clock = clock or vim.uv.new_timer()
    clock:stop()
    clock:start(secs * 1000, 0, vim.schedule_wrap(finish))
    require("hippo.dashboard").refresh()
end

-- running: stop it. done: clear it. otherwise ask how long and start one
function M.toggle()
    if state.ends then
        clock:stop()
        state.ends = nil
        record(true)
        vim.notify("hippo: countdown stopped")
        return require("hippo.dashboard").refresh()
    end
    state.done, state.win = false, vim.api.nvim_get_current_win()
    vim.ui.input({ prompt = "how long (25, 1h30m, 90s): " }, function(len)
        if not len or len == "" then
            return require("hippo.dashboard").refresh()
        end
        local secs = M.parse(len)
        if not secs then
            return vim.notify("hippo: can't read " .. len, vim.log.levels.ERROR)
        end
        vim.ui.input({ prompt = "for what (optional): " }, function(name)
            start(secs, name or "")
        end)
    end)
end

-- name, seconds left and whether it finished; name is nil when there is nothing
function M.status()
    if not (state.ends or state.done) then
        return nil, 0, false
    end
    return state.name, state.ends and math.max(0, state.ends - os.time()) or 0, state.done
end

return M
