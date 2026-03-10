local DocSettings = require("docsettings")
local DocumentRegistry = require("document/documentregistry")
local ffiUtil = require("ffi/util")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local Scan = {}

function Scan:getScanPath()
    if self.ui.file_chooser and self.ui.file_chooser.path then
        return self.ui.file_chooser.path
    end
    if self.ui.document and self.ui.document.file then
        return ffiUtil.dirname(self.ui.document.file)
    end
    return G_reader_settings:readSetting("home_dir") or filemanagerutil.getDefaultDir()
end

function Scan:shouldScanDir(dirname)
    if not G_reader_settings:isTrue("show_hidden") and util.stringStartsWith(dirname, ".") then
        return false
    end
    if self.ui.file_chooser then
        return self.ui.file_chooser:show_dir(dirname)
    end
    return true
end

function Scan:shouldScanFile(filename, fullpath)
    if util.stringStartsWith(filename, "._") then
        return false
    end
    if not G_reader_settings:isTrue("show_hidden") and util.stringStartsWith(filename, ".") then
        return false
    end
    if not DocumentRegistry:hasProvider(fullpath) then
        return false
    end
    if self.ui.file_chooser then
        return self.ui.file_chooser:show_file(filename, fullpath)
    end
    return true
end

function Scan:scanBooks(path, progress_cb)
    local sys_folders = {
        ["/dev"] = true,
        ["/proc"] = true,
        ["/sys"] = true,
    }
    local books = {}
    local scanned_files = 0
    local dirs_scanned = 0
    local dirs = { path }

    while #dirs ~= 0 do
        local new_dirs = {}
        for _, d in ipairs(dirs) do
            dirs_scanned = dirs_scanned + 1
            local ok, iter, dir_obj = pcall(lfs.dir, d)
            if ok then
                for f in iter, dir_obj do
                    if f ~= "." and f ~= ".." then
                        local fullpath = d == "/" and "/" .. f or d .. "/" .. f
                        local attr = lfs.attributes(fullpath) or {}
                        if attr.mode == "directory" then
                            if not sys_folders[fullpath] and self:shouldScanDir(f) then
                                table.insert(new_dirs, fullpath)
                            end
                        elseif attr.mode == "file" and self:shouldScanFile(f, fullpath) then
                            scanned_files = scanned_files + 1
                            if DocSettings:hasSidecarFile(fullpath) then
                                table.insert(books, fullpath)
                            end
                        end
                    end
                end
            end
            if progress_cb then
                progress_cb("scan", {
                    path = path,
                    current_dir = d,
                    dirs_scanned = dirs_scanned,
                    scanned_files = scanned_files,
                    metadata_books = #books,
                })
            end
        end
        dirs = new_dirs
    end

    return books, scanned_files
end

return Scan
