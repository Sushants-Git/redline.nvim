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
local function scratch(c, title, text, ft)
    vim.cmd("new")
    local b = api.nvim_get_current_buf()
    vim.bo[b].buftype, vim.bo[b].bufhidden, vim.bo[b].swapfile = "nofile", "wipe", false
    vim.b[b].redline_root = c and c.root or nil
    api.nvim_buf_set_lines(b, 0, -1, false, vim.split(title .. "\n\n" .. text, "\n", { plain = true }))
    vim.bo[b].filetype, vim.bo[b].modifiable = ft or "text", false
    vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = b })
end

-- Preserve Git's byte-level newline semantics and NUL-delimited filenames.
function W.snapshot(c)
    local base = c.base
    if base == "HEAD" and not pcall(git, c, { "rev-parse", "--verify", "HEAD" }) then
        base = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    end
    local text = git(c, { "diff", "--no-ext-diff", "--no-textconv", "--no-color", base, "--", ".", ":(exclude).comments.txt" })
    for _, path in ipairs(vim.split(git(c, { "ls-files", "--others", "--exclude-standard", "-z" }), "\0", { plain = true, trimempty = true })) do
        if path ~= ".comments.txt" then
            text = text .. git(c, { "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--", "/dev/null", path }, true)
        end
    end
    local resolved = vim.trim(git(c, { "rev-parse", "--verify", base }))
    return "Review context: " .. c.mode .. "\nBase: " .. base .. " (" .. resolved .. ")"
        .. "\nDISK SNAPSHOT: includes untracked files; excludes unsaved buffers.\n\n" .. text
end
function W.diff(c)
    c = c or context()
    if not c then return end
    local ok, text = pcall(W.snapshot, c)
    if not ok then return say(tostring(text)) end
    scratch(c, "Redline diff | / search | n/N next/previous | q close", text, "diff")
end
function W.handoff(c)
    c = c or context()
    if not c then return end
    local ok, text = pcall(W.snapshot, c)
    if not ok then return say(tostring(text)) end
    local file = io.open(c.root .. "/.comments.txt", "rb")
    local notes = file and file:read("*a") or "(no saved notes)"
    if file then file:close() end
    text = "Review handoff (no agent executed)\n\nSaved review notes:\n" .. notes .. "\n\n" .. text
    vim.fn.setreg('"', text)
    pcall(vim.fn.setreg, "+", text)
    say("handoff copied to unnamed register and available clipboard")
end
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
        say("File is absent/deleted: showing disk diff. File mutations are unavailable.")
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
    local is_file = vim.bo[buf].buftype == "" and file:sub(1, #c.root + 1) == c.root .. "/"
        and stat and stat.type == "file"
    local scope = selected and ("selected lines " .. first .. "-" .. last) or "file"
    local items = {}
    local function add(key, label, fn, local_action)
        items[#items + 1] = { key = key, label = label, run = function()
            if not api.nvim_win_is_valid(win) or not api.nvim_buf_is_loaded(buf)
                or api.nvim_win_get_buf(win) ~= buf or api.nvim_buf_get_name(buf) ~= file then
                return say("origin no longer available; reopen actions")
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
                return say("origin changed; reopen actions")
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
        add("v", "Viewed: toggle " .. scope, function() r.toggle_viewed(first, last) end, true)
        add("y", "Copy " .. scope, function()
            local lines = api.nvim_buf_get_lines(buf, first - 1, last, false)
            vim.fn.setreg('"', lines, "V")
            pcall(vim.fn.setreg, "+", lines, "V")
            say("copied " .. scope)
        end, true)
        add("h", "Select chunk at cursor (file)", function() r.select_hunk() end, true)
    end
    add("f", "Files (repo)", function() r.overview(c.root) end)
    add("d", "Diff (repo disk snapshot)", function() W.diff(c) end)
    add("n", "Notes (repo)", function() r.open_notes(c.root) end)
    add("z", "Undo last Redline action (session; not publishing)", r.undo)
    add("a", "AI handoff (whole repo: saved notes + disk diff)", function() W.handoff(c) end)
    add("C", "Commit (repo index)", function() W.commit(c) end)
    add("P", "Push (repo branch)", function() W.push(c) end)
    if c.github then
        add("p", "PR (repo: open or create in browser)", function() W.pr(c) end)
    end
    require("redline.picker").actions(items, "Redline | " .. (is_file
        and (scope .. ": " .. file:sub(#c.root + 2)) or ("repo: " .. c.root)))
end
function W.help()
    scratch(R().workflow_context(), "Redline | q close", table.concat({
        "<leader>ho / :Redline   Choose context, then overview",
        "<leader>ha             Actions (normal / visual)",
        "<leader>hc             Add/edit note (normal / visual)",
        "<leader>hv             Toggle viewed (normal / visual)",
        "]h / [h                Next / previous hunk",
        "<leader>h?             Help",
        "Telescope: Enter open; C-a / normal a actions; normal ? help",
        "Split overview: Enter open; a actions; ? help; q close",
        ":Redline diff          Disk diff including untracked; / searches real text",
        "Disk diff / handoff exclude unsaved buffers; overlays use live buffers.",
        "Absent/deleted targets open the disk diff, never an empty editable file.",
        "Actions start in normal mode: press a row's letter to run immediately.",
        "/ enters fuzzy search; Enter runs selected; Esc closes in either mode; normal q closes.",
        "s Stage | u Unstage | c Comment | v Viewed | y Copy | h Select chunk at cursor",
        "Normal ha targets the whole file; visual ha targets the selected line range.",
        "h selects a chunk; open visual ha to act on those lines. Copy uses live buffer lines.",
        "Repo: f Files | d Diff | n Notes | a AI handoff | C Commit | P Push | p PR",
        "z undoes the session's last Redline action, without confirmation (not commit/push/PR).",
        "Local actions and code copy do not ask for confirmation. / searches, not Diff.",
        "PR opens an existing PR or browser creation; it never pushes. Publishing cannot be undone.",
        "Handoff copies the whole repo's saved notes and disk diff, never executes an agent.",
        "Without Telescope, the same actions are available through vim.ui.select.",
        "setup({ keymaps = false }) disables default mappings.",
    }, "\n"))
end
return W
