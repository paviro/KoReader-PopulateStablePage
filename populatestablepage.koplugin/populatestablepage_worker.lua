local BookList = require("ui/widget/booklist")
local DocSettings = require("docsettings")
local Trapper = require("ui/trapper")
local ffiUtil = require("ffi/util")
local util = require("util")
local _ = require("gettext")
local T = ffiUtil.template

local Worker = {}

local function hasDifferingBookSettings(doc_settings, chars_per_synthetic_page,
                                        use_page_labels, show_page_labels)
    local book_use_page_labels = doc_settings:readSetting("pagemap_use_page_labels")
    if book_use_page_labels ~= nil and book_use_page_labels ~= use_page_labels then
        return true
    end

    local book_show_page_labels = doc_settings:readSetting("pagemap_show_page_labels")
    if book_show_page_labels ~= nil and book_show_page_labels ~= show_page_labels then
        return true
    end

    local book_chars_per_synthetic_page = tonumber(doc_settings:readSetting("pagemap_chars_per_synthetic_page"))
    if book_chars_per_synthetic_page and book_chars_per_synthetic_page > 0
            and book_chars_per_synthetic_page ~= chars_per_synthetic_page then
        return true
    end

    return false
end

function Worker:getWorkerLastPhase(phase_log_path, file)
    if not phase_log_path then
        return nil
    end
    local trace = util.readFromFile(phase_log_path)
    if not trace or trace == "" then
        return nil
    end

    local last_phase, last_detail
    for line in trace:gmatch("[^\r\n]+") do
        local tag, _, line_file, phase, detail = line:match("^(%u+)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
        if tag == "PHASE" and line_file == file and phase and phase ~= "" then
            last_phase = phase
            last_detail = detail
        end
    end

    if not last_phase then
        return nil
    end
    if last_detail and last_detail ~= "" then
        return last_phase .. ": " .. last_detail
    end
    return last_phase
end

function Worker:migrateBook(file, chars_per_synthetic_page, synthetic_overrides,
                            use_page_labels, show_page_labels,
                            overwrite_differing_settings,
                            progress_widget, phase_log_path)
    local doc_settings = DocSettings:open(file)
    local existing_pages = tonumber(doc_settings:readSetting("pagemap_doc_pages"))
    local existing_use_page_labels = doc_settings:readSetting("pagemap_use_page_labels")
    local settings_differ = overwrite_differing_settings and hasDifferingBookSettings(
        doc_settings,
        chars_per_synthetic_page,
        use_page_labels,
        show_page_labels
    )
    if existing_pages and existing_pages > 0
            and existing_use_page_labels ~= nil
            and not settings_differ then
        return "already_ok"
    end

    local function crashReason()
        local phase = self:getWorkerLastPhase(phase_log_path, file)
        if phase then
            return T(_("Worker process crashed while processing this book (last phase: %1)."), phase)
        end
        return _("Worker process crashed while processing this book.")
    end

    local function runWorker(strategy_name, build_synthetic, save_synthetic_chars)
        local completed, status, reason = Trapper:dismissableRunInSubprocess(function()
            local DocSettings = require("docsettings")
            local DocumentRegistry = require("document/documentregistry")
            local _ = require("gettext")
            local filemanagerutil = require("apps/filemanager/filemanagerutil")

            local doc_settings = DocSettings:open(file)
            local existing_pages = tonumber(doc_settings:readSetting("pagemap_doc_pages"))
            local existing_use_page_labels = doc_settings:readSetting("pagemap_use_page_labels")
            local settings_differ = false
            if overwrite_differing_settings then
                local existing_show_page_labels = doc_settings:readSetting("pagemap_show_page_labels")
                local existing_chars_per_synthetic_page = tonumber(doc_settings:readSetting("pagemap_chars_per_synthetic_page"))
                settings_differ = (existing_use_page_labels ~= nil and existing_use_page_labels ~= use_page_labels)
                    or (existing_show_page_labels ~= nil and existing_show_page_labels ~= show_page_labels)
                    or (existing_chars_per_synthetic_page and existing_chars_per_synthetic_page > 0
                        and existing_chars_per_synthetic_page ~= chars_per_synthetic_page)
            end
            if existing_pages and existing_pages > 0
                    and existing_use_page_labels ~= nil
                    and not settings_differ then
                return "already_ok"
            end

            local function setPhase(phase, detail)
                local line = table.concat({
                    "PHASE|",
                    os.date("%Y-%m-%d %H:%M:%S"),
                    "|", file,
                    "|", phase or "",
                    "|", detail and tostring(detail) or "",
                    "\n",
                })
                if phase_log_path then
                    local trace_file = io.open(phase_log_path, "ab")
                    if trace_file then
                        trace_file:write(line)
                        trace_file:close()
                    end
                end
            end

            local function cleanPageLabel(label)
                if type(label) ~= "string" then
                    return label
                end
                return (label:gsub("[Pp][Aa][Gg][Ee]%s*", ""))
            end

            setPhase("start", strategy_name)

            setPhase("get_provider")
            local providers = DocumentRegistry:getProviders(file)
            local provider
            if providers then
                for _, p in ipairs(providers) do
                    if p.provider and p.provider.provider == "crengine" then
                        provider = p.provider
                        break
                    end
                end
            end
            if not provider then
                local fallback = DocumentRegistry:getProvider(file)
                if fallback and fallback.provider == "crengine" then
                    provider = fallback
                end
            end
            if not provider then
                setPhase("not_crengine")
                return "not_crengine"
            end

            setPhase("prepare_provider")
            local _, file_type = filemanagerutil.splitFileNameType(file)
            provider.is_fb2 = file_type:sub(1, 2) == "fb"
            provider.is_txt = file_type == "txt"

            setPhase("open_document")
            local document = DocumentRegistry:openDocument(file, provider)
            if not document then
                setPhase("open_document_failed")
                return "failed", _("Could not open document.")
            end

            local ok, sub_status, sub_reason = pcall(function()
                setPhase("load_document")
                if document.loadDocument and not document:loadDocument() then
                    setPhase("load_document_failed")
                    return "failed", _("Could not load document.")
                end

                if document.render then
                    setPhase("render_document")
                    document:render()
                end

                if build_synthetic and document.buildSyntheticPageMap then
                    setPhase("build_synthetic_pagemap", chars_per_synthetic_page)
                    document:buildSyntheticPageMap(chars_per_synthetic_page)
                end

                setPhase("get_pagemap")
                if not (document.hasPageMap and document:hasPageMap()) then
                    setPhase("no_pagemap")
                    return "no_pagemap"
                end

                local doc_pages = 0
                local current_page_label = nil
                if document.getPageMapCurrentPageLabel then
                    local label, _, count = document:getPageMapCurrentPageLabel()
                    doc_pages = tonumber(count) or 0
                    current_page_label = cleanPageLabel(label)
                end
                if doc_pages <= 0 then
                    setPhase("no_pagemap")
                    return "no_pagemap"
                end

                local book_use_page_labels = doc_settings:readSetting("pagemap_use_page_labels")
                if overwrite_differing_settings or book_use_page_labels == nil then
                    book_use_page_labels = use_page_labels
                end
                local needs_last_page_label = book_use_page_labels
                    and (overwrite_differing_settings
                        or doc_settings:readSetting("pagemap_last_page_label") == nil)
                local needs_current_page_label = book_use_page_labels
                    and (overwrite_differing_settings
                        or doc_settings:readSetting("pagemap_current_page_label") == nil)

                local last_page_label = nil
                if needs_last_page_label and document.getPageMapLastPageLabel then
                    last_page_label = cleanPageLabel(document:getPageMapLastPageLabel())
                end

                local restored_current_page_label = nil
                if needs_current_page_label then
                    local restored_location = false
                    local last_xpointer = doc_settings:readSetting("last_xpointer")
                    if last_xpointer and document.gotoXPointer then
                        setPhase("restore_location", "xpointer")
                        local restored = pcall(function()
                            document:gotoXPointer(last_xpointer)
                        end)
                        restored_location = restored
                    end
                    if not restored_location and document.gotoPage then
                        local last_page = tonumber(doc_settings:readSetting("last_page"))
                        if last_page and last_page > 0 then
                            if document.getPageCount then
                                local page_count = tonumber(document:getPageCount()) or 0
                                if page_count > 0 and last_page > page_count then
                                    last_page = page_count
                                end
                            end
                            if last_page > 0 then
                                setPhase("restore_location", last_page)
                                local restored = pcall(function()
                                    document:gotoPage(last_page)
                                end)
                                restored_location = restored
                            end
                        end
                    end
                    if restored_location and document.getPageMapCurrentPageLabel then
                        setPhase("get_pagemap_restored_current")
                        restored_current_page_label = cleanPageLabel(select(1, document:getPageMapCurrentPageLabel()))
                    end
                end

                setPhase("save_settings", doc_pages)
                doc_settings:saveSetting("pagemap_doc_pages", doc_pages)
                if overwrite_differing_settings
                        or doc_settings:readSetting("pagemap_use_page_labels") == nil then
                    doc_settings:saveSetting("pagemap_use_page_labels", book_use_page_labels)
                end
                if overwrite_differing_settings
                        or doc_settings:readSetting("pagemap_show_page_labels") == nil then
                    doc_settings:saveSetting("pagemap_show_page_labels", show_page_labels)
                end
                if needs_last_page_label and last_page_label and last_page_label ~= "" then
                    doc_settings:saveSetting("pagemap_last_page_label", last_page_label)
                end
                if needs_current_page_label then
                    local page_label_to_save = restored_current_page_label
                    if (not page_label_to_save or page_label_to_save == "")
                            and current_page_label and current_page_label ~= "" then
                        page_label_to_save = current_page_label
                    end
                    if page_label_to_save and page_label_to_save ~= "" then
                        doc_settings:saveSetting("pagemap_current_page_label", page_label_to_save)
                    end
                end
                if save_synthetic_chars or overwrite_differing_settings then
                    doc_settings:saveSetting("pagemap_chars_per_synthetic_page", chars_per_synthetic_page)
                end
                doc_settings:flush()
                setPhase("done", "migrated")
                return "migrated"
            end)

            setPhase("close_document")
            pcall(function()
                document:close()
            end)

            if not ok then
                setPhase("lua_error", tostring(sub_status))
                return "failed", tostring(sub_status)
            end
            setPhase("done", sub_status)
            return sub_status, sub_reason
        end, progress_widget)

        if progress_widget then
            progress_widget.dismiss_callback = nil
        end
        return completed, status, reason
    end

    local attempts
    if synthetic_overrides then
        attempts = {
            {
                strategy = "synthetic_override",
                build_synthetic = true,
                save_synthetic_chars = true,
            },
        }
    else
        attempts = {
            {
                strategy = "document_map",
                build_synthetic = false,
                save_synthetic_chars = false,
            },
            {
                strategy = "synthetic_fallback",
                build_synthetic = true,
                save_synthetic_chars = true,
            },
        }
    end

    local last_status, last_reason
    for i, attempt in ipairs(attempts) do
        local completed, status, reason = runWorker(
            attempt.strategy,
            attempt.build_synthetic,
            attempt.save_synthetic_chars
        )

        if not completed then
            return "aborted"
        end

        if status == "migrated" then
            pcall(function()
                BookList.setBookInfoCache(file, DocSettings:open(file))
            end)
            return status, reason
        end

        if status == "already_ok" or status == "not_crengine" then
            return status, reason
        end

        if not status then
            reason = crashReason()
        end

        last_status = status
        last_reason = reason

        if i < #attempts and (not status or status == "failed" or status == "no_pagemap") then
            -- Try next strategy.
        else
            break
        end
    end

    if not last_status then
        return "failed", last_reason or crashReason()
    end
    return last_status, last_reason
end

return Worker
