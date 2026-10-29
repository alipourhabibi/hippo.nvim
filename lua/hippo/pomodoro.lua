-- A plain pomodoro: focus, then a break, then wait for me to start the next one.
-- It only reminds, it never touches the work timer.
local M = {}

local state = { phase = nil, ends = nil, done = 0, day = nil }
local clock

local function cfg()
    return require("hippo").config.pomodoro
end

-- in nvim and on the desktop, so it reaches me outside nvim too
local function notify(msg)
    vim.notify("hippo: " .. msg)
    if vim.fn.executable("notify-send") == 1 then
        vim.system({ "notify-send", "hippo", msg })
    end
end

local finish

local function start(phase, mins)
    state.phase, state.ends = phase, os.time() + mins * 60
    clock = clock or vim.uv.new_timer()
    clock:stop()
    clock:start(mins * 60 * 1000, 0, vim.schedule_wrap(finish))
end

function finish()
    if state.phase == "focus" then
        if state.day ~= os.date("%Y-%m-%d") then
            state.day, state.done = os.date("%Y-%m-%d"), 0
        end
        state.done = state.done + 1
        local long = state.done % cfg().every == 0
        local mins = long and cfg().long or cfg().short
        notify(("pomodoro %d done, take a %d min break"):format(state.done, mins))
        start("break", mins)
    else
        state.phase = nil
        notify("break is over, start the next one when you are ready")
    end
    require("hippo.dashboard").refresh()
end

function M.toggle()
    if state.phase then
        clock:stop()
        state.phase = nil
        vim.notify("hippo: pomodoro stopped")
    else
        start("focus", cfg().focus)
        vim.notify(("hippo: focus for %d min"):format(cfg().focus))
    end
    require("hippo.dashboard").refresh()
end

-- phase ("focus", "break" or nil), seconds left, and pomodoros done today
function M.status()
    local today = state.day == os.date("%Y-%m-%d") and state.done or 0
    return state.phase, state.phase and math.max(0, state.ends - os.time()) or 0, today
end

return M
