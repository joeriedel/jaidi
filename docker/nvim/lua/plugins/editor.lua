return {
    -- Colorscheme
    {
        "folke/tokyonight.nvim",
        lazy     = false,
        priority = 1000,
        config   = function()
            require("tokyonight").setup({ style = "night" })
            vim.cmd.colorscheme("tokyonight")
        end,
    },

    -- Statusline
    {
        "nvim-lualine/lualine.nvim",
        dependencies = { "nvim-tree/nvim-web-devicons" },
        config = function()
            require("lualine").setup({ options = { theme = "tokyonight" } })
        end,
    },

    -- File explorer (toggle with <leader>e)
    {
        "nvim-neo-tree/neo-tree.nvim",
        branch = "v3.x",
        dependencies = {
            "nvim-lua/plenary.nvim",
            "nvim-tree/nvim-web-devicons",
            "MunifTanjim/nui.nvim",
        },
        config = function()
            require("neo-tree").setup({
                filesystem = {
                    follow_current_file = { enabled = true },
                    hijack_netrw_behavior = "open_current",
                },
            })
            vim.keymap.set("n", "<leader>e", "<CMD>Neotree toggle<CR>")
        end,
    },

    -- Scrollbar
    { "lewis6991/satellite.nvim", opts = {} },

    -- Fuzzy finder
    {
        "nvim-telescope/telescope.nvim",
        dependencies = { "nvim-lua/plenary.nvim" },
        config = function()
            local b = require("telescope.builtin")
            local root = os.getenv("JAIDI_ROOT") or vim.fn.getcwd()
            local map = vim.keymap.set
            map("n", "<leader>ff", function()
                b.find_files({ cwd = root })
            end)
            map("n", "<leader>fg", function()
                b.live_grep({ search_dirs = { root, root .. "/jai/modules", root .. "/jai/how_to", root .. "/jai/examples", root .. "/jai/editor_support" } })
            end)
            map("n", "<leader>fb", b.buffers)
            map("n", "<C-Tab>", b.buffers)
            map("n", "\x1b[9;5u", b.buffers) -- kitty C-Tab sequence forwarded by tmux
            map("n", "<leader>fs", b.lsp_document_symbols)
            map("n", "<leader>fw", b.lsp_workspace_symbols)
        end,
    },
}
