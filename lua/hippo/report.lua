-- Time reports from the timer log: totals per activity, money when a rate is set,
-- and every session. The same markdown goes to a float or to a note.
local vault = require("hippo.vault")
local timer = require("hippo.timer")

local M = {}

M.ranges = { "today", "week", "month", "last-month" }

local function day(t)
    return os.date("%Y-%m-%d", os.time(t))
end

-- first and last date of a range, and a short name for it
function M.range(arg)
    arg = arg or "week"
    local now = os.date("*t")
    if arg == "today" then
        return vault.date(0), vault.date(0), vault.date(0)
    elseif arg == "week" then
        local monday = -((now.wday + 5) % 7)
        return vault.date(monday), vault.date(monday + 6), "week-" .. vault.date(monday)
    elseif arg == "month" or arg == "last-month" then
        local m = now.month - (arg == "month" and 0 or 1)
        local first = { year = now.year, month = m, day = 1, hour = 12 }
        local last = { year = now.year, month = m + 1, day = 0, hour = 12 }
        return day(first), day(last), day(first):sub(1, 7)
    end
    local y, m = arg:match("^(%d%d%d%d)%-(%d%d)$")
    if y then
        return day({ year = y, month = m, day = 1, hour = 12 }), day({ year = y, month = m + 1, day = 0, hour = 12 }), arg
    end
    local from, to = arg:match("^(%d%d%d%d%-%d%d%-%d%d)%.%.(%d%d%d%d%-%d%d%-%d%d)$")
    if from then
        return from, to, from .. "-to-" .. to
    end
end

function M.money(mins, a)
    return a and a.rate and ("%.2f%s"):format(mins / 60 * a.rate, a.currency or "") or ""
end

-- the report as markdown lines
function M.lines(arg, activity)
    local from, to, label = M.range(arg)
    if not from then
        return nil
    end
    local lines = timer.read()
    local rates = {}
    for _, a in ipairs(timer.activities(lines)) do
        rates[a.name] = a
    end

    local sessions, totals, order, sum = {}, {}, {}, 0
    for _, e in ipairs(timer.log(lines)) do
        if e.date >= from and e.date <= to and (not activity or e.name == activity) then
            table.insert(sessions, e)
            if not totals[e.name] then
                totals[e.name] = 0
                table.insert(order, e.name)
            end
            totals[e.name] = totals[e.name] + e.mins
            sum = sum + e.mins
        end
    end

    local out = {
        "# " .. (activity or "all") .. ", " .. label,
        "",
        from .. " to " .. to,
        "",
        "| activity | time | money |",
        "|---|---|---|",
    }
    for _, name in ipairs(order) do
        table.insert(out, ("| %s | %s | %s |"):format(name, timer.format(totals[name]), M.money(totals[name], rates[name])))
    end
    table.insert(out, ("| **total** | **%s** | |"):format(timer.format(sum)))
    vim.list_extend(out, { "", "## Sessions", "", "| date | time | activity | what |", "|---|---|---|---|" })
    for _, e in ipairs(sessions) do
        table.insert(out, ("| %s %s-%s | %s | %s | %s |"):format(
            e.date, e.start, e.finish, timer.format(e.mins), e.name, (e.what:gsub("|", "\\|"))
        ))
    end
    return out, label
end

-- save a report as a note in the reports folder; asks before replacing one
function M.write(arg, activity)
    local lines, label = M.lines(arg, activity)
    if not lines then
        return
    end
    local path = vault.file(require("hippo").config.timer.reports .. "/" .. (activity or "all") .. "-" .. label .. ".md")
    if vim.uv.fs_stat(path) and vim.fn.confirm(vault.rel(path) .. " exists, replace it?", "&Yes\n&No", 2) ~= 1 then
        return
    end
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local note = { "---", "created: " .. vault.date(0), "tags: [report]", "---" }
    vim.fn.writefile(vim.list_extend(note, lines), path)
    vim.notify("hippo: saved " .. vault.rel(path))
end

-- show a report in a float; w saves it as a note
function M.open(arg, activity)
    local lines = M.lines(arg, activity)
    if not lines then
        return vim.notify("hippo: unknown range " .. tostring(arg), vim.log.levels.ERROR)
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].modifiable = false
    local width = math.min(100, vim.o.columns - 4)
    local height = math.min(#lines + 1, vim.o.lines - 6)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        width = width,
        height = height,
        border = "rounded",
        title = " report  w save as note  q close ",
        title_pos = "center",
    })
    vim.wo[win].wrap = false
    local close = function()
        vim.api.nvim_win_close(win, true)
    end
    vim.keymap.set("n", "q", close, { buffer = buf })
    vim.keymap.set("n", "<Esc>", close, { buffer = buf })
    vim.keymap.set("n", "w", function()
        M.write(arg, activity)
    end, { buffer = buf })
end

-- pick a range, then show it
function M.pick()
    vim.ui.select(M.ranges, { prompt = "report" }, function(r)
        if r then
            M.open(r)
        end
    end)
end

return M
