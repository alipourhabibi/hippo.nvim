-- One place for tasks: the todo note (config.notes.todo). The daily note keeps what got
-- done. The same rules as the phone's core/TodoDay.kt, so both move the same lines.
local vault = require("hippo.vault")
local tasks = require("hippo.tasks")

local M = {}

-- ticked tasks in these sections move to the daily "## Done today"
M.move = { "Today", "Tomorrow", "Buy" }
-- routine sections, unticked once a day
M.reset = { "Must", "DO", "Love" }
local TODAY, TOMORROW, DONE = "Today", "Tomorrow", "Done today"
-- frontmatter key in the todo note: the day it was last rolled, so two devices roll once
local KEY = "hippo-day"

-- the note's own heading for name, any case: "## name", "## name:" or "## name(...)"
-- (a word, not a prefix: Do is not Done); "## name" when there is none
function M.heading(lines, name)
    for _, line in ipairs(lines) do
        local text = line:match("^##%s+(.-)%s*$")
        if text and text:sub(1, #name):lower() == name:lower() and not text:sub(#name + 1, #name + 1):match("%w") then
            return vim.trim(line)
        end
    end
    return "## " .. name
end

-- set of line numbers of tasks matching keep in the named sections
local function rows(lines, names, keep)
    local set = {}
    for _, name in ipairs(names) do
        local start, last = vault.section(lines, M.heading(lines, name))
        for i = (start or 0) + 1, start and last or 0 do
            local t = tasks.parse(lines[i])
            if t and keep(t) then
                set[i] = true
            end
        end
    end
    return set
end

local function without(lines, set)
    local out = {}
    for i, line in ipairs(lines) do
        if not set[i] then
            table.insert(out, line)
        end
    end
    return out
end

local function picked(lines, set)
    local out = {}
    for i, line in ipairs(lines) do
        if set[i] then
            table.insert(out, vim.trim(line))
        end
    end
    return out
end

-- vault.append_under on a list of lines instead of a buffer
local function append_under(lines, heading, items)
    local start, last = vault.section(lines, heading)
    if not start then
        local out = vim.list_extend({}, lines)
        if #out > 0 and out[#out]:match("%S") then
            table.insert(out, "")
        end
        table.insert(out, heading)
        return vim.list_extend(out, items)
    end
    local from = last
    if last > start and (lines[last]:match("^%s*[-*+]%s*$") or lines[last]:match("^%s*[-*+] %[ %]%s*$")) then
        from = last - 1
    end
    local out = vim.list_slice(lines, 1, from)
    vim.list_extend(out, items)
    return vim.list_extend(out, vim.list_slice(lines, last + 1))
end

-- ticked Today/Tomorrow/Buy tasks go to the daily "## Done today", a task unticked there goes
-- back to Today; nil when nothing moves, so a write never sets off another one
function M.sweep(todo, daily)
    local done = rows(todo, M.move, function(t)
        return t.done
    end)
    local back = rows(daily, { DONE }, function(t)
        return t.open
    end)
    if next(done) == nil and next(back) == nil then
        return nil
    end
    local t, d = without(todo, done), without(daily, back)
    if next(done) then
        d = append_under(d, M.heading(d, DONE), picked(todo, done))
    end
    if next(back) then
        t = append_under(t, M.heading(t, TODAY), picked(daily, back))
    end
    return t, d
end

local function frontmatter_end(lines)
    if not lines[1] or vim.trim(lines[1]) ~= "---" then
        return nil
    end
    for i = 2, #lines do
        if vim.trim(lines[i]) == "---" then
            return i
        end
    end
end

-- once a day: untick the routines, move open Tomorrow tasks to Today, mark the day; nil when
-- this day was rolled already. With no mark yet it only marks, so today's ticks are kept.
function M.new_day(todo, today)
    local out, mark, at = vim.list_extend({}, todo), nil, nil
    local fm = frontmatter_end(out)
    for i = 2, (fm or 1) - 1 do
        local v = out[i]:match("^" .. vim.pesc(KEY) .. ":%s*(.-)%s*$")
        if v then
            mark, at = v, i
        end
    end
    if mark and mark >= today then
        return nil
    end
    local line = KEY .. ": " .. today
    if at then
        out[at] = line
    elseif fm then
        table.insert(out, fm, line)
    else
        out = vim.list_extend({ "---", line, "---" }, out)
    end
    if not mark then
        return out
    end
    local reset = rows(out, M.reset, function(t)
        return t.done
    end)
    for i in pairs(reset) do
        out[i] = out[i]:gsub("%[[xX]%]", "[ ]", 1):gsub("%s*✅%s*%d%d%d%d%-%d%d%-%d%d", "")
    end
    local moving = rows(out, { TOMORROW }, function(t)
        return t.open
    end)
    if next(moving) then
        local items = picked(out, moving)
        local heading = M.heading(out, TODAY)
        out = append_under(without(out, moving), heading, items)
    end
    return out
end

local function todo_path()
    local rel = require("hippo").config.notes.todo
    return rel and vault.file(rel)
end

local function lines_of(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local busy = false

-- the files version of M.sweep: today's note is written first, so a line is never in neither
function M.sweep_files()
    local todo = todo_path()
    if busy or not todo then
        return
    end
    busy = true
    local ok, err = pcall(function()
        local t, d = M.sweep(lines_of(vault.load(todo)), lines_of(vault.load(vault.today())))
        if not t then
            return
        end
        vault.edit(vault.today(), function(buf)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, d)
        end)
        vault.edit(todo, function(buf)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, t)
        end)
    end)
    busy = false
    if not ok then
        vim.notify("hippo: moving done tasks failed\n" .. tostring(err), vim.log.levels.ERROR)
    end
end

-- ponytail: the laptop may roll before it pulls the phone's roll of the same day; a routine
-- ticked on the phone after its roll can come back unticked. Sync first in the morning.
function M.new_day_files()
    local todo = todo_path()
    if not todo then
        return
    end
    vault.edit(todo, function(buf)
        local out = M.new_day(lines_of(buf), vault.date(0))
        if not out then
            return false
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
    end)
    M.sweep_files()
end

-- a save of the todo note or of today's note moves what was ticked or unticked
function M.setup()
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = vim.api.nvim_create_augroup("HippoTodo", { clear = true }),
        pattern = "*.md",
        callback = function(e)
            local path = vim.fs.normalize(vim.api.nvim_buf_get_name(e.buf))
            if busy or (path ~= todo_path() and path ~= vault.today()) then
                return
            end
            vim.schedule(M.sweep_files)
        end,
    })
end

return M
