local W = {}
local api = vim.api
local function R() return require("redline") end
local function say(s) vim.notify("redline: " .. s) end
local function context()
    local c = R().workflow_context()
    if not c then say("not inside a git repository") end
    return c
end
local function git(c, args, diff)
    local argv = { "git", "-C", c.root }
    vim.list_extend(argv, args)
    local r = vim.system(argv, { text = false }):wait()
    if r.code ~= 0 and not (diff and r.code == 1) then error(r.stderr or "git failed") end
    return r.stdout or ""
end
local function input(prompt, default, fn)
    vim.ui.input({ prompt = prompt, default = default or "" }, function(s)
        if s ~= nil and vim.trim(s) ~= "" then fn(s) end
    end)
end
local function run(c, argv, done, env)
    say("running " .. argv[1] .. " " .. (argv[2] or ""))
    local ok, err = pcall(vim.system, argv, { cwd = c.root, text = true, env = env }, vim.schedule_wrap(function(r)
        if done then return done(r) end
        if r.code ~= 0 then say(r.stderr and r.stderr ~= "" and r.stderr or "command failed")
        else say(r.stdout and r.stdout ~= "" and r.stdout or "completed") end
    end))
    if not ok then say(tostring(err)) end
end
local function changed(r)
    if r.code ~= 0 then return say(r.stderr and r.stderr ~= "" and r.stderr or "command failed") end
    say(r.stdout and r.stdout ~= "" and r.stdout or "completed")
    R().reload()
end
local function browser(c, url)
    if not url:match("^https?://") then return say("invalid PR URL") end
    if vim.fn.has("mac") == 1 then return run(c, { "open", url }) end
    local ok, proc, err = pcall(vim.ui.open, url)
    if not ok then return say(tostring(proc)) end
    if err then return say(err) end
    if proc then
        local function check()
            if not proc:is_closing() then return vim.defer_fn(check, 50) end
            local result = proc:wait(0)
            if result.code ~= 0 then say(result.stderr and result.stderr ~= "" and result.stderr or "browser command failed") end
        end
        vim.defer_fn(check, 50)
    end
end
-- Preserve Git's byte-level newline semantics and NUL-delimited filenames.
function W.snapshot(c)
    return require("redline.diff").snapshot(c)
end
function W.diff(c)
    c = c or context()
    if not c then return end
    local ok, text, metadata = pcall(W.snapshot, c)
    if not ok then return say(tostring(text)) end
    local view = require("redline.view")
    local b = view.open(c, "Redline diff", vim.split(text, "\n", { plain = true }),
        { filetype = "diff", hints = "Enter Open file   / Search   ? Help   q Back" })
    local offset = api.nvim_buf_line_count(b) - #vim.split(text, "\n", { plain = true })
    vim.keymap.set("n", "<CR>", function()
        local target = metadata.rows[api.nvim_win_get_cursor(0)[1] - offset]
        if not target then return say("Choose a changed file or diff line to open it") end
        if target.deleted then return say("This file was deleted. Stay here to review its removed lines.") end
        local mapped, line, notice = pcall(require("redline.diff").live_line,
            metadata.saved[target.path], target.path, target.line)
        if not mapped then return say("Cannot map this saved line: " .. tostring(line)) end
        if notice then say(notice) end
        if line then view.jump(b, target.path, line) end
    end, { buffer = b })
    vim.keymap.set("n", "?", function() W.help() end, { buffer = b })
    for key, direction in pairs({ ["]h"] = 1, ["[h"] = -1 }) do
        vim.keymap.set("n", key, function()
            local row = api.nvim_win_get_cursor(0)[1]
            for n = 1, #metadata.hunks do
                local h = metadata.hunks[direction == 1 and n or #metadata.hunks - n + 1] + offset
                if (h - row) * direction > 0 then return api.nvim_win_set_cursor(0, { h, 0 }) end
            end
        end, { buffer = b })
    end
end
function W.copy_for_ai(c, bufnr, first, last)
    local ok, review = pcall(R().review_context, bufnr, first, last)
    if not ok then return say(tostring(review)) end
    if c and c.root ~= review.root then return say("review target changed; reopen actions") end
    local lines = { "Please address these review comments. Keep changes within the scope below.",
        "File: " .. review.file, "Base: " .. review.base,
        review.selected and ("Lines " .. review.first .. "-" .. review.last .. ": " .. review.file)
            or ("Whole file: " .. review.file) }
    if review.selected then
        lines[#lines + 1] = "\nSelected lines (live buffer):"
        for i, line in ipairs(review.lines) do lines[#lines + 1] = (review.first + i - 1) .. ": " .. line end
    end
    lines[#lines + 1] = "\nRelevant changes (base -> live buffer; clipped to scope):"
    lines[#lines + 1] = #review.changes > 0 and table.concat(review.changes, "\n")
        or "No changes in this scope. Unchanged file content is omitted; select lines to include code context."
    lines[#lines + 1] = "\nLocal review comments:"
    for _, note in ipairs(review.notes) do
        lines[#lines + 1] = string.format("Lines %d-%d%s: %s", note.first, note.last,
            note.position_warning and " (saved position; cannot map to unsaved buffer)" or "", note.body)
    end
    if #review.notes == 0 then lines[#lines + 1] = "None in this scope." end
    if review.notes_omitted > 0 then
        lines[#lines + 1] = review.notes_omitted .. " same-file saved note(s) omitted: cannot map to selected lines in unsaved buffer."
    end
    lines[#lines + 1] = "\nGitHub review comments (currently loaded):"
    for _, comment in ipairs(review.comments) do
        local position = comment.first and string.format("Lines %d-%d", comment.first, comment.last)
            or (comment.outdated and "Outdated; current position unavailable" or "Current position unavailable")
        lines[#lines + 1] = position .. " | @" .. (comment.author or "unknown") .. ": " .. (comment.body or "")
    end
    if #review.comments == 0 then lines[#lines + 1] = "None in this scope." end
    if review.omitted > 0 then
        lines[#lines + 1] = review.omitted .. " same-file GitHub comment(s) omitted: outdated or cannot map to selected lines."
    end
    local text = table.concat(lines, "\n")
    vim.fn.setreg('"', text)
    pcall(vim.fn.setreg, "+", text)
    say("Copied for AI. Paste into your AI tool. Check for secrets before sharing.")
end
W.handoff = W.copy_for_ai
function W.commit(c)
    c = c or context()
    if not c then return end
    local summary = git(c, { "diff", "--cached", "--stat" })
    if summary == "" then return say("nothing staged") end
    input("Commit staged changes ONLY:\n" .. summary .. "\nCommit message: ", "", function(message)
        run(c, { "git", "commit", "-m", message }, changed)
    end)
end
function W.push(c)
    c = c or context()
    if not c then return end
    local branch = vim.trim(git(c, { "branch", "--show-current" }))
    if branch == "" then return say("checkout a branch before pushing (detached HEAD)") end
    local remotes = vim.split(git(c, { "remote" }), "\n", { trimempty = true })
    if #remotes == 0 then return say("no remote configured") end
    local has_merge, merge = pcall(git, c, { "config", "--get", "branch." .. branch .. ".merge" })
    if has_merge and vim.trim(merge) ~= "refs/heads/" .. branch then
        return say("push refused: upstream " .. vim.trim(merge) .. " differs from current branch " .. branch
            .. "; configure a matching upstream with Git before pushing")
    end
    local remote
    for _, key in ipairs({ "branch." .. branch .. ".pushRemote", "remote.pushDefault", "branch." .. branch .. ".remote" }) do
        local ok, value = pcall(git, c, { "config", "--get", key })
        if ok then remote = vim.trim(value); break end
    end
    local function push(remote, destination)
        if not remote then return end
        if not destination:match("^refs/heads/") or not pcall(git, c, { "check-ref-format", destination }) then
            return say("invalid destination branch")
        end
        run(c, { "git", "push", "--", remote, "HEAD:" .. destination }, changed)
    end
    if remote then
        if remote ~= "." and not vim.tbl_contains(remotes, remote) then return say("configured branch remote is unavailable: " .. remote) end
        return push(remote, "refs/heads/" .. branch)
    end
    if #remotes == 1 then return push(remotes[1], "refs/heads/" .. branch) end
    vim.ui.select(remotes, { prompt = "Push to which remote?" }, function(selected) push(selected, "refs/heads/" .. branch) end)
end
function W.pr(c)
    c = c or context()
    if not c then return end
    if not c.github then return say("GitHub is disabled in setup") end
    local branch = vim.trim(git(c, { "branch", "--show-current" }))
    if branch == "" then return say("checkout a branch before opening a PR (detached HEAD)") end
    run(c, { "gh", "pr", "view", "--json", "url" }, function(result)
        if result.code == 0 then
            local ok, data = pcall(vim.json.decode, result.stdout or "")
            if not ok or type(data) ~= "table" or type(data.url) ~= "string" then return say("invalid PR response from gh") end
            return browser(c, data.url)
        end
        -- Only gh's explicit not-found response permits opening the creation form.
        local message = vim.trim(result.stderr or "")
        if result.code ~= 1 or message ~= 'no pull requests found for branch "' .. branch .. '"' then
            return say(message ~= "" and message or "gh PR lookup failed")
        end
        local argv = { "gh", "pr", "create", "--web", "--head", branch }
        local base = c.default_branch
        if base and base ~= "" then
            base = base:gsub("^refs/remotes/", "")
            for _, remote in ipairs(vim.split(git(c, { "remote" }), "\n", { trimempty = true })) do
                if base:sub(1, #remote + 1) == remote .. "/" then
                    base = base:sub(#remote + 2)
                    break
                end
            end
            vim.list_extend(argv, { "--base", base })
        end
        -- Explicit --head prevents gh from automatically pushing the branch.
        run(c, argv, nil, vim.fn.has("mac") == 1 and { GH_BROWSER = "open" } or nil)
    end)
end
function W.open_target(root, file, line, menu)
    if file:sub(1, #root + 1) ~= root .. "/" or file:find("/../", 1, true) then return say("invalid review target") end
    local stat = (vim.uv or vim.loop).fs_stat(file)
    if not stat or stat.type ~= "file" then
        say("This file was deleted or moved. Opening Changes so you can still read it.")
        local c = R().workflow_context(root)
        if c then W.diff(c) end
        return
    end
    -- A buffer number avoids Ex filename expansion for %, #, brackets and bars.
    local ok, err = pcall(vim.cmd, { cmd = "buffer", args = { tostring(vim.fn.bufadd(file)) } })
    if not ok then return say(tostring(err)) end
    api.nvim_win_set_cursor(0, { math.max(1, math.min(line or 1, api.nvim_buf_line_count(0))), 0 })
    if menu then W.actions() end
end
function W.settings()
    local r = R()
    local items = {
        { "Choose review context", r.open }, { "Toggle overlay", r.toggle },
        { "Toggle removed code", r.toggle_deleted }, { "Cycle comment bodies", r.cycle_comments },
        { "Toggle GitHub comments", r.gh_toggle }, { "Sync GitHub comments", r.gh_sync },
    }
    vim.ui.select(items, { prompt = "Redline settings", format_item = function(i) return i[1] end }, function(i) if i then i[2]() end end)
end
function W.actions(first, last)
    local c = context()
    if not c then return end
    local r, buf, win = R(), api.nvim_get_current_buf(), api.nvim_get_current_win()
    local file, cursor = api.nvim_buf_get_name(buf), api.nvim_win_get_cursor(0)
    local tick = api.nvim_buf_get_changedtick(buf)
    local selected = first ~= nil
    local total = api.nvim_buf_line_count(buf)
    first, last = first or 1, last or first or total
    first, last = math.min(first, last), math.max(first, last)
    if first < 1 or last > total then return say("invalid selection; reopen actions") end
    local stat = (vim.uv or vim.loop).fs_stat(file)
    local is_target = vim.bo[buf].buftype == "" and file:sub(1, #c.root + 1) == c.root .. "/"
    local is_file = is_target and stat and stat.type == "file"
    local scope = selected and ("selected lines " .. first .. "-" .. last) or "file"
    local items = {}
    local function add(key, label, fn, local_action)
        items[#items + 1] = { key = key, label = label, run = function()
            if not api.nvim_win_is_valid(win) or not api.nvim_buf_is_loaded(buf)
                or api.nvim_win_get_buf(win) ~= buf or api.nvim_buf_get_name(buf) ~= file then
                return say("The original file window was closed or changed. Open Actions again.")
            end
            if api.nvim_buf_get_changedtick(buf) ~= tick then
                return say("buffer changed; reopen actions for the current selection")
            end
            if local_action then
                local current = (vim.uv or vim.loop).fs_stat(file)
                if not current or current.type ~= "file" then return say("review target no longer exists") end
            end
            local ok, err = pcall(function()
                api.nvim_set_current_win(win)
                api.nvim_win_set_cursor(win, cursor)
            end)
            if not ok then return say(tostring(err)) end
            -- Enter-window autocmds may have changed the target during restoration.
            if api.nvim_get_current_win() ~= win or api.nvim_get_current_buf() ~= buf
                or api.nvim_buf_get_changedtick(buf) ~= tick or api.nvim_buf_get_name(buf) ~= file then
                return say("The file changed while opening Actions. Open Actions again.")
            end
            fn()
        end }
    end
    if is_file then
        add("s", "Stage " .. scope, function()
            if selected then r.stage(first, last) else r.stage_file() end
        end, true)
        add("u", "Unstage " .. scope, function()
            if selected then r.unstage(first, last) else r.unstage_file() end
        end, true)
        add("c", "Comment " .. scope, function() r.add_note(first, last) end, true)
        add("v", "Toggle viewed " .. scope, function() r.toggle_viewed(first, last) end, true)
        add("y", "Copy " .. scope, function()
            local lines = api.nvim_buf_get_lines(buf, first - 1, last, false)
            vim.fn.setreg('"', lines, "V")
            pcall(vim.fn.setreg, "+", lines, "V")
            say("copied " .. scope)
        end, true)
        add("h", "Select chunk at cursor (file)", function() r.select_hunk() end, true)
    end
    add("f", "Show changed files", function() r.overview(c.root) end)
    add("d", "Read changes (all files)", function() W.diff(c) end)
    add("n", "Read saved notes (all files)", function() r.open_notes(c.root) end)
    add("z", "Undo last review action", r.undo)
    if is_target then
        add("a", "Copy for AI", function() W.copy_for_ai(c, buf, selected and first or nil, selected and last or nil) end)
    end
    add("C", "Commit staged changes (all files)", function() W.commit(c) end)
    add("P", "Push this branch", function() W.push(c) end)
    if c.github then
        add("p", "Open pull request", function() W.pr(c) end)
    end
    require("redline.picker").actions(items, "Redline | " .. (is_target
        and ((selected and ("Lines " .. first .. "-" .. last) or "Whole file") .. ": " .. file:sub(#c.root + 2)) or ("Project: " .. c.root)))
end
function W.help()
    local leader = vim.g.mapleader or "\\"
    leader = leader == " " and "Space " or vim.fn.keytrans(leader)
    local lines, marks = {}, {}
    local function section(title)
        if #lines > 0 then lines[#lines + 1] = "" end
        marks[#marks + 1] = { row = #lines + 3, group = "Title", length = #title }
        lines[#lines + 1] = title
    end
    local function key(k, text)
        marks[#marks + 1] = { row = #lines + 3, group = "Special", length = #k + 2 }
        lines[#lines + 1] = "  " .. k .. string.rep(" ", math.max(2, 22 - vim.fn.strdisplaywidth(k))) .. text
    end
    local function note(text)
        marks[#marks + 1] = { row = #lines + 3, group = "Comment", length = #text + 2 }
        lines[#lines + 1] = "  " .. text
    end
    section("Start")
    key(leader .. "ho", "Choose what to review")
    key(leader .. "ha", "Actions for this file or selected lines")
    key(leader .. "h?", "This guide")
    section("Review")
    key("s / u", "Stage / unstage from Actions")
    key(leader .. "hc", "Add or edit a comment")
    key(leader .. "hv", "Mark as viewed, or unmark")
    key("h / z", "Select a chunk / undo from Actions")
    note("Select lines first to act on just those lines.")
    note("Undo reverses the last Redline action anywhere in this session.")
    section("Move")
    key("]h / [h", "Next / previous change")
    key("f / d / n", "Files / Changes / Local notes from Actions")
    key("Enter / ?", "Open file / Help in review lists")
    key("/", "Search; Enter chooses an action")
    key("q / Esc", "Back from Help or Changes")
    key(leader .. "hb", "Back to Changes after opening a file")
    note("Changes stays open in its own tab. gt / gT also switches tabs.")
    note("Changes shows saved files, including new files, not unsaved edits.")
    section("Share")
    key("y / a", "Copy code / Copy for AI from Actions")
    note("Copy for AI includes this file or selected lines, plus comments.")
    key("C / P / p", "Commit staged changes / Push / Open PR from Actions")
    note("Opening a PR never pushes. Undo does not undo a commit or push.")
    local buf, win = require("redline.view").open(R().workflow_context(), "Redline", lines,
        { hints = "Review at your pace.   q Back   Esc Back" })
    if not buf then return end
    local ns = api.nvim_create_namespace("redline.help")
    for _, mark in ipairs(marks) do
        api.nvim_buf_set_extmark(buf, ns, mark.row, 0,
            { end_col = mark.length, hl_group = mark.group })
    end
    return buf, win
end
return W
