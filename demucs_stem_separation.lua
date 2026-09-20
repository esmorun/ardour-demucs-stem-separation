ardour {
	["type"]    = "EditorAction",
	name        = "Demucs Stem Separation",
	license     = "GPLv3",
	author      = "esmorun",
	description = [[Splits the selected audio region(s) into stems with the demucs CLI. Runs in the background; when finished you get a notification and the stems folder opens in your file manager, ready to drag into Ardour.]]
}

function factory ()
	return function ()

		-- helpers ---------------------------------------------------------
		local function q (s) -- shell-quote
			return "'" .. (tostring (s):gsub ("'", "'\\''")) .. "'"
		end

		local function exists (p)
			local f = io.open (p, "r")
			if f then
				f:close ()
				return true
			end
			return false
		end

		local function have (cmd)
			local r = os.execute ("command -v " .. cmd .. " >/dev/null 2>&1")
			return r == true or r == 0
		end

		local function info (title, text)
			LuaDialog.Message (title, text, LuaDialog.MessageType.Info, LuaDialog.ButtonType.Close):run ()
		end

		-- append progress markers to <work>/trace.log (crash forensics)
		local trace_path = nil
		local function trace (msg)
			if not trace_path then return end
			local f = io.open (trace_path, "a")
			if f then
				f:write (os.date ("%H:%M:%S ") .. msg .. "\n")
				f:close ()
			end
		end

		-- 1. collect selected audio regions (one job per unique source) ---
		local jobs, seen, skipped = {}, {}, 0
		for r in Editor:get_selection ().regions:regionlist ():iter () do
			local ar = r:to_audioregion ()
			if not ar:isnil () then
				-- Ardour stores stereo material as one mono file per channel
				-- ("name%L.wav" + "name%R.wav"), so collect up to two channels
				local paths = {}
				for c = 0, math.min (ar:n_channels (), 2) - 1 do
					local fs = ar:source (c):to_filesource ()
					if fs:isnil () then
						paths = {}
						break
					end
					table.insert (paths, fs:path ())
				end
				if #paths > 0 then
					-- demucs processes the whole source file, so the stems belong
					-- where the start of that source file sits on the timeline
					local offset = r:position ():samples () - r:start ():samples ()
					local key    = table.concat (paths, "|") .. "@" .. offset
					if offset < 0 then
						skipped = skipped + 1
					elseif not seen[key] then
						seen[key] = true
						table.insert (jobs, { paths = paths, offset = offset })
					end
				end
			end
		end

		if #jobs == 0 then
			info ("Demucs", "Select one or more audio regions first." ..
				(skipped > 0 and "\n(Skipped regions whose source starts before the session start.)" or ""))
			return
		end

		if not have ("ffmpeg") then
			info ("Demucs", "ffmpeg is required (stereo merge and format conversion).\nInstall it with: sudo pacman -S ffmpeg")
			return
		end

		-- 2. options ------------------------------------------------------
		local STEMS = { "vocals", "drums", "bass", "guitar", "piano", "other" }
		local dlg = LuaDialog.Dialog ("Demucs stem separation", {
			{ type = "label", colspan = 2, title = string.format ("%d source file(s) will be processed.", #jobs) },
		-- GTK treats "_" in the popup menu as a mnemonic marker, but the
		-- selected-value button shows the raw label, so doubling "_" is not
		-- an option; keep plain names (menu shows a harmless underline)
		{ type = "dropdown", key = "model", title = "Model", values = {
				["htdemucs_6s"]		= "htdemucs_6s",
				["htdemucs"]		= "htdemucs",
				["htdemucs_ft"]		= "htdemucs_ft",
				["mdx"]				= "mdx",
				["mdx_extra"]		= "mdx_extra",
				["mdx_q"]			= "mdx_q",
				["mdx_extra_q"]		= "mdx_extra_q",
		}, default = "htdemucs_6s" },
			{ type = "dropdown", key = "format", title = "Format", values = {
				["MP3"] = "mp3",
				["FLAC"] = "flac",
				["WAV"] = "wav",
		}, default = "MP3" },
		{ type = "dropdown", key = "mp3q", title = "MP3 quality (VBR)", values = {
			["V0 - best (~245 kbps)"]   = "0",
			["V1 (~225 kbps)"]          = "1",
			["V2 (~190 kbps)"]          = "2",
			["V3 (~175 kbps)"]          = "3",
			["V4 (~165 kbps)"]          = "4",
			["V5 (~130 kbps)"]          = "5",
			["V6 (~115 kbps)"]          = "6",
			["V7 (~100 kbps)"]          = "7",
			["V8 (~85 kbps)"]           = "8",
			["V9 - smallest (~65 kbps)"] = "9",
		}, default = "V2 (~190 kbps)" },
			{ type = "dropdown", key = "bits", title = "Bit depth (WAV/FLAC only)", values = {
				["24-bit"] = "24",
				["16-bit (dithered)"] = "16",
			}, default = "24-bit" },
			{ type = "label", colspan = 2, title = "Stems to export (guitar and piano only exist in the 6-stem model):" },
			{ type = "checkbox", key = "s_vocals", title = "Vocals", default = true },
			{ type = "checkbox", key = "s_drums",  title = "Drums",  default = true },
			{ type = "checkbox", key = "s_bass",   title = "Bass",   default = true },
			{ type = "checkbox", key = "s_guitar", title = "Guitar", default = true },
			{ type = "checkbox", key = "s_piano",  title = "Piano",  default = true },
			{ type = "checkbox", key = "s_other",  title = "Other",  default = true },
			{ type = "checkbox", key = "mix_rest", colspan = 2, default = false,
			  title = "Mix all unticked stems into one 'rest' file" },
		})
		local opt = dlg:run ()
		if not opt then return end

		local keep = {}
		for _, name in ipairs (STEMS) do
			if opt["s_" .. name] then table.insert (keep, name) end
		end
		if #keep == 0 and not opt.mix_rest then
			info ("Demucs", "No stems selected - nothing to do.")
			return
		end

		-- Ardour launched from a desktop icon often lacks ~/.local/bin in PATH
		local demucs = (os.getenv ("HOME") or "") .. "/.local/bin/demucs"
		if not exists (demucs) then demucs = "demucs" end

		-- 3. write a shell script that does all the work, run it in the background
		local sdir = Session:path ()
		if sdir:sub (-1) ~= "/" then sdir = sdir .. "/" end
		local work = sdir .. "demucs/run_" .. os.time ()
		local stems_dir = work .. "/stems"
		os.execute ("mkdir -p " .. q (stems_dir))
		trace_path = work .. "/trace.log"

		local okr, sr = pcall (function () return Session:nominal_sample_rate () end)
		if not okr or not sr or sr == 0 then sr = 48000 end

		local L = {}
		local function add (line) table.insert (L, line) end

		add ("#!/bin/sh")
		add ("# generated by demucs_stems.lua")
		add ("WORK=" .. q (work))
		add ("FORMAT=" .. q (opt.format))	add ("MP3Q=" .. q (opt.mp3q or "2"))		add ("BITS=" .. q (opt.bits or "24"))
		add ("DITHER='aresample=osf=s16:dither_method=triangular_hp'")
		add ("KEEP=" .. q (" " .. table.concat (keep, " ") .. " "))
		add ("MIXREST=" .. (opt.mix_rest and "1" or "0"))
		add ('notify () { command -v notify-send >/dev/null 2>&1 && notify-send -a Ardour Demucs "$1"; return 0; }')
		add ('fail () { notify "Stem separation failed: $1"; exit 1; }')
		-- one-line summary of the relevant error lines in a log, for notifications
		add ('errfrom () { grep -iaE "error|not installed|traceback|exception" "$1" 2>/dev/null | tail -n 2 | tr "\n" " " | cut -c1-200; }')
		-- remove intermediate audio even when a job fails partway (logs are kept)
		add ('cleanup () { [ -n "$OUT" ] && rm -f "$OUT/input.wav" "$OUT/rest.wav"; return 0; }')
		add ('trap cleanup EXIT')
		add ('command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg is not installed (sudo pacman -S ffmpeg)"')
		add ("")
		add ("# encode one wav ($1) into the chosen format/bit depth; $2 = output path without extension")
		add ("encode () {")
		add ('  case "$FORMAT/$BITS" in')
		add ('    wav/24)  mv "$1" "$2.wav" ;;')
		add ('    wav/16)  ffmpeg -y -loglevel error -i "$1" -af "$DITHER" -c:a pcm_s16le "$2.wav" ;;')
		add ('    flac/24) ffmpeg -y -loglevel error -i "$1" -c:a flac -sample_fmt s32 -bits_per_raw_sample 24 "$2.flac" ;;')
		add ('    flac/16) ffmpeg -y -loglevel error -i "$1" -af "$DITHER" -c:a flac -sample_fmt s16 "$2.flac" ;;')
		add ('    mp3/*)   ffmpeg -y -loglevel error -i "$1" -c:a libmp3lame -q:a "$MP3Q" "$2.mp3" ;;')
		add ("  esac")
		add ("}")

		local positions = {}
		for i, job in ipairs (jobs) do
			local base = job.paths[1]:match ("([^/]+)%.[^./]+$") or "track"
			base = (base:gsub ("%%[LR]$", "")) -- strip Ardour's %L / %R channel suffix

			add ("")
			add ("# ---- job " .. i .. " ----")
			add ('OUT="$WORK/job' .. i .. '"')
			add ('mkdir -p "$OUT"')
			add ("BASE=" .. q (base))
			add ("INPUT=" .. q (job.paths[1]))
			if #job.paths > 1 then
				-- stereo region: merge the two mono files into one stereo file first
				add ("ffmpeg -y -loglevel error -i " .. q (job.paths[1]) .. " -i " .. q (job.paths[2]) ..
					" -filter_complex '[0:a][1:a]join=inputs=2:channel_layout=stereo[a]' -map '[a]' -c:a pcm_f32le" ..
					' "$OUT/input.wav" > "$OUT/ffmpeg.log" 2>&1 || fail "ffmpeg failed, see $OUT/ffmpeg.log"')
				add ('INPUT="$OUT/input.wav"')
			end

			-- demucs always writes 24-bit wav here; ffmpeg converts afterwards
			add (q (demucs) .. " -n " .. opt.model .. ' --int24 -o "$OUT" "$INPUT"' ..
				' > "$OUT/demucs.log" 2>&1 || fail "demucs failed: $(errfrom "$OUT/demucs.log") (log: $OUT/demucs.log)"')

			-- demucs writes $OUT/<model>/<track>/<stem>.wav
			add ("set --")
			add ("NREST=0")
			add ('for f in "$OUT/' .. opt.model .. '"/*/*.wav; do')
			add ('  [ -f "$f" ] || continue')
			add ('  stem=$(basename "$f" .wav)')
			add ('  case "$KEEP" in')
			add ('    *" $stem "*) encode "$f" "$WORK/stems/$BASE - $stem" || fail "encoding $stem failed" ;;')
			add ("    *) if [ \"$MIXREST\" = 1 ]; then set -- \"$@\" -i \"$f\"; NREST=$((NREST + 1)); fi ;;")
			add ("  esac")
			add ("done")
			add ('if [ "$NREST" -eq 1 ]; then')
			add ('  encode "$2" "$WORK/stems/$BASE - rest" || fail "encoding rest failed"')
			add ('elif [ "$NREST" -gt 1 ]; then')
			add ('  ffmpeg -y -loglevel error "$@" -filter_complex "amix=inputs=$NREST:normalize=0:duration=longest"' ..
				' -c:a pcm_s24le "$OUT/rest.wav" > "$OUT/ffmpeg_rest.log" 2>&1 || fail "mixing rest failed, see $OUT/ffmpeg_rest.log"')
			add ('  encode "$OUT/rest.wav" "$WORK/stems/$BASE - rest" || fail "encoding rest failed"')
			add ("fi")
			-- input.wav/rest.wav are removed by the EXIT trap, also on failure
			add ('rm -rf "$OUT/' .. opt.model .. '"')

			if job.offset ~= 0 then
				table.insert (positions, string.format ("%s: start at %.3f s", base, job.offset / sr))
			end
		end

		local done_msg = "Stems are ready - drag them into Ardour."
		if #positions > 0 then
			done_msg = done_msg .. " " .. table.concat (positions, "; ")
		end
		add ("")
		add ("notify " .. q (done_msg))
		add ('command -v xdg-open >/dev/null 2>&1 && xdg-open "$WORK/stems" >/dev/null 2>&1')
		add ("exit 0")

		local script_path = work .. "/run.sh"
		local f = io.open (script_path, "w")
		if not f then
			info ("Demucs", "Could not write " .. script_path)
			return
		end
		f:write (table.concat (L, "\n") .. "\n")
		f:close ()
		trace ("script written")

		os.execute ("sh " .. q (script_path) .. " > " .. q (work .. "/run.log") .. " 2>&1 &")
		trace ("launched in background")

		-- immediate feedback
		local start_msg = "Stem separation started in the background."
		if have ("notify-send") then
			os.execute ("notify-send -a Ardour Demucs " .. q (start_msg) .. " &")
		else
			info ("Demucs", start_msg .. "\n\nStems will appear in:\n" .. stems_dir)
		end
	end
end
