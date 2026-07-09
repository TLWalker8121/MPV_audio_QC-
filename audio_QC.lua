--[[
    MPV Audio QC Overlay
    ---------------------
    A lightweight, real-time audio QC panel for MPV.

    Ctrl+Shift+A     Toggle the overlay on/off
    Ctrl+Shift+1..8  Isolate that channel (mutes all others, keeps layout)
    Ctrl+Shift+0     Return to normal monitoring (clears isolation)

    Requires MPV built with libavfilter (the default in virtually all
    modern builds) since it relies on the `astats` and `pan` filters.
--]]

local msg = require 'mp.msg'

----------------------------------------------------------------------
-- Configuration
----------------------------------------------------------------------

local REFRESH_INTERVAL  = 0.15   -- seconds between overlay redraws
local SILENCE_THRESHOLD = -60    -- dBFS at/below this counts as "Silent"
local BAR_LENGTH        = 8      -- characters in the level bar
local BAR_FLOOR_DB      = -60    -- dB mapped to an empty bar
local BAR_CEIL_DB       = 0      -- dB mapped to a full bar
local OSD_POS           = "\\an7\\pos(20,20)"  -- top-left corner; change
                                                -- to \\an9\\pos(W-20,20) etc.
                                                -- to reposition

local STATS_LABEL = "@qcstats"   -- af label used for the astats filter
local PAN_LABEL    = "@qcpan"     -- af label used for the isolation filter

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

local state = {
    overlay_active  = false,
    isolate_channel = nil,   -- 1-based channel number, or nil
    timer           = nil,
}

local overlay = mp.create_osd_overlay("ass-events")

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

-- Returns channel_count (number), layout (string), or nil if no audio.
local function get_audio_info()
    local ap = mp.get_property_native("audio-params")
    if not ap or not ap["channel-count"] or ap["channel-count"] == 0 then
        return nil, nil
    end
    return ap["channel-count"], ap["channels"]
end

-- Builds a layout-preserving pan filter string that passes only
-- `isolate_index` (1-based) through and zeroes every other channel.
local function build_pan_filter(channel_count, layout, isolate_index)
    local parts = {}
    for i = 0, channel_count - 1 do
        if i == isolate_index - 1 then
            parts[#parts + 1] = string.format("c%d=c%d", i, i)
        else
            parts[#parts + 1] = string.format("c%d=0*c%d", i, i)
        end
    end
    return string.format("pan=%s|%s", layout, table.concat(parts, "|"))
end

-- Adds a filter to the af chain and reports whether it actually
-- initialized. `mp.commandv` alone doesn't surface init failures, so
-- filters can silently fail to insert while playback continues
-- unmodified through the rest of the chain -- that's what causes
-- isolation to appear to do nothing.
--
-- `use_lavfi` wraps the filter in lavfi=[...] rather than passing it
-- as a bare option. On this setup, `pan` needs that wrapper to
-- initialize at all, but `astats` needs to stay bare -- wrapping it
-- breaks the per-channel metadata mpv exposes via af-metadata, which
-- is what the overlay's dB readout depends on.
local function try_add_af(label, filter_body, use_lavfi)
    local filter_str
    if use_lavfi then
        filter_str = string.format("%s:lavfi=[%s]", label, filter_body)
    else
        filter_str = string.format("%s:%s", label, filter_body)
    end
    local _, err = mp.command_native({"af", "add", filter_str})
    if err then
        msg.warn(string.format("failed to add filter '%s': %s", filter_str, tostring(err)))
        return false
    end
    return true
end

-- Rebuilds the audio filter chain from current state.
-- Order matters: astats is inserted BEFORE pan, so the per-channel
-- levels shown always reflect the original signal, not the muted
-- post-isolation signal. The pan filter (if any) is what actually
-- isolates the channel for playback.
local function apply_filters()
    pcall(mp.commandv, "af", "remove", PAN_LABEL)
    pcall(mp.commandv, "af", "remove", STATS_LABEL)

    if not state.overlay_active then
        return
    end

    try_add_af(STATS_LABEL, "astats=metadata=1:reset=1", false)

    if state.isolate_channel then
        local channel_count, layout = get_audio_info()
        if channel_count then
            local isolated = false

            -- Try the named layout mpv reports (e.g. "5.1", "7.1(wide)")
            -- first, since that preserves proper speaker-position
            -- metadata on the output.
            if layout then
                local pan = build_pan_filter(channel_count, layout, state.isolate_channel)
                isolated = try_add_af(PAN_LABEL, pan, true)
            end

            -- Some layout name strings mpv reports aren't accepted by
            -- ffmpeg's pan filter as-is. Fall back to a plain
            -- "<N>c" channel-count layout, which pan always accepts
            -- regardless of naming -- it just won't carry a named
            -- speaker layout on the output.
            if not isolated then
                local fallback_layout = channel_count .. "c"
                local pan = build_pan_filter(channel_count, fallback_layout, state.isolate_channel)
                isolated = try_add_af(PAN_LABEL, pan, true)
            end

            if not isolated then
                mp.osd_message(string.format(
                    "Audio QC: could not isolate channel %d (see console)",
                    state.isolate_channel))
            end
        end
    end
end

local function db_to_bar(db)
    if not db then
        return string.rep("░", BAR_LENGTH)
    end
    local norm = (db - BAR_FLOOR_DB) / (BAR_CEIL_DB - BAR_FLOOR_DB)
    if norm < 0 then norm = 0 end
    if norm > 1 then norm = 1 end
    local filled = math.floor(norm * BAR_LENGTH + 0.5)
    return string.rep("█", filled) .. string.rep("░", BAR_LENGTH - filled)
end

local function parse_rms(meta, channel_index)
    if not meta then return nil end
    local key = string.format("lavfi.astats.%d.RMS_level", channel_index)
    local raw = meta[key]
    if not raw or raw == "-inf" then
        return nil
    end
    return tonumber(raw)
end

----------------------------------------------------------------------
-- Rendering
----------------------------------------------------------------------

local function build_ass()
    local channel_count, layout = get_audio_info()
    if not channel_count then
        return string.format(
            "{%s\\fs20\\fnMonospace\\bord1\\shad0\\c&HFFFFFF&}Audio QC\\N\\NNo audio track detected",
            OSD_POS)
    end

    local meta = mp.get_property_native("af-metadata/" .. STATS_LABEL:sub(2))

    local lines = {}
    lines[#lines + 1] = "Audio QC"
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("Channels: %d", channel_count)
    lines[#lines + 1] = string.format("Layout: %s", layout or "Unknown")

    if state.isolate_channel then
        lines[#lines + 1] = string.format("Monitor: ISOLATE Ch%d — layout preserved", state.isolate_channel)
    else
        lines[#lines + 1] = "Monitor: Normal"
    end
    lines[#lines + 1] = ""

    local used = 0
    for ch = 1, channel_count do
        local db = parse_rms(meta, ch)
        local is_silent = (db == nil) or (db <= SILENCE_THRESHOLD)
        local bar = db_to_bar(db)

        local status
        if state.isolate_channel and state.isolate_channel ~= ch then
            status = "muted"
        elseif state.isolate_channel == ch then
            status = is_silent and "Silent ISOLATED" or string.format("%.0f dB ISOLATED", db)
        else
            status = is_silent and "Silent" or string.format("%.0f dB", db)
        end

        if not is_silent then
            used = used + 1
        end

        lines[#lines + 1] = string.format("Ch%-2d %s %s", ch, bar, status)
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("Used Channels: %d / %d", used, channel_count)

    local body = table.concat(lines, "\\N")
    return string.format("{%s\\fs20\\fnMonospace\\bord1\\shad0\\c&HFFFFFF&}%s", OSD_POS, body)
end

local function refresh_overlay()
    if not state.overlay_active then return end
    overlay.data = build_ass()
    overlay:update()
end

----------------------------------------------------------------------
-- Toggle / isolate actions
----------------------------------------------------------------------

local function stop_timer()
    if state.timer then
        state.timer:kill()
        state.timer = nil
    end
end

local function enable_overlay()
    state.overlay_active = true
    apply_filters()
    stop_timer()
    state.timer = mp.add_periodic_timer(REFRESH_INTERVAL, refresh_overlay)
    refresh_overlay()
end

local function disable_overlay()
    state.overlay_active = false
    stop_timer()
    overlay:remove()
    apply_filters()
end

local function toggle_overlay()
    if state.overlay_active then
        disable_overlay()
    else
        enable_overlay()
    end
end

local function isolate_channel(n)
    local channel_count = get_audio_info()
    if not channel_count then
        mp.osd_message("Audio QC: no audio track detected")
        return
    end
    if n > channel_count then
        mp.osd_message(string.format(
            "Audio QC: channel %d not available (only %d channels)", n, channel_count))
        return
    end
    state.isolate_channel = n
    apply_filters()
    if state.overlay_active then
        refresh_overlay()
    else
        mp.osd_message(string.format("Audio QC: isolating channel %d", n))
    end
end

local function clear_isolation()
    state.isolate_channel = nil
    apply_filters()
    if state.overlay_active then
        refresh_overlay()
    else
        mp.osd_message("Audio QC: normal monitoring")
    end
end

----------------------------------------------------------------------
-- Key bindings
----------------------------------------------------------------------

mp.add_key_binding("Ctrl+Shift+a", "qc-toggle-overlay", toggle_overlay)

for i = 1, 8 do
    mp.add_key_binding("Ctrl+Shift+" .. i, "qc-isolate-" .. i, function() isolate_channel(i) end)
end

mp.add_key_binding("Ctrl+Shift+0", "qc-clear-isolation", clear_isolation)

----------------------------------------------------------------------
-- File / shutdown handling
----------------------------------------------------------------------

-- Isolation doesn't carry over to a new file (channel counts/layouts
-- may differ), but the overlay on/off state persists.
mp.register_event("file-loaded", function()
    state.isolate_channel = nil
    if state.overlay_active then
        apply_filters()
    end
end)

mp.register_event("shutdown", function()
    stop_timer()
    pcall(mp.commandv, "af", "remove", PAN_LABEL)
    pcall(mp.commandv, "af", "remove", STATS_LABEL)
end)