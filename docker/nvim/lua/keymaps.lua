local map = vim.keymap.set

-- Window navigation
map("n", "<C-h>", "<C-w>h")
map("n", "<C-l>", "<C-w>l")
map("n", "<C-j>", "<C-w>j")
map("n", "<C-k>", "<C-w>k")

-- Move selected lines
map("v", "J", ":m '>+1<CR>gv=gv")
map("v", "K", ":m '<-2<CR>gv=gv")

-- Keep cursor centred when scrolling/searching
map("n", "<C-d>", "<C-d>zz")
map("n", "<C-u>", "<C-u>zz")
map("n", "n",     "nzzzv")
map("n", "N",     "Nzzzv")

-- Paste without clobbering the yank register
map("x", "<leader>p", [["_dP]])

-- Yank to system clipboard
map({ "n", "v" }, "<leader>y", [["+y]])
map("n",           "<leader>Y", [["+Y]])

-- Build / Run
map("n", "<leader>c", function() require("build").check()        end)
map("n", "<leader>C", function() require("build").build()        end)
map("n", "<leader>r", function() require("build").run()          end)

-- Alacritty sends VT220 \e[1~/\e[4~ which tmux-256color maps to Find/Select
map({ "n", "i", "v", "c" }, "<Find>",   "<Home>")
map({ "n", "i", "v", "c" }, "<Select>", "<End>")
