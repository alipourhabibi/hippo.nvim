-- The vault syncs with the phone through git, this shows and does that from nvim.
local vault = require("hippo.vault")

local M = {}

local function root()
    return require("hippo").config.path
end

-- calls cb with { changed, ahead, behind }, or nil when the vault is not a repo;
-- fetch first when asked so behind is up to date
function M.status(cb, fetch)
    local function status()
        vim.system({ "git", "--no-optional-locks", "status", "--porcelain=v2", "--branch" },
            { cwd = root(), text = true }, function(r)
            local s
            if r.code == 0 then
                s = { changed = 0, ahead = 0, behind = 0 }
                for line in r.stdout:gmatch("[^\n]+") do
                    local a, b = line:match("^# branch%.ab %+(%d+) %-(%d+)")
                    if a then
                        s.ahead, s.behind = tonumber(a), tonumber(b)
                    elseif not line:match("^#") then
                        s.changed = s.changed + 1
                    end
                end
            end
            vim.schedule(function()
                cb(s)
            end)
        end)
    end
    if fetch then
        vim.system({ "git", "fetch", "-q" }, { cwd = root() }, status)
    else
        status()
    end
end

-- commit everything, pull with rebase, push; stops at the first step that fails
function M.sync(no_confirm)
    if not no_confirm then
        local yes = vim.fn.confirm("Sync vault? (commit all, pull, push)", "&Yes\n&No", 2) == 1
        -- clear the question so the next message does not stack under it
        vim.cmd.redraw()
        if not yes then
            return
        end
    end

    -- save my unsaved vault notes first so they are part of the commit
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(buf)
        if vim.bo[buf].modified and vim.bo[buf].buftype == "" and name ~= "" and vault.contains(name) then
            vim.api.nvim_buf_call(buf, function()
                vim.cmd("silent write")
            end)
        end
    end

    vim.notify("hippo: syncing")
    local script = 'git add -A && (git diff --cached --quiet || git commit -q -m "$1") '
        .. "&& git pull --rebase --autostash -q && git push -q"
    local msg = os.date(require("hippo").config.sync_message)
    vim.system({ "sh", "-c", script, "sh", msg }, { cwd = root(), text = true }, function(r)
        vim.schedule(function()
            if r.code == 0 then
                vim.notify("hippo: synced")
            else
                vim.notify("hippo: sync failed\n" .. r.stderr, vim.log.levels.ERROR)
            end
            vim.cmd.checktime()
            require("hippo.dashboard").refresh()
        end)
    end)
end

return M
