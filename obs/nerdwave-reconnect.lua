-- Nerdwave reconnect for OBS Studio (macOS).
--
-- OBS's "macOS Audio Capture" in Application mode only looks up running apps when the source is created. If you
-- open Nerdwave after OBS, the source stays silent until you restart OBS. This script notices when Nerdwave starts
-- (or restarts) and relinks every source that captures Nerdwave, a few seconds later. No setup: it finds the
-- sources by the app they capture, whatever you named them.
--
-- Install: OBS > Tools > Scripts > + > choose this file.
obs = obslua

local BUNDLE = "com.nerdative.nerdwave"
local PROCESS = "Nerdwave"
local CHECK_MS = 3000

local last_pid = nil
local step = 0          -- 2: refresh the app list on the next tick; 1: restart the capture on the next tick

local function current_pid()
    local p = io.popen("/usr/bin/pgrep -xn " .. PROCESS)
    if p == nil then return nil end
    local pid = p:read("*l")
    p:close()
    if pid == nil or pid == "" then return nil end
    return pid
end

local function nerdwave_sources()
    local found = {}
    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, source in ipairs(sources) do
            if obs.obs_source_get_unversioned_id(source) == "sck_audio_capture" then
                local settings = obs.obs_source_get_settings(source)
                if obs.obs_data_get_string(settings, "application") == BUNDLE then
                    table.insert(found, obs.obs_source_get_name(source))
                end
                obs.obs_data_release(settings)
            end
        end
        obs.source_list_release(sources)
    end
    return found
end

-- The same step OBS runs when you change the capture method in the source's properties: rebuild the app list.
local function refresh_app_list(name)
    local source = obs.obs_get_source_by_name(name)
    if source == nil then return end
    local props = obs.obs_source_properties(source)
    local method = obs.obs_properties_get(props, "type")
    local settings = obs.obs_source_get_settings(source)
    if method ~= nil then obs.obs_property_modified(method, settings) end
    obs.obs_data_release(settings)
    obs.obs_properties_destroy(props)
    obs.obs_source_release(source)
end

-- Restart the capture with the rebuilt list so it finds the new Nerdwave process.
local function restart_capture(name)
    local source = obs.obs_get_source_by_name(name)
    if source == nil then return end
    local settings = obs.obs_source_get_settings(source)
    obs.obs_source_update(source, settings)
    obs.obs_data_release(settings)
    obs.obs_source_release(source)
    obs.script_log(obs.LOG_INFO, "reconnected " .. name .. " to Nerdwave")
end

local function check()
    if step == 1 then for _, name in ipairs(nerdwave_sources()) do restart_capture(name) end end
    if step == 2 then for _, name in ipairs(nerdwave_sources()) do refresh_app_list(name) end end
    if step > 0 then step = step - 1 end
    local pid = current_pid()
    if pid ~= nil and pid ~= last_pid then step = 2 end   -- give the app a moment to open its window
    last_pid = pid
end

function script_description()
    return "Relinks OBS audio capture sources for Nerdwave when Nerdwave starts after OBS (or restarts)."
end

function script_load(settings)
    last_pid = current_pid()
    obs.timer_add(check, CHECK_MS)
end

function script_unload()
    obs.timer_remove(check)
end
