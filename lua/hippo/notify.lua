-- Notifications in nvim and on the desktop. Clicking the desktop one brings me
-- back: the terminal window, the tmux pane, then whatever on_click opens in nvim.
local M = {}

-- pid and its parents, from /proc
local function ancestors(pid)
    local set = {}
    while pid and pid > 1 do
        set[pid] = true
        local f = io.open("/proc/" .. pid .. "/stat")
        if not f then
            break
        end
        pid = tonumber(f:read("*a"):match("%) %S (%d+)"))
        f:close()
    end
    return set
end

-- ponytail: only niri raises the terminal window, add other compositors here when needed
local function raise_terminal(pid, title)
    if not vim.env.NIRI_SOCKET then
        return
    end
    local out = vim.system({ "niri", "msg", "--json", "windows" }):wait().stdout
    local ok, windows = pcall(vim.json.decode, out or "")
    if not ok then
        return
    end
    local mine, best = ancestors(pid), nil
    for _, w in ipairs(windows) do
        if w.pid and mine[w.pid] then
            -- one terminal process can own many windows, the title tells them apart
            if not best or (title and (w.title or ""):find(title, 1, true)) then
                best = w
            end
        end
    end
    if best then
        vim.system({ "niri", "msg", "action", "focus-window", "--id", tostring(best.id) })
    end
end

local function come_back(on_click)
    local pid, title = vim.fn.getpid(), nil
    local pane = vim.env.TMUX_PANE
    if vim.env.TMUX and pane then
        vim.system({ "tmux", "select-window", "-t", pane }):wait()
        vim.system({ "tmux", "select-pane", "-t", pane }):wait()
        local session = vim.trim(vim.system({ "tmux", "display", "-p", "-t", pane, "#{session_name}" }):wait().stdout or "")
        -- no terminal shows my session: pull the last used one over to it
        local clients = vim.system({ "tmux", "list-clients", "-t", session, "-F", "#{client_pid}" }):wait().stdout or ""
        if not clients:match("%d") then
            vim.system({ "tmux", "switch-client", "-t", pane }):wait()
            clients = vim.system({ "tmux", "list-clients", "-t", session, "-F", "#{client_pid}" }):wait().stdout or ""
        end
        pid, title = tonumber(clients:match("%d+")) or pid, session
    end
    raise_terminal(pid, title)
    if on_click then
        on_click()
    end
end

function M.send(msg, opts)
    opts = opts or {}
    vim.notify("hippo: " .. msg)
    if vim.fn.executable("notify-send") ~= 1 then
        return
    end
    local cmd = { "notify-send", "-A", "default=open", "--wait", "hippo", msg }
    if opts.urgent then
        table.insert(cmd, 2, "-u")
        table.insert(cmd, 3, "critical")
    end
    vim.system(cmd, {}, function(r)
        if vim.trim(r.stdout or "") == "default" then
            vim.schedule(function()
                come_back(opts.on_click)
            end)
        end
    end)
end

return M
