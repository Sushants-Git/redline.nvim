local P = {}

function P.actions(items, title)
    local function display(item) return "[" .. item.key .. "] " .. item.label end
    local ok, pickers = pcall(require, "telescope.pickers")
    if not ok then
        return vim.ui.select(items, { prompt = title, format_item = display }, function(item)
            if item then item.run() end
        end)
    end
    local actions = require("telescope.actions")
    local state = require("telescope.actions.state")
    pickers.new({}, {
        prompt_title = title,
        results_title = "Press a letter | /: search | Enter: choose | Esc/q: close",
        initial_mode = "normal",
        sorting_strategy = "ascending",
        layout_strategy = "vertical",
        layout_config = { width = 0.9, height = #items + 6, prompt_position = "top" },
        previewer = false,
        finder = require("telescope.finders").new_table({
            results = items,
            entry_maker = function(item)
                return { value = item, display = display(item), ordinal = item.label }
            end,
        }),
        sorter = require("telescope.config").values.generic_sorter({}),
        attach_mappings = function(prompt, map)
            local executed = false
            local function run(item)
                if not item or executed then return end
                executed = true
                actions.close(prompt)
                -- Let Telescope finish leaving insert mode before a chunk enters Visual mode.
                vim.schedule(item.run)
            end
            local function selected()
                local entry = state.get_selected_entry()
                run(entry and entry.value)
            end
            actions.select_default:replace(selected)
            for _, item in ipairs(items) do
                map("n", item.key, function() run(item) end)
            end
            map("n", "/", function() vim.cmd.startinsert() end)
            map("n", "q", function() actions.close(prompt) end)
            map("n", "<Esc>", function() actions.close(prompt) end)
            map("i", "<Esc>", function() actions.close(prompt) end)
            map("n", "<CR>", selected)
            map("i", "<CR>", selected)
            return true
        end,
    }):find()
end

return P
