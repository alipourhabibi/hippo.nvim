local M = {}

local function cfg()
    return require("hippo").config
end

local function root()
    return cfg().path
end

local function real(path)
    return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

function M.file(rel)
    return root() .. "/" .. rel
end

-- an entry in dashboard or capture config: "today", "agenda", a name from
-- config.notes, or a path in the vault; agenda has no path
function M.entry(entry)
    if entry == "agenda" or entry == "time" then
        return { label = entry }
    elseif entry == "today" then
        return { label = "today", path = M.today() }
    elseif cfg().notes[entry] then
        return { label = entry, path = M.file(cfg().notes[entry]) }
    end
    return { label = vim.fn.fnamemodify(entry, ":t:r"), path = M.file(entry) }
end

function M.rel(path)
    return path:sub(#root() + 2)
end

function M.contains(dir)
    local r, d = real(root()), real(dir)
    return d == r or vim.startswith(d, r .. "/")
end

-- YYYY-MM-DD, offset in days from today (noon avoids DST jumps)
function M.date(offset)
    local t = os.date("*t")
    return os.date("%Y-%m-%d", os.time({ year = t.year, month = t.month, day = t.day + (offset or 0), hour = 12 }))
end

function M.daily(date)
    return M.file(cfg().daily.folder .. "/" .. date .. ".md")
end

function M.today()
    return M.daily(M.date(0))
end

-- dates that have a daily note, oldest first
function M.daily_dates()
    local out = {}
    for name in vim.fs.dir(M.file(cfg().daily.folder)) do
        local d = name:match("^(%d%d%d%d%-%d%d%-%d%d)%.md$")
        if d then
            table.insert(out, d)
        end
    end
    table.sort(out)
    return out
end

-- folders that do not hold my notes
local skip = { [".git"] = true, [".obsidian"] = true, [".trash"] = true }

-- every markdown note in the vault
function M.notes()
    local out = {}
    local opts = {
        depth = 20,
        skip = function(dir)
            return not skip[vim.fs.basename(dir)] and dir ~= vim.fs.dirname(cfg().daily.template)
        end,
    }
    for name, kind in vim.fs.dir(root(), opts) do
        if kind == "file" and name:match("%.md$") then
            table.insert(out, M.file(name))
        end
    end
    return out
end

function M.read(path)
    return vim.uv.fs_stat(path) and vim.fn.readfile(path) or {}
end

-- notes waiting to be filed; a -raw note belongs to its cleaned note so it is not counted
function M.inbox_count()
    local n = 0
    for _, dir in ipairs(cfg().inbox) do
        for name, kind in vim.fs.dir(M.file(dir)) do
            if kind == "file" and name:match("%.md$") and not name:match("%-raw%.md$") then
                n = n + 1
            end
        end
    end
    return n
end

-- content for a note that does not exist yet; daily notes come from the template
function M.blank(path)
    local date = M.rel(path):match("^" .. vim.pesc(cfg().daily.folder) .. "/(%d%d%d%d%-%d%d%-%d%d)%.md$")
    if not date then
        return { "" }
    end
    local lines = M.read(M.file(cfg().daily.template))
    if #lines == 0 then
        lines = { "---", "created: {{date}}", "tags: [daily]", "---" }
    end
    for i, line in ipairs(lines) do
        lines[i] = (line:gsub("{{date}}", date))
    end
    return lines
end

-- load a note into its buffer; a missing note gets M.blank but stays unsaved,
-- so nothing lands on disk (and in the phone sync) unless I write it
function M.load(path)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    local empty = vim.api.nvim_buf_line_count(buf) == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
    if empty and not vim.uv.fs_stat(path) and not vim.bo[buf].modified then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.blank(path))
        vim.bo[buf].modified = false
    end
    return buf
end

-- change a note through its buffer so unsaved edits are kept, then save it;
-- fn can return false to skip saving
function M.edit(path, fn)
    local buf = M.load(path)
    vim.cmd.checktime(buf)
    if fn(buf) == false then
        return
    end
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent write")
    end)
end

-- heading row and last non-blank row (1-based) of a "## heading" section, nil when missing
function M.section(lines, heading)
    local want = heading:lower()
    local level = #heading:match("^#+")
    local start, last
    for i, line in ipairs(lines) do
        if not start then
            if vim.trim(line):lower() == want then
                start, last = i, i
            end
        else
            local h = line:match("^(#+)%s")
            if h and #h <= level then
                break
            end
            if line:match("%S") then
                last = i
            end
        end
    end
    return start, last
end

-- add lines at the end of a section, making the section when missing;
-- an empty "-" or "- [ ]" left there by the template is replaced
function M.append_under(buf, heading, items)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local start, last = M.section(lines, heading)
    if not start then
        local add = vim.list_extend({ heading }, items)
        if lines[#lines]:match("%S") then
            table.insert(add, 1, "")
        end
        vim.api.nvim_buf_set_lines(buf, -1, -1, false, add)
        return
    end
    local from = last
    if last > start and (lines[last]:match("^%s*[-*+]%s*$") or lines[last]:match("^%s*[-*+] %[ %]%s*$")) then
        from = last - 1
    end
    vim.api.nvim_buf_set_lines(buf, from, last, false, items)
end

-- add lines at the end of a note, after a blank line
function M.append(buf, items)
    local last = vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1]
    if last:match("%S") then
        table.insert(items, 1, "")
    end
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, items)
end

return M
