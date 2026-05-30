-- @description Sparkd Controller
-- @author Lanceliogs
-- @version 1.0.0
-- @provides [main] .
-- @about
--   Allow to remotely control the sparkd engine.
--   Requires ReaImGui extension.

-- Dependency check
if not reaper.ImGui_CreateContext then
  reaper.MB(
    "This script requires the ReaImGui extension.\n\n" ..
    "Install it via Extensions > ReaPack > Browse packages > search 'ReaImGui'.",
    "sparkd Control - Missing Dependency", 0)
  return
end

-- Config
local SCRIPT_NAME = "sparkd Control"
local EXT_SECTION = "sparkd_reaper"
local POLL_INTERVAL = 0.250
local EXEC_TIMEOUT = 1000

-- Colors (RGBA hex)
local COL_GREEN     = 0x4ADE80FF
local COL_RED       = 0xF87171FF
local COL_ORANGE    = 0xFBBF24FF
local COL_GRAY      = 0x6B7280FF
local COL_DIM       = 0x9CA3AFFF
local COL_SUCCESS   = 0x34D399FF
local COL_BG_DARK   = 0x1F2937FF
local COL_BG_CARD   = 0x374151FF
local COL_ACCENT    = 0x60A5FAFF

-- State
local ctx = reaper.ImGui_CreateContext(SCRIPT_NAME)
local font_main = reaper.ImGui_CreateFont("sans-serif", 15)
local font_large = reaper.ImGui_CreateFont("sans-serif", 22)
reaper.ImGui_Attach(ctx, font_main)
reaper.ImGui_Attach(ctx, font_large)

local state = {
  project_path = "",
  http_addr = reaper.GetExtState(EXT_SECTION, "http_addr"),
  notenames_dir = reaper.GetExtState(EXT_SECTION, "notenames_dir"),
  sparkctl_path = reaper.GetExtState(EXT_SECTION, "sparkctl_path"),
  spark_reaper_path = reaper.GetExtState(EXT_SECTION, "spark_reaper_path"),

  engine_running = false,
  engine_blackout = false,
  last_poll = 0,
  last_error = "",
  last_error_time = 0,
  last_notenames_msg = "",
  last_notenames_time = 0,
  show_settings = false,
  daemon_reachable = false,
  connected = false, -- user-initiated connection state
}

-- Defaults
if state.http_addr == "" then state.http_addr = "127.0.0.1:7600" end
if state.sparkctl_path == "" then state.sparkctl_path = "sparkctl" end
if state.spark_reaper_path == "" then state.spark_reaper_path = "spark-reaper" end

-- Helpers

local function save_ext_state()
  reaper.SetExtState(EXT_SECTION, "http_addr", state.http_addr, true)
  reaper.SetExtState(EXT_SECTION, "notenames_dir", state.notenames_dir, true)
  reaper.SetExtState(EXT_SECTION, "sparkctl_path", state.sparkctl_path, true)
  reaper.SetExtState(EXT_SECTION, "spark_reaper_path", state.spark_reaper_path, true)
end

local function exec(cmd)
  local result = reaper.ExecProcess(cmd, EXEC_TIMEOUT)
  if not result or result == "" then
    return nil, "Failed to execute: " .. cmd
  end
  local exit_code_str, output = result:match("^(%d+)\n(.*)")
  if not exit_code_str then
    exit_code_str = result:match("^(%d+)")
    output = ""
  end
  local exit_code = tonumber(exit_code_str) or -1
  if exit_code ~= 0 then
    return nil, (output and output ~= "") and output or ("Exit code: " .. tostring(exit_code))
  end
  return output or "", nil
end

local function sparkctl(command)
  local cmd = string.format('%s --http %s %s',
    state.sparkctl_path, state.http_addr, command)
  return exec(cmd)
end

local function set_error(msg)
  state.last_error = msg or ""
  state.last_error_time = reaper.time_precise()
end

local function poll_status()
  if not state.connected then return end

  local now = reaper.time_precise()
  if now - state.last_poll < POLL_INTERVAL then return end
  state.last_poll = now

  local output, err = sparkctl("status")
  if err then
    state.daemon_reachable = false
    state.engine_running = false
    state.engine_blackout = false
    state.connected = false
    set_error("Connection lost")
    return
  end

  state.daemon_reachable = true
  state.engine_running = output:match("running:%s*yes") ~= nil
  state.engine_blackout = output:match("blackout:%s*yes") ~= nil

  local ppath = output:match("project:%s*(.-)%s*$")
  if ppath and ppath ~= "" then
    state.project_path = ppath
  end
end

local function try_connect()
  local output, err = sparkctl("status")
  if err then
    state.connected = false
    state.daemon_reachable = false
    set_error("Cannot reach sparkd at " .. state.http_addr)
    return
  end
  state.connected = true
  state.daemon_reachable = true
  state.last_error = ""
  state.engine_running = output:match("running:%s*yes") ~= nil
  state.engine_blackout = output:match("blackout:%s*yes") ~= nil

  local ppath = output:match("project:%s*(.-)%s*$")
  if ppath and ppath ~= "" then
    state.project_path = ppath
  end
end

local function force_poll()
  state.last_poll = 0
  poll_status()
end

local function basename(path)
  return path:match("[/\\]([^/\\]+)$") or path
end

-- UI Drawing

local function draw_header()
  reaper.ImGui_PushFont(ctx, font_large, 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_ACCENT)
  reaper.ImGui_Text(ctx, "SPARKD")
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopFont(ctx)

  reaper.ImGui_SameLine(ctx, 0, 8)
  reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + 6)

  if not state.connected then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_GRAY)
    reaper.ImGui_Text(ctx, "disconnected")
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_SameLine(ctx, 0, 16)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x166534FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x15803DFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x16A34AFF)
    if reaper.ImGui_Button(ctx, "CONNECT", 80, 24) then
      try_connect()
    end
    reaper.ImGui_PopStyleColor(ctx, 3)
  elseif state.engine_running then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_GREEN)
    reaper.ImGui_Text(ctx, "running")
    reaper.ImGui_PopStyleColor(ctx)
  else
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_ORANGE)
    reaper.ImGui_Text(ctx, "stopped")
    reaper.ImGui_PopStyleColor(ctx)
  end

  reaper.ImGui_Spacing(ctx)
end

local function draw_project_section()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_DIM)
  reaper.ImGui_Text(ctx, "PROJECT")
  reaper.ImGui_PopStyleColor(ctx)

  local display = state.project_path ~= "" and basename(state.project_path) or "No project selected"
  reaper.ImGui_Text(ctx, display)

  if state.project_path ~= "" then
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, state.project_path)
    end
  end

  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, " Load project... ") then
    local init_dir = ""
    if state.project_path ~= "" then
      init_dir = state.project_path:match("^(.*)[/\\]") or ""
    end
    if init_dir == "" then
      init_dir = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
    end
    local init_path = init_dir ~= "" and (init_dir .. "/") or ""
    local rv, file = reaper.GetUserFileNameForRead(init_path, "Select sparkd project", "yaml")
    if rv then
      state.project_path = file
      -- Stop engine first if running, then load the new project
      if state.engine_running then
        sparkctl("stop")
      end
      local _, err = sparkctl(string.format('reload "%s"', state.project_path:gsub("\\", "/")))
      set_error(err)
      force_poll()
    end
  end

  reaper.ImGui_Spacing(ctx)
end

local function draw_engine_controls()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_DIM)
  reaper.ImGui_Text(ctx, "ENGINE")
  reaper.ImGui_PopStyleColor(ctx)

  -- Big action buttons in a row
  local btn_w = 80
  local btn_h = 28

  if state.engine_running then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x991B1BFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xB91C1CFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0xDC2626FF)
    if reaper.ImGui_Button(ctx, "STOP", btn_w, btn_h) then
      local _, err = sparkctl("stop")
      set_error(err)
      force_poll()
    end
    reaper.ImGui_PopStyleColor(ctx, 3)
  else
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x166534FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x15803DFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x16A34AFF)
    if reaper.ImGui_Button(ctx, "START", btn_w, btn_h) then
      local _, err = sparkctl("start")
      set_error(err)
      force_poll()
    end
    reaper.ImGui_PopStyleColor(ctx, 3)
  end

  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x1E3A5FFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x1E40AFFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x2563EBFF)
  if reaper.ImGui_Button(ctx, "RELOAD", btn_w, btn_h) then
    if state.project_path == "" then
      set_error("No project file selected")
    else
      local _, err = sparkctl('reload')
      set_error(err)
      force_poll()
    end
  end
  reaper.ImGui_PopStyleColor(ctx, 3)

  reaper.ImGui_SameLine(ctx, 0, 16)

  -- Blackout as a toggle-style button
  if state.engine_blackout then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x991B1BFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xB91C1CFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0xDC2626FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFFFFFFF)
    if reaper.ImGui_Button(ctx, "BLACKOUT", btn_w, btn_h) then
      local _, err = sparkctl("clear-blackout")
      set_error(err)
      force_poll()
    end
    reaper.ImGui_PopStyleColor(ctx, 4)
  else
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x374151FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x4B5563FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x6B7280FF)
    if reaper.ImGui_Button(ctx, "BLACKOUT", btn_w, btn_h) then
      local _, err = sparkctl("set-blackout")
      set_error(err)
      force_poll()
    end
    reaper.ImGui_PopStyleColor(ctx, 3)
  end

  reaper.ImGui_Spacing(ctx)
end

local function draw_notenames_section()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_DIM)
  reaper.ImGui_Text(ctx, "REAPER TOOLS")
  reaper.ImGui_PopStyleColor(ctx)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x3730A3FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x4338CAFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x4F46E5FF)
  if reaper.ImGui_Button(ctx, "Generate Note Names", 180, 28) then
    if state.project_path == "" then
      set_error("No project file selected")
    else
      local dir_arg = ""
      if state.notenames_dir ~= "" then
        dir_arg = string.format(' -o "%s"', state.notenames_dir)
      end
      local cmd = string.format('%s note-names%s "%s"',
        state.spark_reaper_path, dir_arg, state.project_path)
      local output, err = exec(cmd)
      if err then
        set_error(err)
        state.last_notenames_msg = ""
      else
        set_error(nil)
        state.last_notenames_msg = output or "Done"
        state.last_notenames_time = reaper.time_precise()
      end
    end
  end
  reaper.ImGui_PopStyleColor(ctx, 3)

  -- Show result message
  if state.last_notenames_msg ~= "" then
    local age = reaper.time_precise() - state.last_notenames_time
    if age < 10 then
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_SUCCESS)
      reaper.ImGui_Text(ctx, state.last_notenames_msg)
      reaper.ImGui_PopStyleColor(ctx)
    else
      state.last_notenames_msg = ""
    end
  end

  reaper.ImGui_Spacing(ctx)
end

local function draw_error()
  if state.last_error == "" then return end

  -- Auto-dismiss after 15 seconds
  if reaper.time_precise() - state.last_error_time > 15 then
    state.last_error = ""
    return
  end

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0x7F1D1D99)
  reaper.ImGui_BeginChild(ctx, "error_bar", 0, 30, reaper.ImGui_ChildFlags_Borders())

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_RED)
  reaper.ImGui_Text(ctx, state.last_error)
  reaper.ImGui_PopStyleColor(ctx)

  reaper.ImGui_SameLine(ctx, reaper.ImGui_GetContentRegionAvail(ctx) - 20)
  if reaper.ImGui_SmallButton(ctx, "X") then
    state.last_error = ""
  end

  reaper.ImGui_EndChild(ctx)
  reaper.ImGui_PopStyleColor(ctx)

  reaper.ImGui_Spacing(ctx)
end

local function draw_footer()
  reaper.ImGui_Separator(ctx)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_GRAY)

  local status_icon = state.daemon_reachable and "+" or "-"
  reaper.ImGui_Text(ctx, string.format("[%s] %s", status_icon, state.http_addr))

  reaper.ImGui_SameLine(ctx, reaper.ImGui_GetContentRegionAvail(ctx) - 50)
  reaper.ImGui_PopStyleColor(ctx)

  if reaper.ImGui_SmallButton(ctx, state.show_settings and "Close" or "Settings") then
    state.show_settings = not state.show_settings
  end

  if state.show_settings then
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Indent(ctx, 8)

    local changed
    changed, state.http_addr = reaper.ImGui_InputText(ctx, "Address", state.http_addr)
    if changed then save_ext_state(); force_poll() end

    changed, state.notenames_dir = reaper.ImGui_InputText(ctx, "Output Dir", state.notenames_dir)
    if changed then save_ext_state() end

    changed, state.sparkctl_path = reaper.ImGui_InputText(ctx, "sparkctl", state.sparkctl_path)
    if changed then save_ext_state() end

    changed, state.spark_reaper_path = reaper.ImGui_InputText(ctx, "spark-reaper", state.spark_reaper_path)
    if changed then save_ext_state() end

    reaper.ImGui_Unindent(ctx, 8)
  end
end

-- Main loop

local function loop()
  poll_status()

  reaper.ImGui_PushFont(ctx, font_main, 0)
  reaper.ImGui_SetNextWindowSize(ctx, 400, 280, reaper.ImGui_Cond_FirstUseEver())
  reaper.ImGui_SetNextWindowDockID(ctx, -1, reaper.ImGui_Cond_FirstUseEver())

  -- Dark window styling
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), 0x111827F2)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBg(), 0x1F2937FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBgActive(), 0x1F2937FF)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 12, 12)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 8, 6)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4)

  local visible, open = reaper.ImGui_Begin(ctx, SCRIPT_NAME, true,
    reaper.ImGui_WindowFlags_NoCollapse())

  if visible then
    draw_header()
    draw_error()
    draw_project_section()
    if state.connected then
      draw_engine_controls()
    end
    draw_notenames_section()
    draw_footer()
    reaper.ImGui_End(ctx)
  end

  reaper.ImGui_PopStyleVar(ctx, 3)
  reaper.ImGui_PopStyleColor(ctx, 3)
  reaper.ImGui_PopFont(ctx)

  if open then
    reaper.defer(loop)
  end
end

try_connect()
reaper.defer(loop)
