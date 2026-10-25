local M = {}

M.config = {
    path = nil,
    keys = {
        dashboard = "<M-b>",
        claude = "<M-c>",
        capture = "<M-n>",
        add_tab = "<M-a>",
    },
    -- open tasks with this tag are counted for projects and shown in the agenda
    task_tag = "#task",
    dashboard = {
        -- the note that stays on the left
        main = "today",
        -- tabs of the right pane, in <M-1>..<M-9> order: "today", "agenda",
        -- a name from notes below, or any md path in the vault
        tabs = { "agenda" },
        -- "box", "line" or "none"
        header = "box",
        -- the little hippo in the header box
        mascot = true,
        main_width = 0.45,
    },
    -- short names for notes, relative to the vault, like { todo = "todo.md" }
    notes = {},
    -- where capture can write, Tab switches between them: "today" means the
    -- "## Capture" section of today's note, anything else gets the line at its end
    capture = { "today" },
    daily = {
        folder = "daily",
        template = "templates/daily.md",
    },
    -- folders with notes waiting to be filed
    inbox = { "0-Inbox" },
    -- every folder in here is a project
    projects = "1-Projects",
    -- os.date format for the sync commit
    sync_message = "vault sync %Y-%m-%d %H:%M",
    claude_cmd = { "claude" },
    claude_size = { width = 0.9, height = 0.45 },
}

-- linked by default so the colorscheme decides, override any of them after setup
local highlights = {
    HippoTitle = "Title",
    HippoIcon = "Special",
    HippoDim = "Comment",
    HippoBorder = "FloatBorder",
    HippoOverdue = "DiagnosticError",
    HippoDue = "DiagnosticWarn",
    HippoOk = "DiagnosticOk",
    HippoBar = "Function",
    HippoCount = "Number",
    HippoHeat = "String",
    HippoInactive = "NormalFloat",
    HippoMascot = "Special",
}

local function set_highlights()
    for name, link in pairs(highlights) do
        vim.api.nvim_set_hl(0, name, { link = link, default = true })
    end
end

function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
    assert(M.config.path, "hippo: path is required")
    M.config.path = vim.fs.normalize(M.config.path)

    local dashboard = require("hippo.dashboard")
    local claude = require("hippo.claude")
    local capture = require("hippo.capture")

    set_highlights()
    vim.api.nvim_create_autocmd("ColorScheme", { callback = set_highlights })

    local keys = M.config.keys
    vim.keymap.set({ "n", "t" }, keys.dashboard, dashboard.toggle, { desc = "Hippo dashboard" })
    vim.keymap.set({ "n", "t" }, keys.claude, claude.toggle, { desc = "Hippo claude" })
    vim.keymap.set("n", keys.capture, capture.open, { desc = "Hippo capture" })
    for i = 1, 9 do
        vim.keymap.set("n", "<M-" .. i .. ">", function()
            dashboard.tab(i)
        end, { desc = "Hippo tab " .. i })
    end
    vim.keymap.set("n", keys.add_tab, dashboard.add_tab, { desc = "Hippo add note as tab" })
    vim.keymap.set("n", "<M-0>", dashboard.toggle_side, { desc = "Hippo hide or show the right pane" })

    local actions = {
        toggle = dashboard.toggle,
        refresh = function()
            dashboard.refresh()
        end,
        help = dashboard.help,
        carry = require("hippo.tasks").carry_over,
        sync = function()
            require("hippo.git").sync()
        end,
        capture = capture.open,
        claude = claude.toggle,
        addtab = dashboard.add_tab,
        tab = function(n)
            dashboard.tab(tonumber(n) or 1)
        end,
        side = dashboard.toggle_side,
    }
    vim.api.nvim_create_user_command("Hippo", function(o)
        local name = o.fargs[1] or "toggle"
        if not actions[name] then
            return vim.notify("hippo: no action " .. name, vim.log.levels.ERROR)
        end
        actions[name](o.fargs[2])
    end, {
        nargs = "*",
        complete = function(_, line)
            if #vim.split(line, "%s+", { trimempty = true }) <= 2 and not line:match("%s%S+%s") then
                return vim.tbl_keys(actions)
            end
        end,
    })

    -- open the dashboard when nvim starts inside the vault with no files
    -- nested so the notes get their filetype and markdown plugins
    vim.api.nvim_create_autocmd("VimEnter", {
        once = true,
        nested = true,
        callback = function()
            if vim.fn.argc() == 0 and require("hippo.vault").contains(vim.fn.getcwd()) then
                dashboard.open()
            end
        end,
    })
end

return M
