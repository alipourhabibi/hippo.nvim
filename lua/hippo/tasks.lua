-- Tasks are markdown checkboxes. They follow the Obsidian Tasks plugin format,
-- so the phone understands them too: "- [ ] pay rent #task 📅 2026-10-30 ⏫"
local vault = require("hippo.vault")

local M = {}

local priorities = { ["🔺"] = 1, ["⏫"] = 2, ["🔼"] = 3, ["🔽"] = 5, ["⏬"] = 6 }

local function project_of(path)
    return vault.rel(path):match("^" .. vim.pesc(require("hippo").config.projects) .. "/([^/]+)/")
end

local function tag_pattern()
    return "%s" .. vim.pesc(require("hippo").config.task_tag) .. "%f[^%w_/-]"
end

function M.parse(line)
    local mark, text = line:match("^%s*[-*+] %[(.)%]%s+(.-)%s*$")
    if not mark or text == "" then
        return
    end
    local t = {
        open = mark == " ",
        done = mark == "x" or mark == "X",
        text = text,
        due = text:match("📅%s*(%d%d%d%d%-%d%d%-%d%d)"),
        priority = 4,
    }
    for icon, p in pairs(priorities) do
        if text:find(icon, 1, true) then
            t.priority = p
        end
    end
    return t
end

function M.tagged(text)
    return (" " .. text):find(tag_pattern()) ~= nil
end

-- task text without the date, tag and priority marks
function M.clean(text)
    text = (" " .. text):gsub(tag_pattern(), ""):gsub("📅%s*%d%d%d%d%-%d%d%-%d%d", "")
    for icon in pairs(priorities) do
        text = text:gsub(icon, "")
    end
    return vim.trim((text:gsub("%s+", " ")))
end

-- project name for tasks in a project, note name otherwise
function M.source(t)
    return project_of(t.path) or vim.fn.fnamemodify(t.path, ":t:r")
end

-- every task in the vault, with path and lnum
-- ponytail: reads every note on each refresh, fine for ~1000 notes, use rg if it gets slow
function M.all()
    local out = {}
    for _, path in ipairs(vault.notes()) do
        for lnum, line in ipairs(vim.fn.readfile(path)) do
            local t = M.parse(line)
            if t then
                t.path, t.lnum = path, lnum
                table.insert(out, t)
            end
        end
    end
    return out
end

-- every project folder with its tagged open and done counts, and deadline if set
function M.projects(all)
    local by, out = {}, {}
    local root = vault.file(require("hippo").config.projects)
    for name, kind in vim.fs.dir(root) do
        if kind == "directory" then
            local p = { name = name, open = 0, done = 0 }
            for _, line in ipairs(vault.read(root .. "/" .. name .. "/" .. name .. ".md")) do
                p.deadline = p.deadline or line:match("^deadline:%s*(%S+)")
            end
            by[name] = p
            table.insert(out, p)
        end
    end
    for _, t in ipairs(all) do
        local p = by[project_of(t.path) or ""]
        if p and M.tagged(t.text) then
            if t.open then
                p.open = p.open + 1
            elseif t.done then
                p.done = p.done + 1
            end
        end
    end
    table.sort(out, function(a, b)
        return a.name < b.name
    end)
    return out
end

-- open tasks grouped: overdue, today, the next 7 days, and tagged ones with no date
function M.agenda(all)
    local today, week = vault.date(0), vault.date(7)
    local g = { overdue = {}, today = {}, soon = {}, tagged = {} }
    for _, t in ipairs(all) do
        if t.open then
            local group = (t.due and t.due < today and "overdue")
                or (t.due == today and "today")
                or (t.due and t.due <= week and "soon")
                or (not t.due and M.tagged(t.text) and "tagged")
            if group then
                table.insert(g[group], t)
            end
        end
    end
    for _, list in pairs(g) do
        table.sort(list, function(a, b)
            if (a.due or "") ~= (b.due or "") then
                return (a.due or "") < (b.due or "")
            end
            if a.priority ~= b.priority then
                return a.priority < b.priority
            end
            return a.text < b.text
        end)
    end
    return g
end

-- flip a task found by M.all; refuses when the note changed since
function M.toggle(t)
    local ok = false
    vault.edit(t.path, function(buf)
        local line = vim.api.nvim_buf_get_lines(buf, t.lnum - 1, t.lnum, false)[1]
        local now = line and M.parse(line)
        if not now or now.text ~= t.text then
            return false
        end
        local new = now.open and line:gsub("%[ %]", "[x]", 1) or line:gsub("%[[xX]%]", "[ ]", 1)
        vim.api.nvim_buf_set_lines(buf, t.lnum - 1, t.lnum, false, { new })
        ok = true
    end)
    if not ok then
        vim.notify("hippo: that note changed, refresh and try again", vim.log.levels.WARN)
    end
    return ok
end

-- copy open tasks of the last daily note before today into today's "## Tasks"
-- and mark them [>] there, so they are not carried twice
function M.carry_over()
    local today, prev = vault.date(0), nil
    for _, d in ipairs(vault.daily_dates()) do
        if d < today then
            prev = d
        end
    end
    if not prev then
        return vim.notify("hippo: no daily note before today")
    end

    local from = vault.daily(prev)
    local rows, items = {}, {}
    for lnum, line in ipairs(vim.api.nvim_buf_get_lines(vault.load(from), 0, -1, false)) do
        local t = M.parse(line)
        if t and t.open then
            table.insert(rows, lnum)
            table.insert(items, "- [ ] " .. t.text)
        end
    end
    if #items == 0 then
        return vim.notify("hippo: nothing open in " .. prev)
    end

    -- today first, so a failed write never loses a task
    vault.edit(vault.today(), function(buf)
        vault.append_under(buf, "## Tasks", items)
    end)
    vault.edit(from, function(buf)
        for _, lnum in ipairs(rows) do
            local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
            vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, { (line:gsub("%[ %]", "[>]", 1)) })
        end
    end)
    vim.notify(("hippo: carried %d task%s from %s"):format(#items, #items == 1 and "" or "s", prev))
end

return M
