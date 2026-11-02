-- nvim --headless -u NONE -l tests/todo_test.lua
-- The rules of lua/hippo/todo.lua, the same cases as the phone's TodoDayTest.kt.
vim.opt.rtp:prepend(vim.fn.getcwd())
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/daily", "p")
require("hippo").setup({ path = tmp, notes = { todo = "todo.md" } })
local todo = require("hippo.todo")
local vault = require("hippo.vault")

local function eq(want, got, what)
    if not vim.deep_equal(want, got) then
        error(("%s\nwant %s\ngot  %s"):format(what, vim.inspect(want), vim.inspect(got)), 2)
    end
end

local note = {
    "---", "id: todo", "hippo-day: 2026-11-01", "---",
    "## Must:", "- [x] Brush teeth", "- [ ] Meditate", "",
    "## DO(Same as love, but more compact like):", "- [x] Book", "",
    "## Today:", "- [x] Detsim #task", "- [ ] Read book", "",
    "## Tomorrow:", "- [ ] read the food plan", "- [x] already done", "",
    "## Buy", "- [x] Earplug", "- [ ] umbrella",
}
local daily = { "# 2026-11-02", "", "## Capture", "-", "", "## Done today", "-" }

-- ticked Today/Tomorrow/Buy move to Done today, routines stay
local t, d = todo.sweep(note, daily)
eq({ "## Done today", "- [x] Detsim #task", "- [x] already done", "- [x] Earplug" }, vim.list_slice(d, #d - 3), "done today")
eq(true, vim.tbl_contains(t, "- [x] Brush teeth") and vim.tbl_contains(t, "- [x] Book"), "routines stay ticked")
eq(false, vim.tbl_contains(t, "- [x] Earplug"), "buy item moved")
eq(nil, todo.sweep(t, d), "nothing left to move")

-- unticked in Done today goes back to Today
local d2 = vim.tbl_map(function(l)
    return l == "- [x] Earplug" and "- [ ] Earplug" or l
end, d)
local t3, d3 = todo.sweep(t, d2)
eq(false, vim.tbl_contains(d3, "- [ ] Earplug"), "gone from done today")
local s, e = vault.section(t3, "## Today:")
eq({ "- [ ] Read book", "- [ ] Earplug" }, vim.list_slice(t3, s + 1, e), "back in today")

-- a new day unticks routines, moves Tomorrow to Today, once
local n = todo.new_day(t, "2026-11-02")
eq(true, vim.tbl_contains(n, "hippo-day: 2026-11-02"), "marked")
eq(true, vim.tbl_contains(n, "- [ ] Brush teeth") and vim.tbl_contains(n, "- [ ] Book"), "routines unticked")
s, e = vault.section(n, "## Today:")
eq({ "- [ ] Read book", "- [ ] read the food plan" }, vim.list_slice(n, s + 1, e), "tomorrow moved to today")
eq(nil, todo.new_day(n, "2026-11-02"), "rolled once")

-- the first roll only marks the day
eq({ "---", "id: todo", "hippo-day: 2026-11-02", "---", "## Must:", "- [x] Brush teeth" },
    todo.new_day({ "---", "id: todo", "---", "## Must:", "- [x] Brush teeth" }, "2026-11-02"), "first roll")
eq("## DO(Same as love):", todo.heading({ "## DO(Same as love):", "## Done today" }, "DO"), "heading word")
eq("## Do", todo.heading({ "## Done today" }, "Do"), "Do is not Done")

-- on files: a save of the todo note moves the tick to today's note
vim.fn.writefile({ "---", "id: todo", "---", "## Today:", "- [ ] pay rent", "- [ ] read" }, tmp .. "/todo.md")
vim.cmd.edit(tmp .. "/todo.md")
vim.api.nvim_buf_set_lines(0, 4, 5, false, { "- [x] pay rent" })
vim.cmd("silent write")
vim.wait(1000, function()
    return vim.fn.filereadable(vault.today()) == 1
end)
eq(true, vim.tbl_contains(vim.fn.readfile(vault.today()), "- [x] pay rent"), "moved to today's note on save")
eq({ "---", "id: todo", "---", "## Today:", "- [ ] read" }, vim.fn.readfile(tmp .. "/todo.md"), "gone from todo")
todo.new_day_files()
eq(true, vim.tbl_contains(vim.fn.readfile(tmp .. "/todo.md"), "hippo-day: " .. vault.date(0)), "day marked on file")

print("todo: ok")
