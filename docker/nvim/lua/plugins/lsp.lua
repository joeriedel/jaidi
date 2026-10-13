return {
    {
        "neovim/nvim-lspconfig",
        dependencies = {
            "hrsh7th/nvim-cmp",
            "hrsh7th/cmp-nvim-lsp",
            "hrsh7th/cmp-buffer",
            "hrsh7th/cmp-path",
            "L3MON4D3/LuaSnip",
        },
        config = function()
            -- Register Jails as a custom LSP server
            local lspconfig = require("lspconfig")
            local configs   = require("lspconfig.configs")

            if not configs.jails then
                configs.jails = {
                    default_config = {
                        -- -jai_path points at the mounted compiler directory
                        cmd      = { "/usr/local/bin/jails", "-jai_path", (os.getenv("JAIDI_ROOT") or vim.fn.getcwd()) .. "/jai" },
                        filetypes = { "jai" },
                        root_dir = lspconfig.util.root_pattern("jails.json", ".svn", ".git"),
                    },
                }
            end

            local caps = require("cmp_nvim_lsp").default_capabilities()
            lspconfig.jails.setup({ capabilities = caps })

            -- LSP keymaps (set when a server attaches)
            vim.api.nvim_create_autocmd("LspAttach", {
                callback = function(ev)
                    local map = function(lhs, rhs)
                        vim.keymap.set("n", lhs, rhs, { buffer = ev.buf })
                    end
                    map("gd",         vim.lsp.buf.definition)
                    map("gD",         vim.lsp.buf.declaration)
                    map("K",          vim.lsp.buf.hover)
                    map("gi",         vim.lsp.buf.implementation)
                    map("[d",         vim.diagnostic.goto_prev)
                    map("]d",         vim.diagnostic.goto_next)
                end,
            })

            -- Completion
            local cmp    = require("cmp")
            local luasnip = require("luasnip")

            cmp.setup({
                snippet = {
                    expand = function(args) luasnip.lsp_expand(args.body) end,
                },
                mapping = cmp.mapping.preset.insert({
                    ["<C-Space>"] = cmp.mapping.complete(),
                    ["<CR>"]      = cmp.mapping.confirm({ select = true }),
                    ["<Tab>"]     = cmp.mapping(function(fallback)
                        if cmp.visible() then cmp.select_next_item()
                        elseif luasnip.expand_or_jumpable() then luasnip.expand_or_jump()
                        else fallback() end
                    end, { "i", "s" }),
                    ["<S-Tab>"] = cmp.mapping(function(fallback)
                        if cmp.visible() then cmp.select_prev_item()
                        elseif luasnip.jumpable(-1) then luasnip.jump(-1)
                        else fallback() end
                    end, { "i", "s" }),
                }),
                formatting = {
                    format = function(_, item)
                        for k, v in pairs(item) do
                            if vim.fn.type(v) == 10 then item[k] = "" end  -- 10 = blob
                        end
                        return item
                    end,
                },
                sources = cmp.config.sources({
                    { name = "nvim_lsp" },
                    { name = "luasnip" },
                }, {
                    { name = "buffer" },
                    { name = "path" },
                }),
            })
        end,
    },
}
