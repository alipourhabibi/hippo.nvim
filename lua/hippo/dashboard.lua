local vault = require("hippo.vault")
local tasks = require("hippo.tasks")
local journal = require("hippo.journal")
local git = require("hippo.git")
local timer = require("hippo.timer")
local pomodoro = require("hippo.pomodoro")
local report = require("hippo.report")

local M = {}

local ns = vim.api.nvim_create_namespace("hippo")

local icons = {
    today = "\u{f073}",
    agenda = "\u{f0ae}",
    todo = "\u{f046}",
    shortmind = "\u{f0eb}",
    backlog = "\u{f187}",
    routine = "\u{f01e}",
    file = "\u{f15c}",
    inbox = "\u{f01c}",
    overdue = "\u{f071}",
    due = "\u{f017}",
    git = "\u{f1d3}",
    journal = "\u{f06d}",
    habit = "\u{f004}",
    time = "\u{f254}",
    coffee = "\u{f0f4}",
}

local wins = {}         -- "header", "main" and "side" windows
local bufs = {}         -- "header" and "agenda" scratch buffers
local data = {}         -- what the last refresh found
local git_state
local agenda_items = {} -- agenda row to task
local current = 1       -- which tab the side pane shows
local scratch           -- defined in layout, drawing needs it before that
local ticker            -- redraws the clocks every second

local function opts()
    return require("hippo").config.dashboard
end

local function find_tab()
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        if vim.t[tab].hippo then
            return tab
        end
    end
end

local function on_dashboard()
    local tab = find_tab()
    return tab and tab == vim.api.nvim_get_current_tabpage()
end

local function valid(win)
    return win and vim.api.nvim_win_is_valid(win)
end

-- a main or tab entry with its icon
local function resolve(entry)
    local e = vault.entry(entry)
    e.icon = icons[entry] or icons.file
    return e
end

------------------------------------------------------------------ drawing

-- a line made of { text, hl } parts
local function build(parts)
    local text, marks = "", {}
    for _, p in ipairs(parts) do
        if p[2] then
            table.insert(marks, { #text, #text + #p[1], p[2] })
        end
        text = text .. p[1]
    end
    return { text = text, marks = marks }
end

local function draw(buf, rows)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.tbl_map(function(r)
        return r.text
    end, rows))
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for i, r in ipairs(rows) do
        for _, m in ipairs(r.marks) do
            vim.api.nvim_buf_set_extmark(buf, ns, i - 1, m[1], { end_col = m[2], hl_group = m[3] })
        end
    end
end

-- cut a row to a display width, keeping its highlights inside the text
local function fit(row, width)
    if vim.fn.strdisplaywidth(row.text) <= width then
        return row
    end
    local text = row.text
    while vim.fn.strdisplaywidth(text) > width - 1 do
        text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
    end
    for _, m in ipairs(row.marks) do
        m[2] = math.min(m[2], #text)
        m[1] = math.min(m[1], m[2])
    end
    return { text = text .. "…", marks = row.marks }
end

-- rows inside a rounded box as wide as the window
local function boxed(rows, width, title)
    local B = "HippoBorder"
    local inner = width - 4
    local top = "╭─" .. title .. string.rep("─", math.max(0, width - 3 - vim.fn.strdisplaywidth(title))) .. "╮"
    local out = { build({ { top, B } }) }
    for _, r in ipairs(rows) do
        r = fit(r, inner)
        local pad = string.rep(" ", inner - vim.fn.strdisplaywidth(r.text))
        local row = build({ { "│ ", B }, { r.text }, { pad .. " " }, { "│", B } })
        local shift = #"│ "
        for _, m in ipairs(r.marks) do
            table.insert(row.marks, { m[1] + shift, m[2] + shift, m[3] })
        end
        table.insert(out, row)
    end
    table.insert(out, build({ { "╰" .. string.rep("─", math.max(0, width - 2)) .. "╯", B } }))
    return out
end

local function bar(done, total)
    local filled = total == 0 and 0 or math.floor(done / total * 5 + 0.5)
    return string.rep("▰", filled) .. string.rep("▱", 5 - filled)
end

local function hl_if(n, hl)
    return n > 0 and hl or "HippoDim"
end

------------------------------------------------------------------ header

local function status_row()
    local g = data.agenda
    local row = {
        { icons.today .. " " .. os.date("%a %d %b"),        "HippoTitle" },
        { "    " },
        { icons.inbox .. " inbox " .. data.inbox,           hl_if(data.inbox, "HippoDue") },
        { "    " },
        { icons.overdue .. " " .. #g.overdue .. " overdue", hl_if(#g.overdue, "HippoOverdue") },
        { "    " },
        { icons.due .. " " .. #g.today .. " today",         hl_if(#g.today, "HippoDue") },
        { "    " },
        { icons.git .. " ",                                 "HippoIcon" },
    }
    if git_state then
        vim.list_extend(row, {
            { "●" .. git_state.changed, hl_if(git_state.changed, "HippoDue") },
            { " ↑" .. git_state.ahead, hl_if(git_state.ahead, "HippoDue") },
            { " ↓" .. git_state.behind, hl_if(git_state.behind, "HippoOverdue") },
        })
    else
        table.insert(row, { "-", "HippoDim" })
    end
    return build(row)
end

-- the hippo's face and what it says, from how the day looks
function M.mood(d)
    if #d.agenda.overdue > 0 then
        return "o   o", #d.agenda.overdue .. " overdue, one at a time"
    elseif not d.wrote_today then
        return "-   -", "sleepy, no note today yet"
    elseif d.inbox > 0 then
        return "•   •", d.inbox .. " to file when you can"
    end
    return "^   ^", "all clear, nice"
end

-- three lines of hippo on the left of the box rows
local function with_hippo(rows)
    local eyes, says = M.mood(data)
    local face = { " n_____n ", "( " .. eyes .. " )", " ( oo )  " }
    for i, r in ipairs(rows) do
        local part = face[i] or string.rep(" ", 9)
        local shift = #part + 2
        for _, m in ipairs(r.marks) do
            m[1], m[2] = m[1] + shift, m[2] + shift
        end
        table.insert(r.marks, 1, { 0, #part, "HippoMascot" })
        r.text = part .. "  " .. r.text
    end
    table.insert(rows[1].marks, { #rows[1].text, #rows[1].text + #says + 4, "HippoDim" })
    rows[1].text = rows[1].text .. "    " .. says
    return rows
end

local function clock(secs)
    return ("%d:%02d:%02d"):format(math.floor(secs / 3600), math.floor(secs / 60) % 60, secs % 60)
end

-- the running timer, today's total and the pomodoro; nil when there is nothing
local function timer_row()
    local row = {}
    local r = data.running
    local today = data.today_mins
    if r then
        local mins = timer.elapsed(r)
        local late = mins > require("hippo").config.timer.long * 60
        vim.list_extend(row, {
            { icons.time .. " " .. r.name .. " " .. clock(timer.seconds(r)), late and "HippoOverdue" or "HippoDue" },
            { r.what ~= "" and ("  " .. r.what) or "", "HippoDim" },
        })
        today = today + mins
    end
    if today > 0 then
        table.insert(row, { "    today " .. timer.format(today), "HippoCount" })
    end
    local phase, left, done = pomodoro.status()
    if phase then
        table.insert(row, {
            ("    %s %s %02d:%02d"):format(phase == "focus" and "🍅" or icons.coffee, phase, math.floor(left / 60), left % 60),
            phase == "focus" and "HippoOverdue" or "HippoOk",
        })
    end
    if done > 0 then
        table.insert(row, { "  🍅x" .. done, "HippoDim" })
    end
    return #row > 0 and build(row) or nil
end

local function box_rows()
    local projects = {}
    for _, p in ipairs(data.projects) do
        if #projects > 0 then
            table.insert(projects, { "   " })
        end
        vim.list_extend(projects, {
            { p.name .. " " },
            { bar(p.done, p.open + p.done), hl_if(p.open + p.done, "HippoBar") },
            { " " .. p.open,                hl_if(p.open, "HippoCount") },
        })
        if p.deadline then
            table.insert(projects, { " due " .. p.deadline, "HippoDue" })
        end
    end

    local rows = { status_row() }
    table.insert(rows, timer_row())
    vim.list_extend(rows, {
        build(projects),
        build({
            { icons.journal .. " journal ",      "HippoIcon" },
            { data.heat,                         "HippoHeat" },
            { "  streak " .. data.streak .. "d", hl_if(data.streak, "HippoOk") },
        }),
    })

    if #data.habits > 0 then
        local row = { { icons.habit .. " ", "HippoIcon" } }
        for _, h in ipairs(data.habits) do
            table.insert(row, {
                (h.today and "✓ " or "· ") .. h.name .. " " .. h.streak .. "d   ",
                h.today and "HippoOk" or "HippoDim",
            })
        end
        table.insert(rows, build(row))
    end
    return opts().mascot and with_hippo(rows) or rows
end

local function draw_header()
    if not (valid(wins.header) and data.agenda) then
        return
    end
    local width = vim.api.nvim_win_get_width(wins.header)
    local rows
    if opts().header == "line" then
        local row, t = status_row(), timer_row()
        if t then
            for _, m in ipairs(t.marks) do
                table.insert(row.marks, { m[1] + #row.text + 4, m[2] + #row.text + 4, m[3] })
            end
            row.text = row.text .. "    " .. t.text
        end
        rows = { fit(row, width) }
    else
        rows = boxed(box_rows(), width, " hippo ")
    end
    draw(bufs.header, rows)
    vim.api.nvim_win_set_height(wins.header, #rows)
end

------------------------------------------------------------------ agenda

local function draw_agenda()
    local rows = {}
    agenda_items = {}
    local function section(title, list, hl)
        if #list == 0 then
            return
        end
        table.insert(rows, build({ { " " .. title .. " " .. #list, hl } }))
        for _, t in ipairs(list) do
            table.insert(rows, build({
                { "   " },
                { t.due and (t.due:sub(6) .. "  ") or "", hl },
                { tasks.clean(t.text) },
                { "  " .. tasks.source(t),                "HippoDim" },
            }))
            agenda_items[#rows] = t
        end
    end
    local g = data.agenda
    section("overdue", g.overdue, "HippoOverdue")
    section("today", g.today, "HippoDue")
    section("next 7 days", g.soon, "HippoTitle")
    section("tagged", g.tagged, "HippoDim")
    if #rows == 0 then
        local tag = require("hippo").config.task_tag
        rows = { build({ { " nothing due. tag a task with " .. tag .. " or give it 📅 YYYY-MM-DD", "HippoDim" } }) }
    end
    draw(scratch("agenda"), rows)
end

------------------------------------------------------------------ time

local function draw_time()
    local rows = {}
    local r = data.running
    if r then
        table.insert(rows, build({
            { " " .. icons.time .. " running  ", "HippoTitle" },
            { r.name .. " " .. clock(timer.seconds(r)), "HippoDue" },
            { "  " .. r.what, "HippoDim" },
        }))
    else
        table.insert(rows, build({ { " nothing running, t starts a timer", "HippoDim" } }))
    end
    local phase, left, done = pomodoro.status()
    table.insert(rows, build({
        phase and { (" 🍅 %s %02d:%02d"):format(phase, math.floor(left / 60), left % 60), "HippoDue" }
            or { " p starts a pomodoro", "HippoDim" },
        { done > 0 and ("   %d done today"):format(done) or "", "HippoDim" },
    }))

    -- this week per activity, most time first
    local from, to = report.range("week")
    local sums, order, total = {}, {}, 0
    for _, e in ipairs(data.log) do
        if e.date >= from and e.date <= to then
            if not sums[e.name] then
                sums[e.name] = 0
                table.insert(order, e.name)
            end
            sums[e.name] = sums[e.name] + e.mins
            total = total + e.mins
        end
    end
    table.sort(order, function(a, b)
        return sums[a] > sums[b]
    end)
    local rates = {}
    for _, a in ipairs(data.activities) do
        rates[a.name] = a
    end
    table.insert(rows, build({}))
    table.insert(rows, build({ { " this week  " .. timer.format(total), "HippoTitle" } }))
    for _, name in ipairs(order) do
        table.insert(rows, build({
            { ("   %-14s "):format(name) },
            { bar(sums[name], sums[order[1]]), "HippoBar" },
            { ("  %7s"):format(timer.format(sums[name])), "HippoCount" },
            { "  " .. report.money(sums[name], rates[name]), "HippoDim" },
        }))
    end

    table.insert(rows, build({}))
    table.insert(rows, build({ { " last sessions", "HippoTitle" } }))
    for i = #data.log, math.max(1, #data.log - 7), -1 do
        local e = data.log[i]
        table.insert(rows, build({
            { "   " .. e.date:sub(6) .. "  " .. e.start .. "-" .. e.finish, "HippoDim" },
            { ("  %6s  "):format(timer.format(e.mins)), "HippoCount" },
            { e.name .. "  " },
            { e.what, "HippoDim" },
        }))
    end
    table.insert(rows, build({}))
    table.insert(rows, build({ { " t timer   p pomodoro   R report", "HippoDim" } }))
    draw(scratch("time"), rows)
end

------------------------------------------------------------------ winbars

-- clicking a tab name in the bar calls this (winbar clicks need a global function)
function _G.hippo_tab_click(i)
    M.tab(i)
end

local function open_count(path)
    local n = 0
    for _, t in ipairs(data.all or {}) do
        if t.open and t.path == path then
            n = n + 1
        end
    end
    return n
end

local function set_winbars()
    if valid(wins.main) then
        local e = resolve(opts().main)
        local n = e.path and open_count(e.path) or 0
        vim.wo[wins.main].winbar = "%#HippoIcon# " .. e.icon .. " %#HippoTitle#" .. e.label
            .. "%#HippoDim#" .. (n > 0 and ("  " .. n .. " open") or "") .. "%*"
    end
    if valid(wins.side) then
        local bar_text = ""
        for i, entry in ipairs(opts().tabs) do
            local e = resolve(entry)
            local hl = i == current and "%#HippoTitle#" or "%#HippoDim#"
            local label = i == current and ("[" .. e.label .. "]") or (" " .. e.label .. " ")
            bar_text = bar_text .. "%" .. i .. "@v:lua.hippo_tab_click@" .. hl .. " " .. label .. "%X"
        end
        vim.wo[wins.side].winbar = bar_text .. "%=%#HippoDim#M-0 hide %*"
    end
end

------------------------------------------------------------------ actions

function M.refresh(fetch)
    if not find_tab() then
        return
    end
    data.all = tasks.all()
    data.agenda = tasks.agenda(data.all)
    data.projects = tasks.projects(data.all)
    data.inbox = vault.inbox_count()
    data.heat, data.streak = journal.heat(28)
    data.habits = journal.habits()
    data.wrote_today = vim.uv.fs_stat(vault.today()) ~= nil
    local lines = timer.read()
    data.running = timer.running(lines)
    data.activities = timer.activities(lines)
    data.log = timer.log(lines)
    data.today_mins = 0
    for _, e in ipairs(data.log) do
        if e.date == vault.date(0) then
            data.today_mins = data.today_mins + e.mins
        end
    end
    draw_agenda()
    draw_time()
    draw_header()
    set_winbars()
    git.status(function(s)
        git_state = s
        draw_header()
    end, fetch)
end

-- back to the tab I came from, or a new one when there is none
function M.leave()
    if vim.fn.tabpagenr("#") == 0 then
        vim.cmd("$tabnew")
    else
        vim.cmd("tabnext #")
    end
end

local function agenda_task()
    return agenda_items[vim.api.nvim_win_get_cursor(0)[1]]
end

local function open_task()
    local t = agenda_task()
    if not t then
        return
    end
    M.leave()
    vim.cmd.edit(vim.fn.fnameescape(t.path))
    vim.api.nvim_win_set_cursor(0, { math.min(t.lnum, vim.api.nvim_buf_line_count(0)), 0 })
end

local function toggle_task()
    local t = agenda_task()
    if t then
        tasks.toggle(t)
        M.refresh()
    end
end

function M.help()
    local keys = require("hippo").config.keys
    local lines = {
        "  " .. keys.dashboard .. "      dashboard, or back",
        "  " .. keys.claude .. "      claude",
        "  " .. keys.capture .. "      capture (Tab switches target)",
        "  <M-1..9>   show that tab on the right (or click it)",
        "  <M-0>      hide or show the right pane",
        "  " .. keys.add_tab .. "      add the note I am in as a tab",
        "  " .. keys.timer .. "      start or stop the work timer",
        "  " .. keys.pomodoro .. "      start or stop a pomodoro",
        "  <C-h/l>    go to the left or right pane",
        "  <CR>       follow link or toggle checkbox (obsidian.nvim)",
        "",
        "  in agenda and header:",
        "  <CR>       open the task",
        "  x          done or undone",
        "  C          carry open tasks from the last daily",
        "  S          sync the vault with git",
        "  t / p      timer / pomodoro",
        "  R          time report",
        "  r          refresh",
        "  q          back",
    }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    local width = 60
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = math.floor((vim.o.lines - #lines) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        width = width,
        height = #lines,
        style = "minimal",
        border = "rounded",
        title = " hippo keys ",
        title_pos = "center",
    })
    for _, k in ipairs({ "q", "<Esc>", "?" }) do
        vim.keymap.set("n", k, function()
            vim.api.nvim_win_close(win, true)
        end, { buffer = buf })
    end
end

------------------------------------------------------------------ layout

function scratch(name)
    if not (bufs[name] and vim.api.nvim_buf_is_valid(bufs[name])) then
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(buf, "hippo://" .. name)
        vim.bo[buf].filetype = "hippo"
        local map = function(lhs, fn)
            vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true })
        end
        map("q", M.leave)
        map("r", M.refresh)
        map("S", git.sync)
        map("C", function()
            tasks.carry_over()
            M.refresh()
        end)
        map("?", M.help)
        map("t", timer.toggle)
        map("p", pomodoro.toggle)
        map("R", report.pick)
        if name == "agenda" then
            map("<CR>", open_task)
            map("x", toggle_task)
        end
        bufs[name] = buf
    end
    return bufs[name]
end

-- buffer for a main or tab entry
local function entry_buf(entry)
    local e = resolve(entry)
    if not e.path then
        return scratch(e.label)
    end
    local buf = vault.load(e.path)
    vim.bo[buf].buflisted = true
    return buf
end

local function style(win, kind)
    local wo = vim.wo[win]
    wo.number, wo.relativenumber = false, false
    wo.signcolumn, wo.foldcolumn, wo.colorcolumn = "no", "0", ""
    wo.cursorline = false
    if kind == "header" then
        wo.spell, wo.wrap, wo.winfixheight = false, false, true
    else
        wo.winhighlight = "NormalNC:HippoInactive"
    end
end

local function open_side()
    vim.api.nvim_set_current_win(wins.main)
    vim.cmd("belowright vsplit")
    wins.side = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wins.side, entry_buf(opts().tabs[current]))
    style(wins.side, "side")
    vim.api.nvim_win_set_width(wins.main, math.floor(vim.o.columns * opts().main_width))
end

-- show tab i in the side pane, opening the pane when it is hidden
function M.tab(i)
    if not on_dashboard() or not opts().tabs[i] then
        return
    end
    current = i
    if valid(wins.side) then
        vim.api.nvim_win_set_buf(wins.side, entry_buf(opts().tabs[i]))
        style(wins.side, "side")
    else
        open_side()
    end
    vim.api.nvim_set_current_win(wins.side)
    set_winbars()
end

-- add the note I am in as a tab, until nvim closes (put it in config to keep it)
function M.add_tab()
    local path = vim.api.nvim_buf_get_name(0)
    if vim.bo.buftype ~= "" or not path:match("%.md$") or not vault.contains(path) then
        return vim.notify("hippo: only notes in the vault can be tabs", vim.log.levels.WARN)
    end
    local tabs = opts().tabs
    for i, entry in ipairs(tabs) do
        if resolve(entry).path == path then
            return vim.notify("hippo: already tab " .. i)
        end
    end
    table.insert(tabs, vault.rel(path))
    set_winbars()
    vim.notify("hippo: added as tab " .. #tabs .. (#tabs <= 9 and (", Alt+" .. #tabs) or ""))
end

-- hide the side pane so the main note gets the full width, or bring it back
function M.toggle_side()
    if not on_dashboard() then
        return
    end
    if valid(wins.side) then
        vim.api.nvim_win_hide(wins.side)
        wins.side = nil
    elseif valid(wins.main) then
        open_side()
        set_winbars()
    end
end

local function autocmds()
    local group = vim.api.nvim_create_augroup("hippo_dashboard", { clear = true })
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        pattern = vault.file("*.md"),
        callback = function()
            M.refresh()
        end,
    })
    vim.api.nvim_create_autocmd("TabEnter", {
        group = group,
        callback = function()
            if vim.t.hippo then
                vim.cmd.checktime()
                M.refresh()
            end
        end,
    })
    vim.api.nvim_create_autocmd("VimResized", { group = group, callback = draw_header })
    -- cursorline only in the pane I am in
    vim.api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
        group = group,
        callback = function(ev)
            local win = vim.api.nvim_get_current_win()
            if win == wins.main or win == wins.side then
                vim.wo[win].cursorline = ev.event == "WinEnter"
            end
        end,
    })
end

local function startup_tab_is_empty()
    return vim.fn.tabpagenr("$") == 1
        and vim.fn.winnr("$") == 1
        and vim.api.nvim_buf_get_name(0) == ""
        and not vim.bo.modified
end

-- layout:
--   header (box, one line, or none)
--   main note | tab bar
--             | the current tab
function M.open()
    local tab = find_tab()
    if tab then
        return vim.api.nvim_set_current_tabpage(tab)
    end

    if not startup_tab_is_empty() then
        vim.cmd("0tabnew")
    end
    vim.t.hippo = true
    wins = {}

    wins.main = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wins.main, entry_buf(opts().main))
    style(wins.main, "main")
    open_side()
    if opts().header ~= "none" then
        vim.cmd("topleft split")
        wins.header = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(wins.header, scratch("header"))
        style(wins.header, "header")
    end

    autocmds()
    -- keep the clocks moving while something runs
    ticker = ticker or vim.uv.new_timer()
    ticker:start(1000, 1000, vim.schedule_wrap(function()
        if find_tab() and data.agenda and (data.running or pomodoro.status()) then
            draw_header()
            draw_time()
        end
    end))
    M.refresh(true)
    vim.api.nvim_set_current_win(wins.main)
end

-- jump to the dashboard, or back to the last tab when already on it
function M.toggle()
    if on_dashboard() then
        M.leave()
    else
        M.open()
    end
end

return M
