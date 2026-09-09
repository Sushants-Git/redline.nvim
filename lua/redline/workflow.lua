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
local function confirm(prompt, fn)
    vim.ui.select({ "Cancel", "Confirm" }, { prompt = prompt }, function(s) if s == "Confirm" then fn() end end)
end
local function input(prompt, default, fn, empty)
    vim.ui.input({ prompt = prompt, default = default or "" }, function(s)
        if s ~= nil and (empty or vim.trim(s) ~= "") then fn(s) end
    end)
end
local function run(c, argv)
    say("running " .. argv[1] .. " " .. (argv[2] or ""))
    local ok, err = pcall(vim.system, argv, { cwd = c.root, text = true }, vim.schedule_wrap(function(r)
        if r.code ~= 0 then say(r.stderr ~= "" and r.stderr or "command failed")
        else say(r.stdout ~= "" and r.stdout or "completed"); R().reload() end
    end))
    if not ok then say(tostring(err)) end
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
    confirm("Copy saved notes + disk diff? Check for secrets before sharing.", function()
        vim.fn.setreg('"', text)
        pcall(vim.fn.setreg, "+", text)
        say("handoff copied to unnamed register and available clipboard")
    end)
end
function W.commit(c)
    c = c or context()
    if not c then return end
    local summary = git(c, { "diff", "--cached", "--stat" })
    if summary == "" then return say("nothing staged") end
    input("Commit message: ", "", function(message)
        confirm("Commit ONLY the current index?\n" .. summary .. "\nMessage: " .. message, function()
            run(c, { "git", "commit", "-m", message })
        end)
    end)
end
function W.push(c)
    c = c or context()
    if not c then return end
    local remotes = vim.split(git(c, { "remote" }), "\n", { trimempty = true })
    if #remotes == 0 then return say("no remote configured") end
    vim.ui.select(remotes, { prompt = "Push to which remote?" }, function(remote)
        if not remote then return end
        input("Destination branch: ", vim.trim(git(c, { "branch", "--show-current" })), function(branch)
            if not pcall(git, c, { "check-ref-format", "refs/heads/" .. branch }) then return say("invalid branch") end
            confirm("Push HEAD to " .. remote .. "/" .. branch .. "? (no force)", function()
                run(c, { "git", "push", "--", remote, "HEAD:refs/heads/" .. branch })
            end)
        end)
    end)
end
function W.pr(c, create)
    c = c or context()
    if not c then return end
    if not c.github then return say("GitHub is disabled in setup") end
    if not create then
        return confirm("Open this branch's PR in your browser?", function() run(c, { "gh", "pr", "view", "--web" }) end)
    end
    local branch = vim.trim(git(c, { "branch", "--show-current" }))
    if branch == "" then return say("checkout a branch before creating a PR") end
    input("PR title: ", "", function(title)
        input("PR body (empty allowed): ", "", function(body)
            input("PR base branch: ", (c.default_branch or ""):gsub("^origin/", ""), function(base)
                vim.ui.select({ "Draft", "Ready for review" }, { prompt = "PR status?" }, function(status)
                    if not status then return end
                    confirm("Create " .. status .. " PR " .. branch .. " -> " .. base .. "?\nTitle: " .. title
                        .. "\nBody: " .. body .. "\nPush separately first; this will not push.", function()
                        local argv = { "gh", "pr", "create", "--head", branch, "--base", base, "--title", title, "--body", body }
                        if status == "Draft" then argv[#argv + 1] = "--draft" end
                        run(c, argv)
                    end)
                end)
            end)
        end, true)
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
    local r, buf = R(), api.nvim_get_current_buf()
    local file, cursor = api.nvim_buf_get_name(buf), api.nvim_win_get_cursor(0)
    local tick = api.nvim_buf_get_changedtick(buf)
    local items = {}
    local function add(label, fn, mutation)
        items[#items + 1] = { label, function() if mutation then confirm(label .. "?", fn) else fn() end end }
    end
    if vim.bo[buf].buftype == "" and file:sub(1, #c.root + 1) == c.root .. "/" and (vim.uv or vim.loop).fs_stat(file) then
        local function target(fn)
            return function()
                if not api.nvim_buf_is_valid(buf) or api.nvim_buf_get_name(buf) ~= file
                    or not (vim.uv or vim.loop).fs_stat(file) then return say("review target no longer exists") end
                if api.nvim_buf_get_changedtick(buf) ~= tick then return say("buffer changed; reopen actions for the current selection") end
                api.nvim_set_current_buf(buf)
                api.nvim_win_set_cursor(0, { math.min(cursor[1], api.nvim_buf_line_count(buf)), cursor[2] })
                fn()
            end
        end
        add(first and "Stage selected lines" or "Stage hunk", target(function() r.stage(first, last) end), true)
        add("Stage file (buffer contents)", target(r.stage_file), true)
        add("Unstage file", target(r.unstage_file), true)
        add("Add/edit note", target(function() r.add_note(first, last) end))
        add("Delete note", target(r.del_note), true)
        add("Toggle viewed", target(function() r.toggle_viewed(first, last) end))
        add("Peek removed code", target(r.peek))
        add("Copy contextual code/comments", target(r.yank))
    end
    add("Read notes", r.open_notes)
    add("Overview", r.overview)
    add("Search disk diff (/)", function() W.diff(c) end)
    add("Refresh", r.reload)
    add("Settings", W.settings)
    add("Undo last Redline action (not commit/push/PR)", r.undo, true)
    add("Copy AI handoff (saved notes + disk diff + base)", function() W.handoff(c) end)
    add("Commit staged changes", function() W.commit(c) end)
    add("Push branch", function() W.push(c) end)
    if c.github then
        add("Create PR (push separately)", function() W.pr(c, true) end)
        add("Open PR in browser", function() W.pr(c, false) end)
    end
    add("Help", W.help)
    vim.ui.select(items, { prompt = "Redline actions: " .. (file ~= "" and file or c.root),
        format_item = function(i) return i[1] end }, function(i) if i then i[2]() end end)
end
function W.help()
    scratch(nil, "Redline | q close", table.concat({
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
        "Actions: staging, notes, peek, settings, undo and GitHub workflows.",
        "Commit, push and PR creation require confirmation; Redline cannot undo them.",
        "PR creation never pushes. Handoff only copies, never executes an agent.",
        "setup({ keymaps = false }) disables default mappings.",
    }, "\n"))
end
return W
