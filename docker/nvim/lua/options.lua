local opt = vim.opt

opt.number         = true
opt.relativenumber = true
opt.tabstop        = 4
opt.shiftwidth     = 4
opt.expandtab      = false
opt.smartindent    = true
opt.wrap           = false
opt.swapfile       = false
opt.backup         = false
opt.undofile       = true
opt.undodir        = vim.fn.stdpath("data") .. "/undodir"
opt.hlsearch       = false
opt.incsearch      = true
opt.termguicolors  = true
opt.scrolloff      = 8
opt.signcolumn     = "yes"
opt.updatetime     = 50
opt.ttimeoutlen    = 100
opt.splitright     = true
opt.splitbelow     = true

vim.api.nvim_create_autocmd("FileType", {
    pattern = { "text", "markdown" },
    callback = function()
        vim.opt_local.wrap = true
        vim.opt_local.linebreak = true
    end,
})
