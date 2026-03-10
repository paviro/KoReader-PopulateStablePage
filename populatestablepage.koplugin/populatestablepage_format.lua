local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local _ = require("gettext")
local N_ = _.ngettext
local T = ffiUtil.template
local Screen = Device.screen

local Format = {}

function Format:updateProgress(progress, text)
    if progress.text == text then
        return
    end
    progress.text = text
    if progress.widget then
        UIManager:close(progress.widget)
    end
    progress.widget = InfoMessage:new{
        text = text,
        dismissable = false,
        show_icon = false,
        width = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.5),
    }
    UIManager:show(progress.widget)
    UIManager:forceRePaint()
end

function Format:closeProgress(progress)
    if progress and progress.widget then
        UIManager:close(progress.widget)
        progress.widget = nil
    end
end

function Format:formatGlobalSettingsBlock(chars_per_synthetic_page, synthetic_overrides,
                                          use_page_labels, show_page_labels)
    local lines = {
        _("Books missing per-book stable page display settings will use current global values:"),
        "",
        _("Current global values:"),
        T("  - %1: %2", _("Characters per synthetic page"), chars_per_synthetic_page),
        T("  - %1: %2", _("Override publisher page numbers"), synthetic_overrides and _("yes") or _("no")),
        T("  - %1: %2", _("Use stable page numbers"), use_page_labels and _("yes") or _("no")),
        T("  - %1: %2", _("Show stable page numbers in margin"), show_page_labels and _("yes") or _("no")),
    }
    return table.concat(lines, "\n")
end

function Format:formatScanProgress(path, data)
    local lines = {
        _("Scanning folders…"),
        T(_("Folder: %1"), filemanagerutil.abbreviate(path)),
        "",
        T(_("Folders scanned: %1"), data.dirs_scanned or 0),
        T(_("Files checked: %1"), data.scanned_files or 0),
        T(_("Books with metadata found: %1"), data.metadata_books or 0),
    }
    return table.concat(lines, "\n")
end

function Format:writeResultLog(path, result, chars_per_synthetic_page, synthetic_overrides,
                               use_page_labels, show_page_labels,
                               overwrite_differing_settings, log_path)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    if not log_path then
        local filename_stamp = os.date("%Y%m%d-%H%M%S")
        log_path = string.format("%s/pagemap-populate-%s.log", DataStorage:getDataDir(), filename_stamp)
    end

    local lines = {
        "",
        _("=== Population Summary ==="),
        _("KOReader stable page metadata population log"),
        T(_("Date: %1"), timestamp),
        T(_("Folder: %1"), path),
        T(_("Characters per synthetic page: %1"), chars_per_synthetic_page),
        T(_("Override publisher page numbers: %1"), synthetic_overrides and _("yes") or _("no")),
        T(_("Use stable page numbers: %1"), use_page_labels and _("yes") or _("no")),
        T(_("Show stable page numbers in margin: %1"), show_page_labels and _("yes") or _("no")),
        T(_("Overwrite differing per-book settings: %1"), overwrite_differing_settings and _("yes") or _("no")),
        "",
        T(N_("Updated 1 book.", "Updated %1 books.", result.migrated), result.migrated),
        T(N_("1 book already had required metadata.", "%1 books already had required metadata.", result.already_ok), result.already_ok),
        T(N_("1 book had metadata but is not handled by crengine.", "%1 books had metadata but are not handled by crengine.", result.not_crengine), result.not_crengine),
        T(N_("1 book had no stable page map after loading.", "%1 books had no stable page map after loading.", result.no_pagemap), result.no_pagemap),
        T(N_("1 populate operation failed.", "%1 populate operations failed.", result.failed), result.failed),
    }

    if result.failed > 0 and result.failure_log and #result.failure_log > 0 then
        table.insert(lines, "")
        table.insert(lines, _("Failures:"))
        for i, failure in ipairs(result.failure_log) do
            table.insert(lines, T(_("%1) %2"), i, failure.file))
            if failure.reason then
                table.insert(lines, "   " .. tostring(failure.reason))
            end
        end
    end

    local file, err = io.open(log_path, "ab")
    if file then
        file:write(table.concat(lines, "\n"), "\n")
        file:close()
        return log_path
    end
    return nil, err
end

function Format:formatMigrationProgress(path, data)
    local result = data.result or {}
    local lines = {
        _("Populating missing stable page metadata…"),
        T(_("Folder: %1"), filemanagerutil.abbreviate(path)),
        "",
        T(_("Book %1 of %2"), data.current_index or 0, data.total_books or 0),
        T(_("Updated: %1"), result.migrated or 0),
        T(_("Already done: %1"), result.already_ok or 0),
        T(_("Skipped (non-crengine/no map): %1"), (result.not_crengine or 0) + (result.no_pagemap or 0)),
        T(_("Failed: %1"), result.failed or 0),
    }
    if data.current_file then
        table.insert(lines, "")
        table.insert(lines, T(_("Current: %1"), filemanagerutil.abbreviate(data.current_file)))
    end
    return table.concat(lines, "\n")
end

function Format:formatResult(path, result)
    local lines = {
        T(_("Folder: %1"), path),
        "",
    }

    local function addCountLine(count, single_text, plural_text)
        count = tonumber(count) or 0
        if count > 0 then
            table.insert(lines, T(N_(single_text, plural_text, count), count))
        end
    end

    addCountLine(result.migrated,
        "Updated 1 book.",
        "Updated %1 books.")
    addCountLine(result.already_ok,
        "1 book already had required metadata.",
        "%1 books already had required metadata.")
    addCountLine(result.not_crengine,
        "1 book had metadata but is not handled by crengine.",
        "%1 books had metadata but are not handled by crengine.")
    addCountLine(result.no_pagemap,
        "1 book had no stable page map after loading.",
        "%1 books had no stable page map after loading.")
    addCountLine(result.failed,
        "1 populate operation failed.",
        "%1 populate operations failed.")

    if #lines == 2 then
        table.insert(lines, _("No metadata changes were needed."))
    end

    if result.failed > 0 and #result.failures > 0 then
        table.insert(lines, "")
        table.insert(lines, _("First failures:"))
        for i, failure in ipairs(result.failures) do
            table.insert(lines, T(_("%1) %2"), i, failure.file))
            if failure.reason then
                table.insert(lines, "   " .. tostring(failure.reason))
            end
        end
    end

    return table.concat(lines, "\n")
end

return Format
