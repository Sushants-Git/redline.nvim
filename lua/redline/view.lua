local V = {}
local api = vim.api
local views = {}
local ns = api.nvim_create_namespace("redline.view")
local sequence = 0
local source_options = { "number", "relativenumber", "signcolumn", "foldcolumn", "wrap" }

-- Navigation must never turn 'autowriteall' into an implicit save.
local function navigate(fn)
    local aw, awa = vim.o.autowrite, vim.o.autowriteall
    vim.o.autowrite, vim.o.autowriteall = false, false
    local ok, result = xpcall(fn, debug.traceback)
    vim.o.autowrite, vim.o.autowriteall = aw, awa
    if not ok then vim.notify("redline: " .. result, vim.log.levels.WARN) end
    return ok, result
end

-- Returns bufnr, winid. Body lines begin at buffer line 4 (title, hints, blank).
-- Every open gets a single-window tab; Back restores the immediate parent view.
function V.open(c, title, lines, opts)
    opts = opts or {}
    local origin = { win = api.nvim_get_current_win(), tab = api.nvim_get_current_tabpage(),
        buf = api.nvim_get_current_buf(), view = vim.fn.winsaveview() }
    local options = views[origin.buf] and vim.deepcopy(views[origin.buf].source_options) or {}
    if not views[origin.buf] then
        for _, name in ipairs(source_options) do options[name] = vim.wo[origin.win][name] end
    end
    local buf, win
    navigate(function()
        vim.cmd("noautocmd keepalt tabnew")
        buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
        sequence = sequence + 1
        views[buf] = { origin = origin, root = c and c.root, win = win,
            source_options = options, targets = {}, visited = sequence }
        vim.bo[buf].buftype, vim.bo[buf].bufhidden = "nofile", "wipe"
        vim.bo[buf].swapfile, vim.bo[buf].buflisted = false, false
        vim.b[buf].redline_root = c and c.root or nil
        local text = { title, opts.hints or "q Back   Esc Back", "" }
        vim.list_extend(text, lines)
        api.nvim_buf_set_lines(buf, 0, -1, false, text)
        vim.bo[buf].modified = false
        vim.bo[buf].modifiable = false
        vim.bo[buf].filetype = opts.filetype or "text"
        vim.wo[win].number, vim.wo[win].relativenumber = false, false
        vim.wo[win].signcolumn, vim.wo[win].foldcolumn = "no", "0"
        vim.wo[win].wrap = false
        api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_row = 1, hl_group = "Title" })
        api.nvim_buf_set_extmark(buf, ns, 1, 0, { end_row = 2, hl_group = "Comment" })
        for _, key in ipairs({ "q", "<Esc>" }) do
            vim.keymap.set("n", key, function() V.back(buf) end,
                { buffer = buf, nowait = true, silent = true, desc = "Back" })
        end
        api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true,
            callback = function() views[buf] = nil end })
        api.nvim_create_autocmd("BufEnter", { buffer = buf, callback = function()
            if views[buf] then
                sequence = sequence + 1
                views[buf].visited = sequence
            end
        end })
    end)
    return buf, win
end

function V.back(buf)
    buf = buf or api.nvim_get_current_buf()
    local state = views[buf]
    if not state then return end
    navigate(function()
        local origin = state.origin
        if api.nvim_win_is_valid(origin.win) then
            api.nvim_set_current_win(origin.win)
            if api.nvim_win_get_buf(origin.win) == origin.buf then vim.fn.winrestview(origin.view) end
        elseif api.nvim_tabpage_is_valid(origin.tab) then
            api.nvim_set_current_tabpage(origin.tab)
        end
        -- A user may have repurposed the view window or even its buffer.
        -- Only our nofile buffer is disposable, never a replacement source.
        if api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "nofile" then
            for _, win in ipairs(vim.fn.win_findbuf(buf)) do
                if #api.nvim_list_wins() == 1 then vim.cmd("noautocmd keepalt tabnew") end
                api.nvim_win_close(win, false)
            end
            if api.nvim_buf_is_valid(buf) then api.nvim_buf_delete(buf, { force = true }) end
        end
        views[buf] = nil
    end)
end

-- Prefer the last review used from this source window, then the latest live view.
-- No buffer-local mappings are installed or changed during navigation.
function V.return_to_review()
    local source_win, source_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    local chosen, latest, matched
    for buf, state in pairs(views) do
        if api.nvim_win_is_valid(state.win) and api.nvim_win_get_buf(state.win) == buf then
            local target = state.targets[source_win]
            local matches = target and target.buf == source_buf
            local visited = matches and target.visited or state.visited
            if not chosen or (matches and not matched) or ((not not matches) == (not not matched) and visited > latest) then
                chosen, latest, matched = state, visited, matches
            end
        end
    end
    if not chosen then return vim.notify("redline: no review view is open", vim.log.levels.INFO) end
    return navigate(function()
        api.nvim_set_current_win(chosen.win)
    end)
end

-- Keep the review page open. Source buffers never inherit its Back mappings.
-- Prefer matching windows in the original tab, then other tabs, before creating one.
-- Return with <leader>hb (setup mapping) or return_to_review(), then q/Esc for Back.
-- Missing files only notify: never open an empty buffer or recursively open diff.
function V.jump(buf, path, line)
    local state = views[buf]
    if not state then return end
    if type(path) ~= "string" or path == "" or path:find("%z") then
        return vim.notify("redline: no file at this line", vim.log.levels.WARN)
    end
    if path:sub(1, 1) ~= "/" then path = (state.root or vim.fn.getcwd()) .. "/" .. path end
    path = vim.fs.normalize(path, { expand_env = false })
    local stat = vim.uv.fs_stat(path)
    if not stat or stat.type ~= "file" then
        return vim.notify("redline: file is absent or deleted: " .. path, vim.log.levels.WARN)
    end
    local ok = navigate(function()
        local origin = state.origin
        -- Help opened over Changes still belongs to the original source tab.
        local parent = views[origin.buf]
        while parent do origin, parent = parent.origin, views[parent.origin.buf] end
        local target
        if api.nvim_tabpage_is_valid(origin.tab) then
            for _, win in ipairs(api.nvim_tabpage_list_wins(origin.tab)) do
                if api.nvim_buf_get_name(api.nvim_win_get_buf(win)) == path then target = win; break end
            end
        end
        if not target then
            for _, win in ipairs(api.nvim_list_wins()) do
                local source = api.nvim_win_get_buf(win)
                if vim.bo[source].buftype == "" and api.nvim_buf_get_name(source) == path then
                    target = win
                    break
                end
            end
        end
        if target then
            api.nvim_set_current_win(target)
        else
            vim.cmd("noautocmd keepalt tabnew")
            local source = vim.fn.bufadd(path)
            vim.fn.bufload(source)
            api.nvim_win_set_buf(0, source)
            vim.bo[source].buflisted = true
            for _, name in ipairs(source_options) do vim.wo[0][name] = state.source_options[name] end
        end
        local row = math.max(1, math.min(math.floor(tonumber(line) or 1), api.nvim_buf_line_count(0)))
        api.nvim_win_set_cursor(0, { row, 0 })
        sequence = sequence + 1
        state.visited = sequence
        state.targets[api.nvim_get_current_win()] = { buf = api.nvim_get_current_buf(), visited = sequence }
        if not state.notified then
            state.notified = true
            local key = (vim.g.mapleader or "\\") .. "hb"
            local mapping = vim.fn.maparg(key, "n", false, true)
            local hint = mapping.callback == V.return_to_review
                and ((vim.g.mapleader == " " and "Space " or vim.fn.keytrans(vim.g.mapleader or "\\")) .. "hb")
                or ":lua require('redline').back_to_review()"
            vim.notify("redline: Back to Changes: " .. hint, vim.log.levels.INFO)
        end
    end)
    return ok
end

return V
