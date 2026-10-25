local M = {}

-- one claude session for the whole nvim; hiding the window keeps it running
local buf

local function find_win()
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return
    end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(win) == buf then
            return win
        end
    end
end

local function open_float(cfg)
    local width = math.floor(vim.o.columns * cfg.claude_size.width)
    local height = math.floor(vim.o.lines * cfg.claude_size.height)
    vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = vim.o.lines - height - 4,
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        title = " claude ",
        title_pos = "center",
    })
end

function M.toggle()
    local win = find_win()
    if win then
        return vim.api.nvim_win_hide(win)
    end

    local cfg = require("hippo").config
    if buf and vim.api.nvim_buf_is_valid(buf) then
        open_float(cfg)
    else
        buf = vim.api.nvim_create_buf(false, true)
        open_float(cfg)
        local this = buf
        vim.fn.jobstart(cfg.claude_cmd, {
            term = true,
            cwd = cfg.path,
            on_exit = function()
                vim.schedule(function()
                    if vim.api.nvim_buf_is_valid(this) then
                        vim.api.nvim_buf_delete(this, { force = true })
                    end
                end)
            end,
        })
    end
    vim.cmd.startinsert()
end

return M
