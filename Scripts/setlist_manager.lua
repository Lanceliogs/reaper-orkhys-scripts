-- @description Orkhys Setlist Manager
-- @author Lanceliogs
-- @version 1.0.0
-- @provides [main] .
-- @about
--   Reorderable live setlist manager for REAPER.
--   Decouples show order from timeline layout using regions.
--   Supports linked songs (auto-chain), persistent setlists, and JSON export/import.
--   Requires ReaImGui extension.

local r = reaper
local script_name = "Orkhys Setlist Manager"
local EXTSTATE_SECTION = "OrkhysSetlist"
local EXTSTATE_KEY = "ActiveSetlist"

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local ctx = nil
local font = nil
local font_large = nil

local all_regions = {}       -- {idx, name, start_time, end_time}
local setlist = {}           -- {{region_idx=N, linked=bool}, ...}
local current_index = 0      -- index into setlist (1-based, 0 = none)
local is_managing = false    -- whether the engine is actively controlling playback
local awaiting_trigger = false

-- ---------------------------------------------------------------------------
-- Region Discovery
-- ---------------------------------------------------------------------------

local function discover_regions()
  all_regions = {}
  local _, num_markers, num_regions = r.CountProjectMarkers(0)
  local i = 0
  while true do
    local retval, is_rgn, pos, rgnend, name, markrgnindexnumber = r.EnumProjectMarkers(i)
    if retval == 0 then break end
    if is_rgn then
      if name and name ~= "" and name:sub(1, 1) ~= "!" then
        table.insert(all_regions, {
          idx = markrgnindexnumber,
          name = name,
          start_time = pos,
          end_time = rgnend,
        })
      end
    end
    i = i + 1
  end
  table.sort(all_regions, function(a, b) return a.start_time < b.start_time end)
end

local function get_region_by_idx(region_idx)
  for _, rgn in ipairs(all_regions) do
    if rgn.idx == region_idx then return rgn end
  end
  return nil
end

local function get_region_name(region_idx)
  local rgn = get_region_by_idx(region_idx)
  return rgn and rgn.name or ("Region " .. region_idx)
end

-- ---------------------------------------------------------------------------
-- Setlist Data Model
-- ---------------------------------------------------------------------------

local function setlist_add(region_idx)
  table.insert(setlist, { region_idx = region_idx, linked = false })
end

local function setlist_remove(pos)
  table.remove(setlist, pos)
  if current_index > #setlist then current_index = #setlist end
  if current_index < 0 then current_index = 0 end
end

local function setlist_move_up(pos)
  if pos <= 1 then return end
  setlist[pos], setlist[pos - 1] = setlist[pos - 1], setlist[pos]
  if current_index == pos then current_index = pos - 1
  elseif current_index == pos - 1 then current_index = pos end
end

local function setlist_move_down(pos)
  if pos >= #setlist then return end
  setlist[pos], setlist[pos + 1] = setlist[pos + 1], setlist[pos]
  if current_index == pos then current_index = pos + 1
  elseif current_index == pos + 1 then current_index = pos end
end

local function setlist_toggle_link(pos)
  if setlist[pos] then
    setlist[pos].linked = not setlist[pos].linked
  end
end

local function is_in_setlist(region_idx)
  for _, entry in ipairs(setlist) do
    if entry.region_idx == region_idx then return true end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Persistence: ExtState
-- ---------------------------------------------------------------------------

local function save_to_extstate()
  local parts = {}
  for _, entry in ipairs(setlist) do
    table.insert(parts, entry.region_idx .. ":" .. (entry.linked and "1" or "0"))
  end
  local data = table.concat(parts, "|")
  r.SetExtState(EXTSTATE_SECTION, EXTSTATE_KEY, data, true)
end

local function load_from_extstate()
  local data = r.GetExtState(EXTSTATE_SECTION, EXTSTATE_KEY)
  if not data or data == "" then return end
  setlist = {}
  for token in data:gmatch("[^|]+") do
    local idx_str, linked_str = token:match("^(%d+):([01])$")
    if idx_str then
      local region_idx = tonumber(idx_str)
      if get_region_by_idx(region_idx) then
        table.insert(setlist, { region_idx = region_idx, linked = (linked_str == "1") })
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Persistence: JSON Export/Import
-- ---------------------------------------------------------------------------

local function json_escape(s)
  return s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
end

local function export_json(filepath)
  local f = io.open(filepath, "w")
  if not f then
    r.ShowMessageBox("Could not write to:\n" .. filepath, script_name, 0)
    return false
  end
  f:write('{\n')
  f:write('  "name": "' .. json_escape(filepath:match("([^/\\]+)%.json$") or "setlist") .. '",\n')
  f:write('  "entries": [\n')
  for i, entry in ipairs(setlist) do
    local name = json_escape(get_region_name(entry.region_idx))
    f:write('    {"region_name": "' .. name .. '", "region_idx": ' .. entry.region_idx .. ', "linked": ' .. tostring(entry.linked) .. '}')
    if i < #setlist then f:write(',') end
    f:write('\n')
  end
  f:write('  ]\n')
  f:write('}\n')
  f:close()
  return true
end

local function import_json(filepath)
  local f = io.open(filepath, "r")
  if not f then
    r.ShowMessageBox("Could not read:\n" .. filepath, script_name, 0)
    return false
  end
  local content = f:read("*a")
  f:close()

  local new_setlist = {}
  for region_idx_str, linked_str in content:gmatch('"region_idx"%s*:%s*(%d+)%s*,%s*"linked"%s*:%s*(%w+)') do
    local region_idx = tonumber(region_idx_str)
    if get_region_by_idx(region_idx) then
      table.insert(new_setlist, { region_idx = region_idx, linked = (linked_str == "true") })
    end
  end

  if #new_setlist == 0 then
    r.ShowMessageBox("No valid entries found in file.", script_name, 0)
    return false
  end

  setlist = new_setlist
  current_index = 0
  save_to_extstate()
  return true
end

-- ---------------------------------------------------------------------------
-- Playback Engine
-- ---------------------------------------------------------------------------

local function get_current_region()
  if current_index < 1 or current_index > #setlist then return nil end
  return get_region_by_idx(setlist[current_index].region_idx)
end

local function play_current()
  local rgn = get_current_region()
  if not rgn then return end
  r.SetEditCurPos(rgn.start_time, true, true)
  r.OnPlayButton()
  is_managing = true
  awaiting_trigger = false
end

local function stop_playback()
  r.OnStopButton()
  is_managing = false
  awaiting_trigger = false
end

local function advance_to_next()
  if current_index < #setlist then
    current_index = current_index + 1
    local rgn = get_current_region()
    if rgn then
      r.SetEditCurPos(rgn.start_time, true, true)
    end
  else
    current_index = 0
    is_managing = false
  end
end

local function go_to_entry(idx)
  if idx >= 1 and idx <= #setlist then
    current_index = idx
    local rgn = get_current_region()
    if rgn then
      r.SetEditCurPos(rgn.start_time, true, true)
    end
    awaiting_trigger = true
    is_managing = true
  end
end

local function engine_tick()
  if not is_managing then return end
  if awaiting_trigger then return end

  local play_state = r.GetPlayState()
  local is_playing = (play_state & 1) == 1

  if not is_playing then return end

  local rgn = get_current_region()
  if not rgn then
    is_managing = false
    return
  end

  local pos = r.GetPlayPosition()
  if pos >= rgn.end_time - 0.05 then
    r.OnStopButton()

    if current_index < #setlist then
      local was_linked = setlist[current_index].linked
      advance_to_next()
      if was_linked then
        play_current()
      else
        awaiting_trigger = true
      end
    else
      current_index = 0
      is_managing = false
    end
  end
end

-- ---------------------------------------------------------------------------
-- ImGui UI
-- ---------------------------------------------------------------------------

local function get_project_path()
  local proj_path = r.GetProjectPath()
  local sep = package.config:sub(1, 1)
  if proj_path:sub(-1) == sep then
    return proj_path:sub(1, -2)
  end
  return proj_path
end

local function draw_ui()
  local visible, open = r.ImGui_Begin(ctx, script_name, true, r.ImGui_WindowFlags_NoCollapse())
  if not open then
    r.ImGui_End(ctx)
    return false
  end
  if not visible then
    r.ImGui_End(ctx)
    return true
  end

  -- Header: current song + status
  r.ImGui_PushFont(ctx, font_large, 0)
  local status_text = ""
  if current_index > 0 then
    local rgn = get_current_region()
    local name = rgn and rgn.name or "???"
    local play_state = r.GetPlayState()
    local state_icon = ""
    if awaiting_trigger then state_icon = "[READY] "
    elseif (play_state & 1) == 1 then state_icon = "[PLAYING] "
    else state_icon = "[STOPPED] " end
    status_text = state_icon .. current_index .. "/" .. #setlist .. ": " .. name
  else
    status_text = "No song selected"
  end
  r.ImGui_TextWrapped(ctx, status_text)
  r.ImGui_PopFont(ctx)

  r.ImGui_Separator(ctx)

  -- Transport controls
  local is_playing = (r.GetPlayState() & 1) == 1
  local nav_locked = is_managing and not awaiting_trigger and is_playing

  r.ImGui_Spacing(ctx)
  if r.ImGui_Button(ctx, "Play##transport", 80, 28) then
    if not nav_locked then
      if current_index == 0 and #setlist > 0 then
        current_index = 1
      end
      play_current()
    end
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Stop##transport", 80, 28) then
    stop_playback()
  end
  r.ImGui_SameLine(ctx)
  if nav_locked then
    r.ImGui_BeginDisabled(ctx)
  end
  if r.ImGui_Button(ctx, "Next##transport", 80, 28) then
    advance_to_next()
    if current_index > 0 then
      awaiting_trigger = true
    end
  end
  if nav_locked then
    r.ImGui_EndDisabled(ctx)
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Refresh Regions", 120, 28) then
    discover_regions()
  end

  r.ImGui_Spacing(ctx)
  r.ImGui_Separator(ctx)
  r.ImGui_Spacing(ctx)

  -- Two-column layout
  local avail_w, avail_h = r.ImGui_GetContentRegionAvail(ctx)
  local panel_w = avail_w * 0.6 - 5
  local child_h = avail_h - 36

  -- Left panel: Setlist
  if r.ImGui_BeginChild(ctx, "##setlist_panel", panel_w, child_h) then
    r.ImGui_Text(ctx, "SETLIST (" .. #setlist .. " songs)")
    r.ImGui_Separator(ctx)

    local to_remove = nil
    local to_move_up = nil
    local to_move_down = nil

    local table_flags = r.ImGui_TableFlags_RowBg() | r.ImGui_TableFlags_BordersInnerH()
    if r.ImGui_BeginTable(ctx, "##setlist_table", 5) then
      r.ImGui_TableSetupColumn(ctx, "Song", r.ImGui_TableColumnFlags_WidthStretch())
      r.ImGui_TableSetupColumn(ctx, "Link?", r.ImGui_TableColumnFlags_WidthFixed(), 40)
      r.ImGui_TableSetupColumn(ctx, "Up", r.ImGui_TableColumnFlags_WidthFixed(), 22)
      r.ImGui_TableSetupColumn(ctx, "Dn", r.ImGui_TableColumnFlags_WidthFixed(), 22)
      r.ImGui_TableSetupColumn(ctx, "Rm", r.ImGui_TableColumnFlags_WidthFixed(), 22)
      r.ImGui_TableHeadersRow(ctx)

      for i, entry in ipairs(setlist) do
        r.ImGui_PushID(ctx, i)
        r.ImGui_TableNextRow(ctx)

        local is_current = (i == current_index)

        -- Column 1: Song name (selectable, disabled while playing)
        r.ImGui_TableNextColumn(ctx)
        if is_current then
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x00FF88FF)
        end
        local name = get_region_name(entry.region_idx)
        local label = string.format("%2d. %s", i, name)
        if nav_locked then
          r.ImGui_Selectable(ctx, label, is_current)
        else
          if r.ImGui_Selectable(ctx, label, is_current) then
            go_to_entry(i)
          end
        end
        if is_current then
          r.ImGui_PopStyleColor(ctx)
        end

        -- Column 2: Link checkbox
        r.ImGui_TableNextColumn(ctx)
        local changed
        changed, entry.linked = r.ImGui_Checkbox(ctx, "##link", entry.linked)
        if changed then save_to_extstate() end
        if r.ImGui_IsItemHovered(ctx) then
          r.ImGui_SetTooltip(ctx, "Enable auto link with next song")
        end

        -- Column 3: Move up
        r.ImGui_TableNextColumn(ctx)
        if r.ImGui_SmallButton(ctx, "\u{25B2}") then to_move_up = i end

        -- Column 4: Move down
        r.ImGui_TableNextColumn(ctx)
        if r.ImGui_SmallButton(ctx, "\u{25BC}") then to_move_down = i end

        -- Column 5: Remove
        r.ImGui_TableNextColumn(ctx)
        if r.ImGui_SmallButton(ctx, "X") then to_remove = i end

        r.ImGui_PopID(ctx)
      end

      r.ImGui_EndTable(ctx)
    end

    if to_move_up then setlist_move_up(to_move_up); save_to_extstate() end
    if to_move_down then setlist_move_down(to_move_down); save_to_extstate() end
    if to_remove then setlist_remove(to_remove); save_to_extstate() end

    r.ImGui_EndChild(ctx)
  end

  r.ImGui_SameLine(ctx)

  -- Right panel: Available songs
  local right_w = avail_w - panel_w - 5
  if r.ImGui_BeginChild(ctx, "##pool_panel", right_w, child_h) then
    r.ImGui_Text(ctx, "AVAILABLE SONGS")
    r.ImGui_Separator(ctx)

    for _, rgn in ipairs(all_regions) do
      if not is_in_setlist(rgn.idx) then
        if r.ImGui_Selectable(ctx, rgn.name .. "##pool_" .. rgn.idx) then
          setlist_add(rgn.idx)
          save_to_extstate()
        end
      end
    end

    r.ImGui_EndChild(ctx)
  end

  -- Footer: Save/Load
  r.ImGui_Separator(ctx)
  r.ImGui_Spacing(ctx)

  if r.ImGui_Button(ctx, "Export JSON", 100, 24) then
    local sep = package.config:sub(1, 1)
    local path = get_project_path() .. sep .. "setlist_" .. os.date("%Y%m%d_%H%M%S") .. ".json"
    if export_json(path) then
      r.ShowMessageBox("Setlist exported to:\n" .. path, script_name, 0)
    end
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Import JSON", 100, 24) then
    local retval, filename = r.GetUserFileNameForRead("", "Import Setlist JSON", "*.json")
    if retval then
      import_json(filename)
    end
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Add All", 80, 24) then
    for _, rgn in ipairs(all_regions) do
      if not is_in_setlist(rgn.idx) then
        setlist_add(rgn.idx)
      end
    end
    save_to_extstate()
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Clear", 80, 24) then
    setlist = {}
    current_index = 0
    save_to_extstate()
  end

  r.ImGui_End(ctx)
  return open
end

-- ---------------------------------------------------------------------------
-- Main Loop
-- ---------------------------------------------------------------------------

local function main_loop()
  engine_tick()

  r.ImGui_PushFont(ctx, font, 0)
  local keep_open = draw_ui()
  r.ImGui_PopFont(ctx)

  if keep_open then
    r.defer(main_loop)
  end
end

local function init()
  ctx = r.ImGui_CreateContext(script_name, r.ImGui_ConfigFlags_DockingEnable())
  font = r.ImGui_CreateFont("sans-serif", 14)
  font_large = r.ImGui_CreateFont("sans-serif", 20)
  r.ImGui_Attach(ctx, font)
  r.ImGui_Attach(ctx, font_large)

  discover_regions()
  load_from_extstate()

  main_loop()
end

init()
