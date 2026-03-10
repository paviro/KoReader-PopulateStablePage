local ConfirmBox = require("ui/widget/confirmbox")
local CheckButton = require("ui/widget/checkbutton")
local InfoMessage = require("ui/widget/infomessage")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = ffiUtil.template

local PageMapMigrate = WidgetContainer:extend{
    name = "populatestablepage",
    is_doc_only = false,
}

local function attachMethods(target, methods)
    for name, method in pairs(methods) do
        target[name] = method
    end
end

attachMethods(PageMapMigrate, require("populatestablepage_format"))
attachMethods(PageMapMigrate, require("populatestablepage_scan"))
attachMethods(PageMapMigrate, require("populatestablepage_worker"))
attachMethods(PageMapMigrate, require("populatestablepage_migration"))

function PageMapMigrate:init()
    if not self.ui.document then
        self.ui.menu:registerToMainMenu(self)
    end
end

function PageMapMigrate:addToMainMenu(menu_items)
    menu_items.pagemap_metadata_population = {
        text = _("Populate stable page metadata"),
        sorting_hint = "more_tools",
        callback = function()
            self:confirmMigration()
        end,
    }
end

function PageMapMigrate:showMigrationConfirm()
    local chars_per_synthetic_page = tonumber(G_reader_settings:readSetting("pagemap_chars_per_synthetic_page"))
    if not chars_per_synthetic_page or chars_per_synthetic_page <= 0 then
        UIManager:show(InfoMessage:new{
            text = _("Synthetic stable pages are not enabled globally.\n\nSet 'Characters per page' in:\nStable page numbers -> Default settings for new books."),
            icon = "notice-warning",
        })
        return
    end

    local path = self:getScanPath()
    if lfs.attributes(path, "mode") ~= "directory" then
        UIManager:show(InfoMessage:new{
            text = T(_("Cannot scan folder: %1"), path),
            icon = "notice-warning",
        })
        return
    end

    local synthetic_overrides = G_reader_settings:isTrue("pagemap_synthetic_overrides")
    local use_page_labels = G_reader_settings:isTrue("pagemap_use_page_labels")
    local show_page_labels = G_reader_settings:isTrue("pagemap_show_page_labels")
    local details_text = self:formatGlobalSettingsBlock(
        chars_per_synthetic_page,
        synthetic_overrides,
        use_page_labels,
        show_page_labels
    )

    local confirm_box, check_button_overwrite
    confirm_box = ConfirmBox:new{
        text = T(_("Scan %1 and subfolders for books with metadata missing stable page fields?"), path)
            .. "\n\n"
            .. details_text,
        ok_text = _("Populate"),
        ok_callback = function()
            local overwrite_differing_settings = check_button_overwrite and check_button_overwrite.checked
            UIManager:nextTick(function()
                Trapper:wrap(function()
                    self:runMigration(path, chars_per_synthetic_page, synthetic_overrides,
                                      use_page_labels, show_page_labels,
                                      overwrite_differing_settings)
                end)
            end)
        end,
    }
    check_button_overwrite = CheckButton:new{
        text = _("Overwrite per-book stable page settings when they differ from current global values."),
        checked = false,
        parent = confirm_box,
    }
    confirm_box:addWidget(check_button_overwrite)
    UIManager:show(confirm_box)
end

function PageMapMigrate:confirmMigration()
    local chars_per_synthetic_page = tonumber(G_reader_settings:readSetting("pagemap_chars_per_synthetic_page"))
    local synthetic_overrides = G_reader_settings:isTrue("pagemap_synthetic_overrides")
    if chars_per_synthetic_page == 1500 and synthetic_overrides then
        self:showMigrationConfirm()
        return
    end

    UIManager:show(ConfirmBox:new{
        text = _("Apply recommended global stable page defaults before populating metadata?")
            .. "\n\n"
            .. _("Recommended defaults:")
            .. "\n"
            .. T("  - %1: %2", _("Characters per synthetic page"), 1500)
            .. "\n"
            .. T("  - %1: %2", _("Override publisher page numbers"), _("yes"))
            .. "\n\n"
            .. _("Choose 'Keep current' to continue without changing these settings."),
        ok_text = _("Apply defaults"),
        cancel_text = _("Keep current"),
        ok_callback = function()
            G_reader_settings:saveSetting("pagemap_chars_per_synthetic_page", 1500)
            G_reader_settings:saveSetting("pagemap_synthetic_overrides", true)
            UIManager:nextTick(function()
                self:showMigrationConfirm()
            end)
        end,
        cancel_callback = function()
            UIManager:nextTick(function()
                self:showMigrationConfirm()
            end)
        end,
    })
end

return PageMapMigrate
