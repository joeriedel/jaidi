-- nvim-treesitter was archived in 2026. nvim 0.12+ has built-in treesitter.
-- The Jai parser .so and queries are compiled and installed during the Docker build.

vim.filetype.add({ extension = { jai = "jai" } })

local function is_case(line)
    return line:match("^%s*case[^%w_]") or line:match("^%s*case$")
end

-- bare case: ends with ; and no code after it (e.g. "case .FOO;" but not "case .FOO; break;")
local function is_bare_case(line)
    return is_case(line) and line:match("^%s*case[^{]*;%s*$") ~= nil
                         and not line:match("{%s*$")
end

_G.jai_indent = function()
    local lnum     = vim.v.lnum
    local prev     = vim.fn.prevnonblank(lnum - 1)
    if prev == 0 then return 0 end
    local prev_line   = vim.fn.getline(prev)
    local cur_line    = vim.fn.getline(lnum)
    local prev_indent = vim.fn.indent(prev)
    local sw          = vim.bo.shiftwidth

    if cur_line:match("^%s*}") then
        if prev_line:match("{%s*$") then
            return prev_indent   -- empty block: } sits at the same level as the {
        end
        -- Scan backward to find the matching { so deeply-nested bodies
        -- (e.g. case bodies inside if #complete) get the right indent.
        local depth = 1
        local search = prev
        while search > 0 and depth > 0 do
            local line = vim.fn.getline(search)
            for i = #line, 1, -1 do
                local ch = line:sub(i, i)
                if ch == "}" then
                    depth = depth + 1
                elseif ch == "{" then
                    depth = depth - 1
                    if depth == 0 then
                        return vim.fn.indent(search)
                    end
                end
            end
            search = search - 1
        end
        return math.max(0, prev_indent - sw)
    end

    if is_case(cur_line) then
        -- Scan backward to find the enclosing unmatched { (the switch body opener).
        -- This handles cases where the previous line is a deeply-nested } rather than
        -- the case-level closing brace.
        local depth = 0
        local search = prev
        while search > 0 do
            local line = vim.fn.getline(search)
            for i = #line, 1, -1 do
                local ch = line:sub(i, i)
                if ch == "}" then
                    depth = depth + 1
                elseif ch == "{" then
                    depth = depth - 1
                    if depth < 0 then
                        return vim.fn.indent(search) + sw
                    end
                end
            end
            search = search - 1
        end
        return math.max(0, prev_indent - sw)
    end

    if prev_line:match("{%s*$") then
        return prev_indent + sw
    end

    if is_bare_case(prev_line) then
        return prev_indent + sw
    end

    return prev_indent
end

-- Register the Jai parser explicitly since it's installed outside the normal nvim-treesitter paths
pcall(vim.treesitter.language.add, "jai", {
    path = "/root/.local/share/nvim/site/parser/jai.so",
})

local function set_jai_indent(buf)
    vim.bo[buf].smartindent = false
    vim.bo[buf].cindent     = false
    vim.bo[buf].indentexpr  = "v:lua.jai_indent()"
    -- 0{ / 0} : re-indent when { or } is the first non-whitespace char typed
    -- o / O   : re-indent on o/O
    vim.bo[buf].indentkeys  = "0{,0},o,O"
end

vim.api.nvim_create_autocmd("FileType", {
    pattern = "jai",
    callback = function(ev)
        local buf = ev.buf
        local ok, err = pcall(vim.treesitter.start, buf, "jai")
        if not ok then
            vim.notify("jai treesitter: " .. tostring(err), vim.log.levels.WARN)
        end
        -- Set immediately (covers synchronous treesitter indentexpr override)
        -- and again after scheduling (covers asynchronous override in Neovim 0.12+).
        set_jai_indent(buf)
        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(buf) then set_jai_indent(buf) end
        end)
    end,
})

return {}
