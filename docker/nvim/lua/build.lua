local M = {}

local function new_task(title)
    local t = { buf = nil, win = nil, job = nil }

    local function ensure_buf()
        if t.buf ~= nil and vim.api.nvim_buf_is_valid(t.buf) then return end
        t.buf = vim.api.nvim_create_buf(false, true)
        vim.bo[t.buf].bufhidden  = "hide"
        vim.bo[t.buf].modifiable = false
    end

    local function close_win()
        if t.win ~= nil and vim.api.nvim_win_is_valid(t.win) then
            vim.api.nvim_win_close(t.win, true)
        end
        t.win = nil
    end

    local function open_win()
        if t.win ~= nil and vim.api.nvim_win_is_valid(t.win) then
            vim.api.nvim_set_current_win(t.win)
            return
        end
        ensure_buf()
        local W = math.floor(vim.o.columns * 0.85)
        local H = math.floor(vim.o.lines   * 0.80)
        t.win = vim.api.nvim_open_win(t.buf, true, {
            relative  = "editor",
            width     = W,
            height    = H,
            row       = math.floor((vim.o.lines   - H) / 2),
            col       = math.floor((vim.o.columns - W) / 2),
            style     = "minimal",
            border    = "rounded",
            title     = " " .. title .. " ",
            title_pos = "center",
        })
        vim.wo[t.win].wrap = false
        vim.keymap.set("n", "q",     close_win, { buffer = t.buf, nowait = true })
        vim.keymap.set("n", "<Esc>", close_win, { buffer = t.buf, nowait = true })
        vim.keymap.set("n", "<CR>", function()
            local line = vim.api.nvim_get_current_line()
            local path, row, col = line:match("^(/[^:]+):(%d+),?(%d*):")
            if not path then return end
            row = tonumber(row)
            col = col ~= "" and tonumber(col) or 1
            close_win()
            vim.cmd(string.format("edit +%d %s", row, vim.fn.fnameescape(path)))
            vim.schedule(function()
                pcall(vim.api.nvim_win_set_cursor, 0, { row, math.max(0, col - 1) })
            end)
        end, { buffer = t.buf, nowait = true })
    end

    local function buf_append(lines)
        ensure_buf()
        vim.bo[t.buf].modifiable = true
        vim.api.nvim_buf_set_lines(t.buf, -1, -1, false, lines)
        vim.bo[t.buf].modifiable = false
        if t.win ~= nil and vim.api.nvim_win_is_valid(t.win) then
            pcall(vim.api.nvim_win_set_cursor, t.win, { vim.api.nvim_buf_line_count(t.buf), 0 })
        end
    end

    local function start_job(cmd, cwd, on_exit)
        return vim.fn.jobstart(cmd, {
            cwd       = cwd,
            on_stdout = function(_, data) vim.schedule(function() buf_append(data) end) end,
            on_stderr = function(_, data) vim.schedule(function() buf_append(data) end) end,
            on_exit   = function(_, code) vim.schedule(function() on_exit(code) end) end,
        })
    end

    function t.run(cmdline, cmd, cwd, on_success)
        ensure_buf()
        if t.job ~= nil then vim.fn.jobstop(t.job) t.job = nil end
        vim.bo[t.buf].modifiable = true
        vim.api.nvim_buf_set_lines(t.buf, 0, -1, false, { cwd .. "$ " .. cmdline, "" })
        vim.bo[t.buf].modifiable = false
        open_win()
        vim.cmd("redraw!")
        t.job = start_job(cmd, cwd, function(code)
            buf_append({ "", code == 0 and "Done." or ("Exited (" .. code .. ").") })
            t.job = nil
            if code == 0 and on_success then on_success() end
        end)
    end

    -- Append a follow-on job to the existing buffer without clearing it.
    -- Returns the job id so the caller can track it independently.
    function t.append(cmdline, cmd, cwd, on_exit)
        buf_append({ "", cwd .. "$ " .. cmdline, "" })
        return start_job(cmd, cwd, function(code)
            buf_append({ "", code == 0 and "Done." or ("Exited (" .. code .. ").") })
            if on_exit then on_exit(code) end
        end)
    end

    function t.toggle()
        if t.win ~= nil and vim.api.nvim_win_is_valid(t.win) then
            close_win()
        else
            open_win()
        end
    end

    return t
end

local root = os.getenv("JAIDI_ROOT") or vim.fn.getcwd()
local build   = new_task("Build Output")
local run_job = nil

function M.check()
    vim.cmd("silent! wall")
    build.run("jai first.jai - check", { "jai", "first.jai", "-", "check" }, root)
end

function M.build()
    vim.cmd("silent! wall")
    build.run("jai first.jai", { "jai", "first.jai" }, root)
end

function M.run()
    vim.cmd("silent! wall")
    if run_job ~= nil then vim.fn.jobstop(run_job) run_job = nil end
    build.run("jai first.jai", { "jai", "first.jai" }, root, function()
        run_job = build.append("bin/jaidi", { root .. "/bin/jaidi" }, root, function()
            run_job = nil
        end)
    end)
end

function M.toggle_build() build.toggle() end

vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
        if build.job ~= nil then vim.fn.jobstop(build.job) end
        if run_job  ~= nil then vim.fn.jobstop(run_job)    end
    end,
})

return M
