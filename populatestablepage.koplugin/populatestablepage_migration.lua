local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local util = require("util")
local _ = require("gettext")
local T = ffiUtil.template

local Migration = {}

function Migration:migrateBooks(path, chars_per_synthetic_page, synthetic_overrides,
                                use_page_labels, show_page_labels,
                                overwrite_differing_settings, progress_cb, progress)
    local result = {
        scanned_files = 0,
        metadata_books = 0,
        migrated = 0,
        already_ok = 0,
        not_crengine = 0,
        no_pagemap = 0,
        failed = 0,
        failures = {},
        failure_log = {},
    }

    if progress_cb then
        progress_cb("scan_start", {
            path = path,
        })
    end

    local books, scanned_files = self:scanBooks(path, progress_cb)
    result.scanned_files = scanned_files
    result.metadata_books = #books

    if progress_cb then
        progress_cb("scan_done", {
            path = path,
            scanned_files = scanned_files,
            metadata_books = #books,
        })
    end

    for i, file in ipairs(books) do
        local progress_widget = progress and progress.widget or false
        local phase_log_path = progress and progress.log_path or nil
        local status, reason = self:migrateBook(
            file,
            chars_per_synthetic_page,
            synthetic_overrides,
            use_page_labels,
            show_page_labels,
            overwrite_differing_settings,
            progress_widget,
            phase_log_path
        )
        if status == "migrated" then
            result.migrated = result.migrated + 1
        elseif status == "already_ok" then
            result.already_ok = result.already_ok + 1
        elseif status == "not_crengine" then
            result.not_crengine = result.not_crengine + 1
        elseif status == "no_pagemap" then
            result.no_pagemap = result.no_pagemap + 1
        elseif status == "aborted" then
            return result, true
        else
            result.failed = result.failed + 1
            table.insert(result.failure_log, {
                file = file,
                reason = reason,
            })
            if #result.failures < 5 then
                table.insert(result.failures, {
                    file = file,
                    reason = reason,
                })
            end
        end

        if progress_cb then
            progress_cb("migrate", {
                path = path,
                current_file = file,
                current_index = i,
                total_books = #books,
                result = result,
            })
        end

        collectgarbage()
    end

    return result
end

function Migration:runMigration(path, chars_per_synthetic_page, synthetic_overrides,
                                use_page_labels, show_page_labels,
                                overwrite_differing_settings)
    local progress = {}
    local last_scan_update_files = -1
    local last_scan_update_dirs = 0
    local filename_stamp = os.date("%Y%m%d-%H%M%S")
    progress.log_path = string.format("%s/pagemap-populate-%s.log", DataStorage:getDataDir(), filename_stamp)
    util.writeToFile("", progress.log_path)
    self:updateProgress(progress, self:formatScanProgress(path, {
        dirs_scanned = 0,
        scanned_files = 0,
        metadata_books = 0,
    }))

    local function onProgress(phase, data)
        if phase == "scan_start" then
            self:updateProgress(progress, self:formatScanProgress(path, {
                dirs_scanned = 0,
                scanned_files = 0,
                metadata_books = 0,
            }))
        elseif phase == "scan" then
            local files_step_reached = data.scanned_files > 0 and data.scanned_files - last_scan_update_files >= 200
            local dirs_step_reached = (data.dirs_scanned or 0) - last_scan_update_dirs >= 25
            if not files_step_reached and not dirs_step_reached then
                return
            end
            last_scan_update_files = data.scanned_files
            last_scan_update_dirs = data.dirs_scanned or last_scan_update_dirs
            self:updateProgress(progress, self:formatScanProgress(path, data))
        elseif phase == "scan_done" then
            self:updateProgress(progress, self:formatScanProgress(path, data))
        elseif phase == "migrate" then
            self:updateProgress(progress, self:formatMigrationProgress(path, data))
        end
    end

    local ok, result_or_err, aborted = pcall(
        self.migrateBooks,
        self,
        path,
        chars_per_synthetic_page,
        synthetic_overrides,
        use_page_labels,
        show_page_labels,
        overwrite_differing_settings,
        onProgress,
        progress
    )
    self:closeProgress(progress)

    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Populate failed: %1"), tostring(result_or_err)),
            icon = "notice-warning",
        })
        return
    end

    if aborted then
        UIManager:show(InfoMessage:new{
            text = _("Populate aborted."),
        })
        return
    end

    if self.ui.file_chooser then
        self.ui.file_chooser:refreshPath()
    end
    UIManager:broadcastEvent(Event:new("BookMetadataChanged"))

    local result_text = self:formatResult(path, result_or_err)
    local has_problems = (result_or_err.failed or 0) > 0
        or (result_or_err.no_pagemap or 0) > 0
        or (result_or_err.not_crengine or 0) > 0
    if has_problems then
        local log_path, log_err = self:writeResultLog(
            path,
            result_or_err,
            chars_per_synthetic_page,
            synthetic_overrides,
            use_page_labels,
            show_page_labels,
            overwrite_differing_settings,
            progress.log_path
        )
        if log_path then
            result_text = result_text
                .. "\n\n"
                .. T(_("Log written to:\n%1"), log_path)
        elseif log_err then
            result_text = result_text
                .. "\n\n"
                .. T(_("Could not write log file: %1"), tostring(log_err))
        end
    elseif progress.log_path then
        pcall(os.remove, progress.log_path)
    end

    UIManager:show(ConfirmBox:new{
        text = result_text,
        icon = "notice-info",
        cancel_text = _("Close"),
        no_ok_button = true,
    })
end

return Migration
