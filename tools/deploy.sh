# copy the mod source into the game's unpacked mod and hot-reload the extension (needs the game's
# local MCP server on: Options, or -enablemcp). BEAMNG_USER overrides the game's user folder.
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../co_driver_coach"
USERDIR="${BEAMNG_USER:-$LOCALAPPDATA/BeamNG/BeamNG.drive/current}"
USERDIR="$(cygpath -u "$USERDIR" 2>/dev/null || echo "$USERDIR")"
mkdir -p "$USERDIR/mods/unpacked/co_driver_coach"
cp -r "$SRC/." "$USERDIR/mods/unpacked/co_driver_coach/"
python -I "$HERE/bmcp.py" run_lua 'local r = {} for _, n in ipairs({"coDriverCoach", "coDriverAnalysis", "coDriverEngineer", "coDriverLaps"}) do extensions.unload(n) setExtensionUnloadMode(n, "manual") extensions.load(n) r[#r + 1] = n .. "=" .. tostring(extensions.isExtensionLoaded(n)) end local v = getPlayerVehicle(0) if v then v:queueLuaCommand("extensions.unload(\"coDriverRec\") extensions.load(\"coDriverRec\")") end return table.concat(r, " ")'
# hard-reload the UI so the game never keeps serving a cached copy of an older panel
python -I "$HERE/bmcp.py" reload_ui '{}' >/dev/null && echo "UI reloaded"
# 0.40: the reloaded UI opens on the main menu; with a level loaded, go back to driving
sleep 4
python -I "$HERE/bmcp.py" run_lua 'if getCurrentLevelIdentifier() then extensions.ui_router.navigate("play") return "back to play" end return "no level"'
