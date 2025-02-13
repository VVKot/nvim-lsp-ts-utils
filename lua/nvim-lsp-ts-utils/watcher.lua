local p = require("plenary.scandir")

local o = require("nvim-lsp-ts-utils.options")
local u = require("nvim-lsp-ts-utils.utils")
local loop = require("nvim-lsp-ts-utils.loop")
local rename_file = require("nvim-lsp-ts-utils.rename-file")

local defer = vim.defer_fn

local s = { watching = false, unwatch = nil, _source = nil }
s.source = {
    get = function()
        return s._source
    end,
    set = function(val)
        s._source = val
    end,
    reset = function()
        s._source = nil
    end,
}

s.reset = function()
    s.watching = false
    s.unwatch = nil
    s._source = nil
end

local M = {}

M.state = s

local should_ignore_file = function(path)
    if u.is_tsserver_file(path) then
        return false
    end

    -- the path may be a directory, but since it could be deleted, we can't check with fs_fstat
    if u.file.extension(path) == "" then
        return false
    end

    return true
end

local should_ignore_event = function(source, target)
    -- ignore save
    if source == target then
        return true
    end

    -- ignore non-move events
    local source_exists, target_exists = u.file.stat(source), u.file.stat(target)
    if source_exists then
        return true
    end
    if not target_exists then
        return true
    end

    -- ignore type mismatches
    if u.file.extension(source) == "" and target_exists.type ~= "directory" then
        return true
    end

    return false
end

local handle_event_factory = function(dir)
    return function(filename)
        local path = dir .. "/" .. filename
        if should_ignore_file(path) then
            return
        end

        local source = s.source.get()
        if not source then
            s.source.set(path)
            defer(function()
                s.source.reset()
            end, 0)
            return
        end

        local target = path
        if should_ignore_event(source, target) then
            s.source.reset()
            return
        end

        if source and target then
            u.debug_log("attempting to update imports")
            u.debug_log("source: " .. source)
            u.debug_log("target: " .. target)

            rename_file.on_move(source, target)
            s.source.reset()
        end
    end
end

local handle_error = function(err)
    u.echo_warning("error in watcher: " .. err)
    s.reset()
end

M.start = function()
    if s.watching then
        return
    end

    local root = u.buffer.root()
    if not root then
        u.debug_log("project root could not be determined; watch aborted")
        return
    end

    u.debug_log("attempting to watch root dir" .. root)

    if u.config_file_exists("git") then
        u.debug_log("git config found; scanning root dir")

        local dir_files = p.scan_dir(root, {
            respect_gitignore = true,
            depth = 1,
            add_dirs = true,
        })

        local unwatch_callbacks, watching = {}, false
        for _, file in ipairs(dir_files) do
            if u.file.is_dir(file) then
                watching = true
                u.debug_log("watching dir " .. file)

                local callback =
                    loop.watch_dir(file, { on_event = handle_event_factory(file), on_error = handle_error })
                table.insert(unwatch_callbacks, callback)
            end
        end

        if not watching then
            u.debug_log("no valid directories found in root dir; aborting")
            return
        end

        s.watching = true
        s.unwatch = function()
            for _, cb in ipairs(unwatch_callbacks) do
                cb()
            end
        end
        return
    end

    u.debug_log("git config not found; falling back to watch_dir")

    if not o.get().watch_dir then
        u.debug_log("watch_dir is not set; watch aborted")
        return
    end

    local watch_dir = root .. o.get().watch_dir
    if not u.file.is_dir(watch_dir) then
        u.debug_log("failed to resolve watch_dir " .. watch_dir .. "; watch aborted")
        return
    end

    u.debug_log("watching directory " .. watch_dir)

    s.watching = true
    s.unwatch = loop.watch_dir(watch_dir, {
        on_event = handle_event_factory(watch_dir),
        on_error = handle_error,
    })
end

M.stop = function()
    if not s.watching then
        return
    end

    s.unwatch()
    s.reset()
    u.debug_log("watcher stopped")
end

M.restart = function()
    M.stop()
    defer(M.start, 100)
end

return M
