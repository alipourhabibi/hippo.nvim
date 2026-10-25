local vault = require("hippo.vault")
local tasks = require("hippo.tasks")

local M = {}

-- note size in bytes for each heat level; tune if the colors feel off
local levels = { 500, 1500, 3000 }
local chars = { "·", "░", "▒", "▓", "█" }

-- days in a row ending today, or ending yesterday when today is not done yet
function M.streak(has)
    local start = has(vault.date(0)) and 0 or -1
    local n = 0
    while has(vault.date(start - n)) do
        n = n + 1
    end
    return n
end

-- last n days as one char each, more writing is darker; also the writing streak
function M.heat(n)
    local size = {}
    for _, d in ipairs(vault.daily_dates()) do
        size[d] = vim.uv.fs_stat(vault.daily(d)).size
    end
    local out = {}
    for i = n - 1, 0, -1 do
        local s = size[vault.date(-i)]
        local level = 1
        if s then
            level = 2
            for _, limit in ipairs(levels) do
                if s >= limit then
                    level = level + 1
                end
            end
        end
        table.insert(out, chars[level])
    end
    return table.concat(out), M.streak(function(d)
        return size[d] ~= nil
    end)
end

-- habits are the items under "## Habits" in the daily template;
-- a day counts when that day's daily note has the item checked
function M.habits()
    local tpl = vault.read(vault.file(require("hippo").config.daily.template))
    local start, last = vault.section(tpl, "## Habits")
    if not start then
        return {}
    end

    local checked = {}
    local function done(date, name)
        if not checked[date] then
            checked[date] = {}
            for _, line in ipairs(vault.read(vault.daily(date))) do
                local t = tasks.parse(line)
                if t and t.done then
                    checked[date][t.text:lower()] = true
                end
            end
        end
        return checked[date][name] or false
    end

    local out = {}
    for i = start + 1, last do
        local t = tasks.parse(tpl[i])
        if t then
            local name = t.text:lower()
            table.insert(out, {
                name = t.text,
                today = done(vault.date(0), name),
                streak = M.streak(function(d)
                    return done(d, name)
                end),
            })
        end
    end
    return out
end

return M
