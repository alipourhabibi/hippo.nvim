-- A small popup to throw a thought somewhere without leaving what I am doing.
local vault = require("hippo.vault")

local M = {}

local function targets()
    return require("hippo").config.capture
end

local function add(entry, text)
    local e = vault.entry(entry)
    vault.edit(e.path, function(buf)
        if entry == "today" then
            vault.append_under(buf, "## Capture", { "- " .. text })
        else
            -- keep the list going when the note ends with one
            local lines = vim.tbl_filter(function(l)
                return l:match("%S")
            end, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
            local bullet = (lines[#lines] or ""):match("^%s*[-*+] ")
            if bullet then
                vim.api.nvim_buf_set_lines(buf, -1, -1, false, { bullet .. text })
            else
                vault.append(buf, { text })
            end
        end
    end)
end

local function title(i)
    local list = targets()
    return " capture to " .. vault.entry(list[i]).label .. (#list > 1 and "  (Tab to switch) " or " ")
end

function M.open()
    local i = 1
    local buf = vim.api.nvim_create_buf(false, true)
    local width = math.min(80, vim.o.columns - 4)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = math.floor(vim.o.lines / 3),
        col = math.floor((vim.o.columns - width) / 2),
        width = width,
        height = 1,
        style = "minimal",
        border = "rounded",
        title = title(i),
        title_pos = "center",
    })

    local function close()
        vim.cmd.stopinsert()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end

    local function submit()
        local text = vim.trim(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
        close()
        if text ~= "" then
            add(targets()[i], text)
            vim.notify("hippo: captured to " .. vault.entry(targets()[i]).label)
        end
    end

    local function switch()
        i = i % #targets() + 1
        vim.api.nvim_win_set_config(win, { title = title(i), title_pos = "center" })
    end

    local opts = { buffer = buf }
    vim.keymap.set({ "i", "n" }, "<CR>", submit, opts)
    vim.keymap.set({ "i", "n" }, "<Tab>", switch, opts)
    vim.keymap.set("n", "<Esc>", close, opts)
    vim.keymap.set("n", "q", close, opts)
    vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = vim.schedule_wrap(close) })
    vim.cmd.startinsert()
end

return M
