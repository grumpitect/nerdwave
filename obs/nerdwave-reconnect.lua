-- Nerdwave reconnect for OBS Studio (macOS).
--
-- OBS's "macOS Audio Capture" in Application mode links to the app when the source starts. If you open Nerdwave
-- after OBS, the source stays silent until you restart OBS. This script notices when Nerdwave starts and relinks
-- every source that captures Nerdwave a few seconds later. No setup: it finds the sources by the app they
-- capture, whatever you named them. (Quitting and reopening Nerdwave, or updating it, while OBS runs already
-- works on its own; only "not running, then running" triggers a relink.)
--
-- OBS runs scripts on the thread that draws frames, so the script never waits on other programs: one small
-- background checker (it stops by itself when OBS quits) writes Nerdwave's pid to a file every 2 s, and the
-- script only reads that file.
--
-- Install: OBS > Tools > Scripts > + > choose this file.
obs = obslua

local BUNDLE = "com.nerdative.nerdwave"
local CHECK_MS = 2000
local DIR = os.getenv("TMPDIR") or "/tmp/"
local RESULTS = DIR .. "nerdwave-obs-pid.txt"
local CHECKER_PID = DIR .. "nerdwave-obs-checker.pid"

local running = nil     -- true/false once known
local step = 0          -- 2: refresh the app list on the next check; 1: restart the capture on the next check

local function stop_checker()
    local f = io.open(CHECKER_PID, "r")
    if f == nil then return end
    local pid = f:read("*l")
    f:close()
    if pid ~= nil and pid:match("^%d+$") then os.execute("kill " .. pid .. " >/dev/null 2>&1") end
    os.remove(CHECKER_PID)
end

local function start_checker()
    stop_checker()
    os.remove(RESULTS)
    -- $PPID is OBS (the shell OBS starts for os.execute); the loop ends when OBS is gone.
    local loop = "while kill -0 $PPID 2>/dev/null; do /usr/bin/pgrep -xn Nerdwave > '" .. RESULTS .. ".new'; mv -f '"
        .. RESULTS .. ".new' '" .. RESULTS .. "'; sleep 2; done"
    os.execute("( " .. loop .. " ) >/dev/null 2>&1 & echo $! > '" .. CHECKER_PID .. "'")
end

local function nerdwave_running()
    local f = io.open(RESULTS, "r")
    if f == nil then return nil end
    local pid = f:read("*l")
    f:close()
    return pid ~= nil and pid ~= ""
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

-- Restart the capture with the rebuilt list so it finds Nerdwave (restarting without the refresh disconnects it).
local function restart_capture(name)
    local source = obs.obs_get_source_by_name(name)
    if source == nil then return end
    local settings = obs.obs_source_get_settings(source)
    obs.obs_source_update(source, settings)
    obs.obs_data_release(settings)
    obs.obs_source_release(source)
    obs.script_log(obs.LOG_INFO, "relinked " .. name .. " to Nerdwave")
end

local function check()
    if step == 1 then for _, name in ipairs(nerdwave_sources()) do restart_capture(name) end end
    if step == 2 then for _, name in ipairs(nerdwave_sources()) do refresh_app_list(name) end end
    if step > 0 then step = step - 1 end
    local now = nerdwave_running()
    if now ~= nil then
        if now and running == false then step = 2 end
        running = now
    end
end

function script_description()
    return "Relinks OBS audio capture sources for Nerdwave when Nerdwave starts after OBS."
end

function script_load(settings)
    start_checker()
    obs.timer_add(check, CHECK_MS)
end

function script_unload()
    obs.timer_remove(check)
    stop_checker()
end
