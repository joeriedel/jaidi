return {
    {
        "mfussenegger/nvim-dap",
        dependencies = {
            "rcarriga/nvim-dap-ui",
            "nvim-neotest/nvim-nio",
        },
        config = function()
            local dap    = require("dap")
            local dapui  = require("dapui")

            vim.fn.sign_define("DapBreakpoint",          { text = "●", texthl = "DapBreakpoint",          linehl = "", numhl = "" })
            vim.fn.sign_define("DapBreakpointCondition", { text = "●", texthl = "DapBreakpointCondition",  linehl = "", numhl = "" })
            vim.fn.sign_define("DapBreakpointRejected",  { text = "●", texthl = "DapBreakpointRejected",   linehl = "", numhl = "" })
            vim.fn.sign_define("DapStopped",             { text = "▶", texthl = "DapStopped",              linehl = "DapStopped", numhl = "" })
            vim.api.nvim_set_hl(0, "DapBreakpoint",          { fg = "#e51400" })
            vim.api.nvim_set_hl(0, "DapBreakpointCondition", { fg = "#e59400" })
            vim.api.nvim_set_hl(0, "DapBreakpointRejected",  { fg = "#888888" })
            vim.api.nvim_set_hl(0, "DapStopped",             { fg = "#98c379" })

            -- codelldb adapter
            dap.adapters.codelldb = {
                type = "server",
                port = "${port}",
                executable = {
                    command = "/opt/codelldb/extension/adapter/codelldb",
                    args    = { "--port", "${port}" },
                },
            }

            -- Jai debug configuration — prompts for the compiled binary path on first run
            local last_executable = nil
            dap.configurations.jai = {
                {
                    type        = "codelldb",
                    request     = "launch",
                    name        = "Launch",
                    program     = function()
                        local default = last_executable or (vim.fn.getcwd() .. "/")
                        last_executable = vim.fn.input("Executable: ", default, "file")
                        return last_executable
                    end,
                    cwd         = "${workspaceFolder}",
                    stopOnEntry = false,
                    args        = {},
                },
            }

            dapui.setup()

            -- Auto open/close the UI, restoring window sizes on exit
            local pre_dap_wins = nil

            dap.listeners.after.event_initialized["dapui"] = function()
                pre_dap_wins = {}
                for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                    pre_dap_wins[win] = {
                        w = vim.api.nvim_win_get_width(win),
                        h = vim.api.nvim_win_get_height(win),
                    }
                end
                dapui.open()
            end

            local function close_and_restore()
                local wins = pre_dap_wins
                pre_dap_wins = nil
                dapui.close()
                if wins then
                    vim.defer_fn(function()
                        for win, dims in pairs(wins) do
                            if vim.api.nvim_win_is_valid(win) then
                                pcall(vim.api.nvim_win_set_width,  win, dims.w)
                                pcall(vim.api.nvim_win_set_height, win, dims.h)
                            end
                        end
                    end, 50)
                end
            end

            dap.listeners.before.event_terminated["dapui"] = close_and_restore
            dap.listeners.before.event_exited["dapui"]     = close_and_restore

            local map = vim.keymap.set
            map("n", "<F5>",       dap.continue)
            map("n", "<leader>b",  dap.toggle_breakpoint)
            map("n", "<leader>B",  function()
                dap.set_breakpoint(vim.fn.input("Condition: "))
            end)
            map("n", "<leader>dx", dap.terminate)
            map("n", "<leader>dr", dap.repl.open)
            map("n", "<leader>du", dapui.toggle)

            -- Step keys active only during a debug session
            local step_keys = { o = dap.step_over, i = dap.step_into, O = dap.step_out,
                                ["<leader>k"] = dap.up, ["<leader>j"] = dap.down }
            local step_keys_active = false
            dap.listeners.after.event_initialized["step_keys"] = function()
                if step_keys_active then return end
                step_keys_active = true
                for k, fn in pairs(step_keys) do map("n", k, fn) end
            end
            local function remove_step_keys()
                if not step_keys_active then return end
                step_keys_active = false
                for k in pairs(step_keys) do pcall(vim.keymap.del, "n", k) end
            end
            dap.listeners.before.event_terminated["step_keys"] = remove_step_keys
            dap.listeners.before.event_exited["step_keys"]     = remove_step_keys
        end,
    },
}
