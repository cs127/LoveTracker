-- Scream Tracker 3 "S3M" playroutine
-- by zorg @ 2017 § ISC

-- TODO: Scream Tracker mentions a Xxx command that mapped to an amiga 8xx command, that's not used...

-- OpenMPT S3M Test battery:
----------------------------
-- Amiga Limits   - Fail
-- Freq Limits    - Pass
-- Loop Reset     - Pass
-- NOP            - Fail
-- OxxMem         - Fail
-- ParamMem       - Fail
-- PatternDelay   - Fail?
-- PeriodLimit    - Fail
-- PortaAfterArp  - Fail
-- PortaSmpChange - Fail
-- VibratoTypeCh  - Pass
-- Weirdloop      - Fail, spectacularly at that.

-- Note: To keep things compact, everything not generic enough to be used by
--       other playroutines are kept inside the respective play_*.lua files,
--       a.k.a. these ones.

local Device = require 'device'
local device = Device(44100, 16, 2, 1024, 'Buffer', 'Buffer')

-- Start defining everything as local, then if we need something to be passed
-- into something that's a bit more "closed", redefine it as a var. of routine.

local source = device.source
local buffer = device.buffer

local module, voice, visualizer

local tickPeriod, samplingPeriod, midiPPQ, actualTempo
local timeSigNumer, timeSigDenom

--
local normalizer, normRatio, samplesToMix
local interpolation

local tickAccumulator, currentTick, currentRow, currentOrder, currentPattern
local time
local smoothScrolling

local speed, tempo
local loopRow, loopCnt, patternLoop, filterSet
local positionJump, patternBreak, patternDelay, globalVolume

local patternInvalidated = true

-- Constants

-- TODO: do dim. analysis on these numbers so we can reason about them better.

local ARPEGGIOPERIOD = 1 / 50 -- Hz; ST3's arp isn't tied to the speed var.

local SINETABLE = {
	[0] =   0,  24,  49,  74,  97, 120, 141, 161,
	      180, 197, 212, 224, 235, 244, 250, 253,
	      255, 253, 250, 244, 235, 224, 212, 197,
	      180, 161, 141, 120,  97,  74,  49,  24,
	        0,  24,  49,  74,  97, 120, 141, 161,
	      180, 197, 212, 224, 235, 244, 250, 253,
	      255, 253, 250, 244, 235, 224, 212, 197,
	      180, 161, 141, 120,  97,  74,  49,  24}

local RAMPDOWNTABLE = {
	[0] = 255, 247, 239, 231, 223, 215, 207, 199,
	      191, 183, 175, 167, 159, 151, 143, 135,
	      127, 119, 111, 103,  95,  87,  79,  71,
	       63,  55,  47,  39,  31,  23,  15,   7, 
	        0,   8,  16,  24,  32,  40,  48,  56,
	       64,  72,  80,  88,  96, 104, 112, 120,
	      128, 136, 144, 152, 160, 168, 176, 184,
	      192, 200, 208, 216, 224, 232, 240, 248}

local SQUARETABLE = {
	[0] = 255, 255, 255, 255, 255, 255, 255, 255,
	      255, 255, 255, 255, 255, 255, 255, 255,
	      255, 255, 255, 255, 255, 255, 255, 255,
	      255, 255, 255, 255, 255, 255, 255, 255,
	      255, 255, 255, 255, 255, 255, 255, 255,
	      255, 255, 255, 255, 255, 255, 255, 255,
	      255, 255, 255, 255, 255, 255, 255, 255,
	      255, 255, 255, 255, 255, 255, 255, 255}


-- This might not be what scream tracker did, but what it did, did sound random.
-- Until exact code is shown, this is "close enough".
local RANDOMTABLE = {}
	for i = 0, 63 do RANDOMTABLE[i] = love.math.random(0, 255) end

local WAVEFORMTABLE = {
	[0] = SINETABLE, RAMPDOWNTABLE, SQUARETABLE, RANDOMTABLE,
	      SINETABLE, RAMPDOWNTABLE, SQUARETABLE, RANDOMTABLE}

-- TODO: Test how scream tracker implemented the 8th type (?).
local RETRIGVOLSLIDEFUNC = {
	  [0] = function(v) return v end,
	--[[1]] function(v) return v -  1 end,
	--[[2]] function(v) return v -  2 end,
	--[[3]] function(v) return v -  4 end,
	--[[4]] function(v) return v -  8 end,
	--[[5]] function(v) return v - 16 end,
	--[[6]] function(v) return v * (2/3) end,
	--[[7]] function(v) return v * (1/2) end,
	--[[8]] function(v) return v end,
	--[[9]] function(v) return v +  1 end,
	--[[A]] function(v) return v +  2 end,
	--[[B]] function(v) return v +  4 end,
	--[[C]] function(v) return v +  8 end,
	--[[D]] function(v) return v + 16 end,
	--[[E]] function(v) return v * (3/2) end,
	--[[F]] function(v) return v * (2/1) end,
}

local C4SPEEDFINETUNES = {
	[ 0x00 ] = 7895, -- -8
	[ 0x01 ] = 7941,
	[ 0x02 ] = 7985,
	[ 0x03 ] = 8046,
	[ 0x04 ] = 8107,
	[ 0x05 ] = 8169,
	[ 0x06 ] = 8232,
	[ 0x07 ] = 8280,
	[ 0x08 ] = 8363, -- Default
	[ 0x09 ] = 8413,
	[ 0x0A ] = 8463,
	[ 0x0B ] = 8529,
	[ 0x0C ] = 8581,
	[ 0x0D ] = 8651,
	[ 0x0E ] = 8723,
	[ 0x0F ] = 8757, -- +7
}

local DEFAULTC4SPEED = C4SPEEDFINETUNES[ 0x08 ]

-- Hz = DEFAULTC4SPEED * C4PERIOD / NOTEPERIOD

local OCTAVE4PERIOD = {
	1712, 1616, 1524, 1440, 1356, 1280, 1208, 1140, 1076, 1016, 960, 907
}

local NOTEPERIOD = {}
for octave = 0, 10 do for note = 1, 12 do
		NOTEPERIOD[octave*12+(note-1)] =
			math.floor(16 * (OCTAVE4PERIOD[note] / 2^octave))
end end

local BASECLOCK  = DEFAULTC4SPEED * OCTAVE4PERIOD[1] -- C4
local FIXEDCLOCK = BASECLOCK / device.samplingRate

local FIXTIMING = function(tempo, speed, tsn, tsd)
	local tick =  2.5 / tempo
	local ppq  =  speed *  tsn * (4.0 / tsd)
	local tempo = 60.0 / (tick * ppq)
	return tick, ppq, tempo
end

local PERIODBINSEARCH = function(p)
	-- Start from the middle and always halve the remaining area
	-- We can assume that the given parameter will have a value between
	-- 27392 and 0 (or it'll just return those as the "closest" ones.)
	-- Note that the order of values is reversed (from highest to lowest)
	local L, R = 0, 132-1
	local m
	while L <= R do
		m = math.floor((L + R) / 2.0)
		if     NOTEPERIOD[m] > p then
			L = m + 1
		elseif NOTEPERIOD[m] < p then
			R = m - 1
		else 
			return m, 0
		end
	end
	if not NOTEPERIOD[L-1] then return 0,   0 end
	if not NOTEPERIOD[L]   then return L-1, 0 end
	return L-1, (p-NOTEPERIOD[L-1])/(NOTEPERIOD[L]-NOTEPERIOD[L-1])
end

-- Voice objects

local Voice = {}

Voice.getStatistics = function(v)
	local smpL, smpS, smpE, Cspd, T, L, H, S = 0, 0, 0, 0, 0, 0, 0, 0
	if v.instrument then
		smpL = v.instrument.length or 0
		smpS = v.instrument.loopStart or 0
		smpE = v.instrument.loopEnd or 0
		Cspd = v.instrument.c4speed or 0
		T    = v.instrument.type
		L    = v.instrument.looped and 0 or 1
		H    = v.instrument.bitDepth == 16 and 1 or 0
		S    = v.instrument.channelCount == 2 and 1 or 0
	end
	return v.n or 0xFF, v.i or 0, v.v or 0, v.c or 0, v.d or 0,
		v.notePeriod, v.glisPeriod, v.instPeriod,
		v.currOffset, smpL, smpS, smpE, Cspd, T, L, H, S,
		v.currInstrument, v.currVolume*0x40, v.currPanning*0xF, v.fxCommand,
		v.fxSlotGeneric, v.fxSlotPortamento, v.fxSlotVibrato,
		loopRow[v.ch], loopCnt[v.ch],
		v.noteDelayTicks, v.noteCutTicks,
		v.arpIndex,
		v.tremorOffset, v.tremorOnTicks, v.tremorOffTicks,
		v.vibratoWaveform, v.vibratoOffset,
		v.tremoloWaveform, v.tremoloOffset
end

Voice.setNote = function(v, note)
	v.n = note
end

Voice.setInstrument = function(v, instrument)
	v.i = instrument
end

Voice.setVolume = function(v, volume)
	v.v = volume
end

Voice.setEffect = function(v, effectCommand, effectData)
	v.c, v.d = effectCommand, effectData
end

Voice.setPeriod = function(v, pitch)
	-- Voice.process calls this; set raw note period, and the fixed value
	-- modified by the instrument c4speed.
	if pitch == -1 then
		v.notePeriod = 0
		v.instPeriod = 0
		return
	end
	v.notePeriod = NOTEPERIOD[pitch]
	-- If amiga limits are forced, apply upper limits on base period as well,
	-- not just the computed one.
	if module.amigaNoteLimits then
		v.notePeriod = math.max(v.notePeriod, 56) -- B-5
	end

	if v.instrument and v.instrument.c4speed then
		v.instPeriod = v.notePeriod * (DEFAULTC4SPEED / v.instrument.c4speed)
		-- Also enforce amiga limits on the computed period.
		if module.amigaNoteLimits then
			v.instPeriod = math.max(v.instPeriod, 56) -- B-5
		end
		v.tempPeriod = v.instPeriod -- Needed for semitone glissando.
	end
end

Voice.process = function(v, currentTick)
	local N, I, V, C, D
	local Dx, Dy

	-- Handle inputs
	if v.n then
		if     v.n == 255 then
			-- Note continue
			N = false
		elseif v.n == 254 then
			-- Note cut
			v.notePeriod = 0
			N = -1
		elseif v.n <  254 then
			-- Note trigger
			N = math.floor(v.n / 0x10) * 12 + (v.n % 0x10)
		end
	else
		-- No note
		v.n = 0xFF
		N   = false
	end

	if v.i then
		if     v.i == 0 then
			-- Instrument undefined
			v.currInstrument = 0
			I = false
		elseif v.i >  0 then
			-- Instrument defined
			v.currInstrument = v.i
			I = v.i - 1
		end
	else
		-- No instrument
		v.i = 0
		I   = false
	end

	if v.v then
		V = v.v
	else
		-- No volume
		v.v = 0
		V   = false
	end

	if v.c then
		v.fxCommand = v.c
		v.fxData    = v.d
	else
		-- No effect
		v.c = 0
		v.d = 0
	end
	C  = string.char(v.c + 0x40)
	D  = v.d
	Dx = math.floor(D / 16)
	Dy =            D % 16



	-- Early note delay detection...
	if currentTick == 0 then
		local x = math.floor(D / 0x10)
		if C == 'S' and x == 0xD then
			-- Note Delay
			local y = D % 0x10
			-- No % -> delay may happen across rows, which is probably wrong.
			v.noteDelayTicks = y % speed
			v.noteDelayTrigger = true
		elseif v.noteDelayTicks > 0 then
			-- Reset delay ticks since it was more than the speed value.
			-- Removing this needed to allow delays across rows, as said above.
			v.noteDelayTicks = 0
			v.noteDelayTrigger = false
		end
	end


	if  (not v.noteDelayTrigger and currentTick      == 0) or
		(    v.noteDelayTrigger and v.noteDelayTicks == 0) then
		v.noteDelayTrigger = false
		-- Combinatorics...
		if         N and     I then
			-- Apply instrument
			v.instrument = module.sample[I]
			if C ~= 'G' then
				-- Set note and reset offset to 0.
				v:setPeriod(N)
				v.currOffset = 0
			end
			-- Handle volume
			if V then
				v.currVolume = V / 0x40
			else
				if v.instrument and v.instrument.volume then
					v.currVolume = v.instrument.volume / 0x40
				end
			end
		elseif     N and not I then
			if C ~= 'G' then
				-- Set note and reset offset to 0.
				v:setPeriod(N)
				v.currOffset = 0
			end
			-- Handle volume
			if V then
				v.currVolume = V / 0x40
			else
				-- Do nothing here.
			end
		elseif not N and     I then
			-- Apply instrument
			v.instrument = module.sample[I]
			-- Handle volume
			if V then
				v.currVolume = V / 0x40
			else
				if v.instrument then
					v.currVolume = v.instrument.volume / 0x40
				end
			end
		elseif not N and not I then
			-- Handle volume
			if V then
				v.currVolume = V / 0x40
			else
				-- Do nothing here.
			end
		end

		if N then v.lastNote = N end
	end

	if currentTick == 0 then
		-- Hack: If C is @ it means only the data has been saved and that
		--       there's no effect.
		if C == '@' then
			if D ~= 0x00 then
				v.fxSlotGeneric = D
			end
		end
		-- T0 Effects.
		if     C == 'D' then
			-- Volume SLide
			if D > 0x00 then
				v.fxSlotGeneric = D
			end
			local x = math.floor(v.fxSlotGeneric / 0x10)
			local y =            v.fxSlotGeneric % 0x10
			-- If we have a fine slide, then process it here.
			-- Note that in the case of DFF, we prioritize by fine sliding up.
			if     y == 0xF then
				-- up x units
				v.currVolume = math.min(1.0, v.currVolume + (x / 0x40))
			elseif x == 0xF then
				-- down y untis
				v.currVolume = math.max(0.0, v.currVolume - (y / 0x40))
			end
			-- "Fast Volume Slide" bug handling
			if module.fastVolSlides then
				if     y == 0x0 then
					-- up x units
					v.currVolume = math.min(1.0, v.currVolume + (x / 0x40))
				elseif x == 0x0 then
					-- down y units
					v.currVolume = math.max(0.0, v.currVolume - (y / 0x40))
				end
			end
		elseif C == 'E' then
			-- Portamento Down
			if D > 0x00 then
				v.fxSlotPortamento = D
			end
			local x = math.floor(v.fxSlotPortamento / 0x10)
			local y =            v.fxSlotPortamento % 0x10
			if     x == 0xF then
				-- Fine porta
				v.instPeriod = v.instPeriod + y * 4
			elseif x == 0xE then
				-- Extra fine porta
				v.instPeriod = v.instPeriod + y
			end
			--v.instPeriod = math.min(v.instPeriod, 27392)
		elseif C == 'F' then
			-- Portamento Up
			if D > 0x00 then
				v.fxSlotPortamento = D
			end
			local x = math.floor(v.fxSlotPortamento / 0x10)
			local y =            v.fxSlotPortamento % 0x10
			if     x == 0xF then
				-- Fine porta
				v.instPeriod = v.instPeriod - y * 4
			elseif x == 0xE then
				-- Extra fine porta
				v.instPeriod = v.instPeriod - y
			end
			-- Amiga limits
			if module.amigaNoteLimits then
				v.instPeriod = math.max(v.instPeriod, 56)
			end
			v.instPeriod = math.max(v.instPeriod, 0)
		elseif C == 'G' then
			-- Tone portamento
			if D > 0x00 then
				v.fxSlotPortamento = D
			end
			if N and v.instrument and v.instrument.c4speed then
				v.glisPeriod = NOTEPERIOD[N] *
					(DEFAULTC4SPEED / v.instrument.c4speed)
			end
		elseif C == 'H' then
			-- Vibrato
			local x = math.floor(D / 0x10)
			local y =            D % 0x10
			-- TODO: Some modules imply that the two param parts are set
			-- separately.
			if x > 0x0 then
				v.fxSlotVibrato = (x * 0x10) + (v.fxSlotVibrato % 0x10)
			end
			if y > 0x0 then
				v.fxSlotVibrato = math.floor(v.fxSlotVibrato / 0x10) * 0x10 + y
			end
			-- If wavecontrol is retriggering, then reset offset here.
			if N and v.vibratoWaveform < 4 then
				v.vibratoOffset = 32
			end
		elseif C == 'I' then
			-- Tremor
			if D > 0x00 then
				v.fxSlotGeneric  = D
				v.tremorOnTicks  = math.floor(v.fxSlotGeneric / 0x10)
				v.tremorOffTicks =            v.fxSlotGeneric % 0x10
			end
			-- The actual function
			-- OpenMPT implements this with both x0 and x1 and 0y and 1y being counted as on/off for 1 tick (except 00),
			-- But FireLight claims it's x+1, y+1 all the way (except 00)...
			-- TEST THIS MORE! (Also whether the internal counter gets reset at anytime or not... row/pat/song)

			--local x, y = v.tremorOnTicks+1, v.tremorOffTicks+1
			local x, y = v.tremorOnTicks, v.tremorOffTicks
			if x == 0 and y == 0 then
				-- Use previous values (S3M "bug" if this wasn't here and we set 00 to 11.)
			else
				-- Adjust values
				x = v.tremorOnTicks  == 0 and v.tremorOnTicks  + 1 or v.tremorOnTicks
				y = v.tremorOffTicks == 0 and v.tremorOffTicks + 1 or v.tremorOffTicks
			end

			v.tremorOffset = v.tremorOffset % (x + y) -- sum is 32 maximum

			if v.tremorOffset >= x then
				print('T0 off ' .. v.tremorOffset)
				v.currVolume = 0
			else
				print('T0 on  ' .. v.tremorOffset)
				v.currVolume = (V and V or v.instrument.volume) / 0x40
			end

			v.tremorOffset = v.tremorOffset + 1
		elseif C == 'J' then
			-- Arpeggio
			if D > 0x00 then
				v.fxSlotGeneric = D
				v.arpOffset[1] = math.floor(v.fxSlotGeneric / 0x10)
				v.arpOffset[2] =            v.fxSlotGeneric % 0x10
			end
		elseif C == 'K' then
			-- VolSlide + Vibrato
			if D > 0x00 then
				v.fxSlotGeneric = D -- Sets the volume slide params only.
			end
		elseif C == 'L' then
			-- VolSlide + TonePorta
			if D > 0x00 then
				v.fxSlotGeneric = D -- Sets the volume slide params only.
			end
		elseif C == 'O' then
			-- Set Offset
			v.fxSlotGeneric = D
			v.setOffset     = D * 0x100
		elseif C == 'Q' then
			-- Retrigger note (+VolSlide)
			if D > 0x00 then
				v.fxSlotGeneric = D
			end
		elseif C == 'R' then
			-- Tremolo
			if D > 0x00 then
				v.fxSlotGeneric = D -- Rxy goes into generic slot.
			end
			-- If wavecontrol is retriggering, then reset offset here.
			if N and v.tremoloWaveform < 4 then
				v.tremoloOffset = 32
			end
		elseif C == 'S' then
			local x = math.floor(D / 0x10)
			if x == 0x1 then
				-- Glissando
				local y = D % 0x10
				v.glissando = not (y == 0) -- If true, slide by semitones.
			elseif x == 0x2 then
				-- Set FineTune
				-- TODO: This seemingly destroys any other previous value for
				--       c4speed; check if this is actually how it should work.
				-- IDEA: Maybe modify the base c4speed instead?
				if v.instrument then
					v.instrument.c4speed = C4SPEEDFINETUNES[D % 0x10]
				end
			elseif x == 0x3 then
				-- Set Vibrato Waveform
				-- TODO: See if this is global or per-channel - seems to be per-channel.
				local y = D % 0x10
				if y < 8 then
					v.vibratoWaveform = y
				end
			elseif x == 0x4 then
				-- Set Tremolo Waveform
				-- TODO: See if this is global or per-channel - seems to be per-channel.
				local y = D % 0x10
				if y < 8 then
					v.tremoloWaveform = y
				end
			elseif x == 0x8 then
				-- Set Panning
				local y = D % 0x10
				v.currPanning = y / 0x0F
			elseif x == 0xA then
				-- Stereo Control - ST3's help screen says this is "old".
				local y = D % 0x10
				if y == 0 or y == 2 then
					v.currPanning = v.sbDfPanning
				elseif y == 1 or y == 3 then
					v.currPanning = 1 - v.sbDfPanning
				elseif y < 8 then
					v.currPanning = 0.5
				end
			elseif x == 0xC then
				-- Note Cut
				local y = D % 0x10
				-- No % -> cut may happen across rows, which is probably wrong.
				v.noteCutTicks = y % speed
			elseif x == 0xD then
				-- The setter part of this needs to be handled before handling
				-- the note/instrument/volume columns, AND it needs to be
				-- processed on the 0th tick too, because of the code written.
				-- Note Delay
				if v.noteDelayTicks > 0 then
					v.noteDelayTicks = v.noteDelayTicks - 1
				end
			elseif x == 0xF then
				-- Invert Loop OR Funk Repeat
				-- Thing is, there are a few possibilities here;
				-- A. Implement Invert Loop, which irreversibly modifies the
				--    waveform data.
				-- B. Implement Funk Repeat, which only works on instruments
				--    with very specific settings.
				-- C. Implement it differently, e.g. looping will be reversed
				-- To be honest, it really is the best solution to just not.
				-- Though Scream Tracker V3.21 does state that SFx does stand
				--    for FunkRepeat, with x = speed.
			end
		elseif C == 'U' then
			-- Fine Vibrato
			local x = math.floor(D / 0x10)
			local y =            D % 0x10
			-- TODO: Some modules imply that the two param parts are set
			-- separately.
			if x > 0x0 then
				v.fxSlotVibrato = (x * 0x10) + (v.fxSlotVibrato % 0x10)
			end
			if y > 0x0 then
				v.fxSlotVibrato = math.floor(v.fxSlotVibrato / 0x10) * 0x10 + y
			end
			-- If wavecontrol is retriggering, then reset offset here.
			if N and v.vibratoWaveform < 4 then
				v.vibratoOffset = 32
			end
		end
	else 
		-- Tn Effects.
		if     C == 'D' then
			-- VolSLide
			local x = math.floor(v.fxSlotGeneric / 0x10)
			local y =            v.fxSlotGeneric % 0x10
			if     y == 0x0 then
				-- up x units
				v.currVolume = math.min(1.0, v.currVolume + (x / 0x40))
			elseif x == 0x0 then
				-- down y units
				v.currVolume = math.max(0.0, v.currVolume - (y / 0x40))
			end
		elseif C == 'E' then
			-- Portamento Down
			local x = math.floor(v.fxSlotPortamento / 0x10)
			if x < 0xE then
				v.instPeriod = v.instPeriod + v.fxSlotPortamento * 4
			end
			--v.instPeriod = math.min(v.instPeriod, 27392)
		elseif C == 'F' then
			-- Portamento Up
			local x = math.floor(v.fxSlotPortamento / 0x10)
			if x < 0xE then
				v.instPeriod = v.instPeriod - v.fxSlotPortamento * 4
			end
			v.instPeriod = math.max(v.instPeriod, 0)
		elseif C == 'G' then
			-- Tone Portamento
			if     v.tempPeriod > v.glisPeriod then
				v.tempPeriod = v.tempPeriod - v.fxSlotPortamento * 4
				if v.tempPeriod < v.glisPeriod then
					v.tempPeriod = v.glisPeriod
				end
			elseif v.tempPeriod < v.glisPeriod then
				v.tempPeriod = v.tempPeriod + v.fxSlotPortamento * 4
				if v.tempPeriod > v.glisPeriod then
					v.tempPeriod = v.glisPeriod
				end
			end

			if not v.glissando then
				v.instPeriod = v.tempPeriod
			else
				-- This works, though it's not exact to either ST3 not OpenMPT.
				if v.tempPeriod > v.glisPeriod then
					local p = PERIODBINSEARCH(v.tempPeriod)-1
					p = math.max(p, 0)
					v.instPeriod = NOTEPERIOD[p]
						--* (DEFAULTC4SPEED / v.instrument.c4speed)
				elseif v.tempPeriod < v.glisPeriod then
					local p = PERIODBINSEARCH(v.tempPeriod)+1
					p = math.min(p, 131)
					v.instPeriod = NOTEPERIOD[p]
						--* (DEFAULTC4SPEED / v.instrument.c4speed)
				end
			end
		elseif C == 'H' then
			-- Vibrato
			local pos = v.vibratoOffset - 32 -- [0,63] -> [-32,31]
			local speed = math.floor(v.fxSlotVibrato / 0x10)
			local depth = v.fxSlotVibrato % 0x10
			local delta = WAVEFORMTABLE[v.vibratoWaveform][v.vibratoOffset]
			--delta = delta * depth
			--delta = delta / 128
			--delta = delta * 4 -- Fine vibrato is the unmultiplied one
			delta = delta * depth / 32
			if pos < 0 then
				v.vibratoFreqDelta = -delta
			else
				v.vibratoFreqDelta = delta
			end
			v.vibratoOffset = (v.vibratoOffset + speed) % 64
		elseif C == 'I' then
			-- Tremor
			-- The actual function

			-- OpenMPT implements this with both x0 and x1 and 0y and 1y being counted as on/off for 1 tick (except 00),
			-- But FireLight claims it's x+1, y+1 all the way (except 00)...
			--local x, y = v.tremorOnTicks+1, v.tremorOffTicks+1
			local x, y = v.tremorOnTicks, v.tremorOffTicks
			if x == 0 and y == 0 then
				-- Use previous values (S3M "bug" if this wasn't here and we set 00 to 11.)
			else
				-- Adjust values
				x = v.tremorOnTicks  == 0 and v.tremorOnTicks  + 1 or v.tremorOnTicks
				y = v.tremorOffTicks == 0 and v.tremorOffTicks + 1 or v.tremorOffTicks
			end

			v.tremorOffset = v.tremorOffset % (x + y) -- sum is 32 maximum

			if v.tremorOffset >= x then
				print('Tn off ' .. v.tremorOffset)
				v.currVolume = 0
			else
				print('Tn on  ' .. v.tremorOffset)
				v.currVolume = (V and V or v.instrument.volume) / 0x40
			end

			v.tremorOffset = v.tremorOffset + 1
		elseif C == 'J' then
			-- Arpeggio
			-- The below code is how the effect would work if ST3/S3M didn't
			-- use a constant 50Hz rate for the effect.
			--v.arpIndex = currentTick % 3
			--v:setPeriod(math.min(v.lastNote + v.arpOffset[v.arpIndex], 131))
		elseif C == 'K' then
			-- Vibrato
			local pos = v.vibratoOffset - 32 -- [0,63] -> [-32,31]
			local speed = math.floor(v.fxSlotVibrato / 0x10)
			local depth = v.fxSlotVibrato % 0x10
			local delta = WAVEFORMTABLE[v.vibratoWaveform][v.vibratoOffset]
			--delta = delta * depth
			--delta = delta / 128
			--delta = delta * 4 -- Fine vibrato is the unmultiplied one
			delta = delta * depth / 32
			if pos < 0 then
				v.vibratoFreqDelta = -delta
			else
				v.vibratoFreqDelta = delta
			end
			v.vibratoOffset = (v.vibratoOffset + speed) % 64
			-- VolSlide
			local x = math.floor(v.fxSlotGeneric / 0x10)
			local y =            v.fxSlotGeneric % 0x10
			if     y == 0x0 then
				-- up x units
				v.currVolume = math.min(1.0, v.currVolume + (x / 0x40))
			elseif x == 0x0 then
				-- down y units
				v.currVolume = math.max(0.0, v.currVolume - (y / 0x40))
			end
		elseif C == 'L' then
			-- TonePorta
			if     v.tempPeriod > v.glisPeriod then
				v.tempPeriod = v.tempPeriod - v.fxSlotPortamento * 4
				if v.tempPeriod < v.glisPeriod then
					v.tempPeriod = v.glisPeriod
				end
			elseif v.tempPeriod < v.glisPeriod then
				v.tempPeriod = v.tempPeriod + v.fxSlotPortamento * 4
				if v.tempPeriod > v.glisPeriod then
					v.tempPeriod = v.glisPeriod
				end
			end

			if not v.glissando then
				v.instPeriod = v.tempPeriod
			else
				-- This works, though it's not exact to either ST3 not OpenMPT.
				if v.tempPeriod > v.glisPeriod then
					local p = PERIODBINSEARCH(v.tempPeriod)-1
					p = math.max(p, 0)
					v.instPeriod = NOTEPERIOD[p]
						--* (DEFAULTC4SPEED / v.instrument.c4speed)
				elseif v.tempPeriod < v.glisPeriod then
					local p = PERIODBINSEARCH(v.tempPeriod)+1
					p = math.min(p, 131)
					v.instPeriod = NOTEPERIOD[p]
						--* (DEFAULTC4SPEED / v.instrument.c4speed)
				end
			end
			-- VolSlide
			local x = math.floor(v.fxSlotGeneric / 0x10)
			local y =            v.fxSlotGeneric % 0x10
			if     y == 0x0 then
				-- up x units
				v.currVolume = math.min(1.0, v.currVolume + (x / 0x40))
			elseif x == 0x0 then
				-- down y units
				v.currVolume = math.max(0.0, v.currVolume - (y / 0x40))
			end
		elseif C == 'Q' then
			-- Retrigger note (+VolSlide)
			local x = math.floor(v.fxSlotGeneric / 0x10)
			local y =            v.fxSlotGeneric % 0x10
			v.currVolume = math.floor(
				RETRIGVOLSLIDEFUNC[x](v.currVolume * 0x40)) / 0x40
			v.currVolume = math.min(math.max(v.currVolume, 0.0), 1.0)
			if currentTick % y == 0 then
				v.currOffset = 0
				if V then
					v.currVolume = V / 0x40
				elseif I then
					v.currVolume = v.instrument.volume / 0x40
				end
			end
		elseif C == 'R' then
			-- Tremolo
			local pos = math.abs(v.tremoloOffset) - 32 -- [0,63] -> [-32,31]
			local speed = math.floor(v.fxSlotGeneric / 0x10)
			local depth = v.fxSlotGeneric % 0x10
			local delta = WAVEFORMTABLE[v.tremoloWaveform][v.tremoloOffset]
			--delta = delta * depth
			--delta = delta / 64
			--delta = delta * 4
			delta = delta * depth / 16
			if pos < 32 then
				v.currVolume = math.min(v.currVolume + (delta / 0x40), 1) 
			else
				v.currVolume = math.max(v.currVolume - (delta / 0x40), 1)
			end
			v.tremoloOffset = (v.tremoloOffset + speed) % 64
		elseif C == 'S' then
			local x = math.floor(D / 0x10)
			if x == 0xC then
				-- Note Cut
				-- This code also works for the case when
				-- noteCutTicks >= speed
				if v.noteCutTicks > 0 then
					v.noteCutTicks = v.noteCutTicks - 1
					if v.noteCutTicks == 0 then
						v.currVolume = 0.0
					end
				end
			elseif x == 0xD then
				-- Note Delay
				if v.noteDelayTicks > 0 then
					v.noteDelayTicks = v.noteDelayTicks - 1
				end
			end
		elseif C == 'U' then
			-- Fine Vibrato
			local pos = v.vibratoOffset - 32 -- [0,63] -> [-32,31]
			local speed = math.floor(v.fxSlotVibrato / 0x10)
			local depth = v.fxSlotVibrato % 0x10
			local delta = WAVEFORMTABLE[v.vibratoWaveform][v.vibratoOffset]
			--delta = delta * depth
			--delta = delta / 128
			--delta = delta * 1
			delta = delta * depth / 128
			if pos < 0 then
				v.vibratoFreqDelta = -delta
			else
				v.vibratoFreqDelta = delta
			end
			v.vibratoOffset = (v.vibratoOffset + speed) % 64
		end
	end
end

Voice.render = function(v)
	local smpL, smpR = 0.0, 0.0

	if v.instPeriod == 0 then return smpL, smpR end

	if not v.instrument or v.instrument.type == 0 then return smpL, smpR end

	if v.instrument.type == 1 then
		-- Sampler.
		local freq

		-- ST3 Arpeggio
		if v.c == 0x0A then
			v.arpIndex = (v.arpIndex + (samplingPeriod / ARPEGGIOPERIOD)) % 3
			v:setPeriod(
				math.min(v.arpOffset[math.floor(v.arpIndex)] + v.lastNote,
				131))
		end

		-- Vibrato
		if v.c == 0x08 or v.c == 0x0B or v.c == 0x16 then
			freq = v.instPeriod + v.vibratoFreqDelta
		else
			freq = v.instPeriod
		end

		v.currOffset = v.currOffset + (FIXEDCLOCK / freq)

		if v.setOffset > 0 then
			-- Add setOffset parameter.
			v.currOffset = v.currOffset + v.setOffset
			v.setOffset = 0
		end

		if v.instrument.looped then
			local addend = v.currOffset - v.instrument.loopEnd
			if addend >= 0 then
				v.currOffset = v.instrument.loopStart + addend
			end
		else
			if v.currOffset > v.instrument.data:getSampleCount() *
				v.instrument.data:getChannelCount()
			then
				v.currOffset = 0.0
				v.instPeriod = 0 -- Only play the sample once.
				return smpL, smpR
			end
		end

		v.currOffset = v.currOffset % (v.instrument.data:getSampleCount() *
			v.instrument.data:getChannelCount())

		-- Interpolation
		if interpolation == 'nearest' then
			-- 0th order interpolation: nearest neighbour (piecewise constant)
			if v.instrument.channelCount == 1 then
				local p = math.floor(v.currOffset)
				smpL = v.instrument.data:getSample(p)
				smpR = smpL
			else
				-- Stereo is not standard ST3, but implementable.
				local p = math.floor(v.currOffset)
				p = p % 2 == 1 and p - 1 or p

				smpL = v.instrument.data:getSample(p)
				smpR = v.instrument.data:getSample(p + 1)
			end
		elseif interpolation == 'linear' then
			-- TODO
		end

		smpL = smpL * v.currVolume * (1.0 - v.currPanning)
		smpR = smpR * v.currVolume *        v.currPanning
		return smpL, smpR

	elseif v.instrument.type == 2 then
		-- TODO: AdLib OPL2 synth - melodics.
		return smpL, smpR
	end
end

local mtVoice = {__index = Voice}

Voice.new = function(ch, pan, sbdefpan)
	local v = setmetatable({}, mtVoice)

	v.ch = ch

	-- Processing related.
	v.disabled = false -- Whether or not the voice is processed.
	v.muted    = false -- Whether or not the voice output is muted.

	-- Per-row input data.
	v.n,  v.i,  v.v,  v.c,  v.d  = 0xFF, 0x00, 0x00, 0x00, 0x00

	-- Reference to the instrument
	v.instrument       = false  -- Reference to the current instrument.

	-- Current running values
	v.lastNote         = 0

	v.notePeriod       = 0x0000 -- Base period value as taken from note data.
	v.glisPeriod       = 0x0000 -- Final (true) period value of Gxx glissando effects.
	v.instPeriod       = 0x0000 -- True period value calc.-ed w/ the current instrument.

	v.currOffset       = 0.0    -- Current sample offset. (floored -> matrix displayable)

	v.currVolume       = 0.0    -- Current volume.
	v.currPanning      = pan / 0xF -- Current panning.
	v.sbDfPanning      = sbdefpan / 0xF -- Default panning in SoundBlaster modules.

	v.currInstrument   = 0x00   -- Only for display purposes.

	-- Emulate ST3 limited effect memory.
	v.fxCommand        = 0x00   -- Effect command.
	v.fxData           = 0x00   -- Effect parameter.

	v.fxSlotGeneric    = 0x00   -- Generic effect parameter slot. (D, K*, L, E?, F?, G???, I, J, Q, R, S)
	v.fxSlotPortamento = 0x00   -- Portamento effect parameter slot. (E?/F?/G???)
	v.fxSlotVibrato    = 0x00   -- Vibrato effect parameter slot. (H/U/K*)

	-- Faster calculation
	v.noteDelayTicks   = 0x0    -- Ticks to delay note onsets.
	v.noteCutTicks     = 0x0    -- Ticks to cut note sound after.
	v.noteDelayTrigger = false  -- Internal helper.

	v.arpIndex         = 0x0    -- Running index for arpeggio effect.
	v.arpOffset        = {}
	v.arpOffset[0]     = 0x0    -- Arpeggio offsets.
	v.arpOffset[1]     = 0x0    -- -"-.
	v.arpOffset[2]     = 0x0    -- -"-.

	v.tremorOffset     = 0x00   -- Running index for tremor effect.
	v.tremorOnTicks    = 0x0    -- Ticks while sound is unmuted.
	v.tremorOffTicks   = 0x0    -- Ticks while sound is muted.

	v.vibratoWaveform  = 0
	v.tremoloWaveform  = 0
	v.vibratoOffset    = 32   -- 0..63
	v.tremoloOffset    = 32
	v.vibratoFreqDelta = 0

	v.glissando        = false -- ST3 proved this is also per-channel.
	v.tempPeriod       = 0     -- Need to behave like non-gliss Gxx instperiod.

	v.setOffset        = 0x0000 -- Oxx setOffset calculated value.


	return v
end

-- The playroutine

local routine = {}



routine.load = function(mod)
	module = mod

	time = 0.0
	samplesToMix = 0

	loopRow, loopCnt = {}, {}
	for ch = 0, module.channelCount-1 do
		loopRow[ch] = 0
		loopCnt[ch] = 0 
	end
	patternLoop = false
	filterSet   = false

	interpolation   = 'nearest'
	smoothScrolling = false
	visualizer      = {}

	positionJump, patternBreak, patternDelay = false, false, 0
	glissando, globalVolume = false, module.globalVolume / 0x40

	timeSigNumer, timeSigDenom = 4, 4
	speed = module.initialSpeed
	tempo = module.initialTempo

	tickPeriod, midiPPQ, actualTempo = FIXTIMING(
		tempo, speed, timeSigNumer, timeSigDenom)

	samplingPeriod = 1.0 / device.samplingRate

	voice = {}
	for ch=0, 31 do --module.channelCount-1 do
		if module.channel[ch].map then
			voice[module.channel[ch].map] = Voice.new(
				module.channel[ch].map,
				module.channel[ch].pan,
				module.channel[ch].sbdefpan)
			-- Per-voice waveform analyzers.
			visualizer[module.channel[ch].map] = {}
			visualizer[module.channel[ch].map].offset = 0
			visualizer[module.channel[ch].map].length = 104 -- width of a track
			for smp = 0, visualizer[module.channel[ch].map].length-1 do 
				visualizer[module.channel[ch].map][smp] = 0.0
			end
		end
		--voice[ch] = Voice.new(module.channel[ch].pan)
	end
	normalizer = module.channelCount
	normRatio = math.sqrt(10.0^((normalizer-1.0)/10.0)) -- dB, probably.

	tickAccumulator = 0.0
	currentTick     = 0
	currentRow      = 0
	currentOrder    = 0
	currentPattern  = module.order[currentOrder]
	patternInvalidated = true

	love.timer.step()
end



routine.process = function()
	-- Process tracks
	if currentPattern < 254 then
		-- Reverse-iteration is needed to correctly process some effects.
		for ch = module.channelCount-1, 0, -1 do
			local cell = module.pattern[currentPattern][currentRow][ch]
			-- Set cell data for voices.
			voice[ch]:setNote(cell.note)
			voice[ch]:setInstrument(cell.instrument)
			voice[ch]:setVolume(cell.volume)
			voice[ch]:setEffect(cell.effectCommand, cell.effectData)
			-- After we set everything in the voice, process it.
			voice[ch]:process(currentTick)
			-- Handle playback modification and other globals locally here.
			if currentTick == 0 and cell.effectCommand then
				if     string.char(cell.effectCommand + 0x40) == 'A' then
					-- Set Speed
					if cell.effectData >= 0x01 and cell.effectData <= 0xFF then
						speed = cell.effectData
					end
				elseif string.char(cell.effectCommand + 0x40) == 'T' then
					-- Set Tempo
					if cell.effectData >= 0x20 and cell.effectData <= 0xFF then
						tempo = cell.effectData
					end
				elseif string.char(cell.effectCommand + 0x40) == 'B' then
					-- Position Jump
					positionJump = cell.effectData
					-- Invalidate patternLoops that happened in a "later" 
					-- channel.
					patternLoop = false
				elseif string.char(cell.effectCommand + 0x40) == 'C' then
					-- Pattern Break
					if cell.effectData <= 0x3F then
						patternBreak = math.floor(cell.effectData/16)*10 +
							cell.effectData%16
						-- Invalidate patternLoops that happened in a "later" 
						-- channel.
						patternLoop = false
					end
				elseif string.char(cell.effectCommand + 0x40) == 'S' and
					math.floor(cell.effectData/16) == 0x0 then
						-- Set Filter
						-- TODO: This must have been global... right?
						--       Also, OALS has filter objects, so possible.
						--       Interestingly, ST3.21's help screen says that
						--       this had 3 settings: 1/0/F : on/off/forced.
						--       Find out what forced meant.
				elseif string.char(cell.effectCommand + 0x40) == 'S' and
					math.floor(cell.effectData/16) == 0xB then
						-- Pattern Loop
						local x = cell.effectData%16
						if x == 0 then
							loopRow[ch] = currentRow
						else
							if loopCnt[ch] == 0 then
								loopCnt[ch] = x
							else
								loopCnt[ch] = loopCnt[ch] - 1
							end
							patternLoop = true
							-- Invalidate positionJumps and patternBreaks that
							-- happened in a "later" channel.
							positionJump, patternBreak = false, false
						end
				elseif string.char(cell.effectCommand + 0x40) == 'S' and
					math.floor(cell.effectData/16) == 0xE then
						-- Pattern Delay
						local x = cell.effectData % 0x10
						-- This works in rows, not ticks!
						patternDelay = x * speed
				elseif string.char(cell.effectCommand + 0x40) == 'V' then
					-- Global Volume
					if cell.effectData <= 0x40 then
						globalVolume = cell.effectData / 0x40
					end
				end
			end
		end
		-- Fix timing, since we may have modified it in one of the tracks.
		tickPeriod, midiPPQ, actualTempo = FIXTIMING(
			tempo, speed, timeSigNumer, timeSigDenom)
	end
end



routine.step = function()
	-- Advance playback position.

	-- Default handling
	if currentTick + 1 < speed + patternDelay then
		currentTick = currentTick + 1
	else
		if patternDelay > 0 then patternDelay = 0 end
		currentTick = 0
		if currentRow + 1 < 64 then -- Row # constant & hardcoded in s3m.
			currentRow = currentRow + 1
		else
			currentRow = 0
			if currentOrder + 1 < module.orderCount then
				currentOrder   = currentOrder + 1
				currentPattern = module.order[currentOrder]
			else
				currentOrder   = 0 -- No song restart marker in s3m.
				currentPattern = module.order[currentOrder]
			end
			-- Invalidate loop points if we leave a pattern in any way!
			for ch = 0, module.channelCount-1 do
				loopRow[ch] = 0
				loopCnt[ch] = 0 
			end
			patternInvalidated = true
		end
	end
	-- Loop handling
	if patternLoop and currentTick == 0 then 
		for ch = 0, module.channelCount-1 do
			-- TODO: Check if this processing order is right or wrong.
			if loopCnt[ch] > 0 then
				currentRow = loopRow[ch]
				patternLoop = false
				break
			end
		end
	end
	-- Jump handling
	if positionJump or patternBreak then
		if currentTick == 0 then
			if positionJump and not patternBreak then
				-- Jump to 0th row of given order.
				currentOrder   = positionJump % module.orderCount
				currentPattern = module.order[currentOrder]
				currentRow     = 0
				patternInvalidated = true
			elseif not positionJump and patternBreak then
				-- Jump to given row of next order.
				currentOrder   = (currentOrder + 1) % module.orderCount
				currentPattern = module.order[currentOrder]
				if currentPattern < 254 then
					currentRow = patternBreak % 64 -- See above.
				end
				patternInvalidated = true
			else
				-- Jump to given row of given order.
				currentOrder   = positionJump % module.orderCount
				currentPattern = module.order[currentOrder]
				if currentPattern < 254 then
					currentRow = patternBreak % 64 -- See above.
				end
				patternInvalidated = true
			end
			positionJump, patternBreak = false, false
		end
		-- Invalidate loop points if we leave a pattern in any way!
			for ch = 0, module.channelCount-1 do
				loopRow[ch] = 0
				loopCnt[ch] = 0 
			end
	end
	-- Marker/Empty pattern skips
	if currentPattern >= 254 then
		for ord = currentOrder, module.orderCount-1 do
			if module.order[ord] < 254 then
				currentOrder   = ord
				currentPattern = module.order[currentOrder]
				currentRow     = 0
				currentTick    = 0
				patternInvalidated = true
				break
			end
		end
		if currentPattern >= 254 then
			-- Restart from beginning.
			currentOrder   = 0
			currentPattern = module.order[currentOrder]
			currentRow     = 0
			currentTick    = 0
			time = 0
			patternInvalidated = true
		end
	end
end



routine.render = function(dt)
	-- Rendermode
	if device.renderMode == 'CPU' then
		-- We could check the buffer state here, like below, but that would
		-- swap underruns with rendering slowdowns.
		samplesToMix = math.min(
			math.floor(dt / samplingPeriod)
			,buffer.data:getSampleCount()
		)

	elseif device.renderMode == 'Buffer' then
		if source.queue:getFreeBufferCount() == 0 then return end
		samplesToMix = math.min(
			math.floor(tickPeriod / samplingPeriod),
			buffer.data:getSampleCount()
		)
	end

	if samplesToMix == 0 then return end

	for i=0, samplesToMix-1 do
		local smpL, smpR = 0.0, 0.0
		for v=0, module.channelCount-1 do
			local L, R = 0.0, 0.0
			-- Render each voice, and mix them together.
			if not voice[v].muted then
				L, R = voice[v]:render()
				smpL, smpR = smpL + L, smpR + R
				-- Visualizer stuff
				visualizer[v][visualizer[v].offset] = (L+R)/2
				visualizer[v].offset = (visualizer[v].offset + 1) %
					visualizer[v].length
			end
		end

		-- Apply global volume once (may not be 100% accurate, but it works.)
		smpL, smpR = smpL * globalVolume, smpR * globalVolume

		-- Normalize output.
		smpL, smpR = smpL / normRatio, smpR / normRatio

		-- Write samples to buffer.
		buffer.data:setSample(buffer.offset  , smpL)
		buffer.data:setSample(buffer.offset+1, smpR)

		-- Advance buffer position, if it's full, queue it and reset buffer.
		buffer.offset = buffer.offset + 2
		if buffer.offset >= buffer.data:getSampleCount() *
			buffer.data:getChannelCount()
		then
			buffer.offset = 0
			source.queue:queue(buffer.data)
			source.queue:play()
		end

		-- This tracking mode should be the most precise, since it's updated
		-- each time an smp (or two, because stereo...) gets rendered.
		if device.trackingMode == 'Buffer' then
			tickAccumulator = tickAccumulator + samplingPeriod
			if tickAccumulator >= tickPeriod then
				-- If a tick was rendered fully, process the next tick, and
				-- advance the playback position.
				routine.process()
				routine.step()
				tickAccumulator = tickAccumulator - tickPeriod
				time = time + tickPeriod
			end
		end
	end
end



routine.update = function(dt)

	-- Render sound.
	routine.render(dt)

	-- This one's less precise, but it doesn't consume as much processing time.
	if device.trackingMode == 'CPU' then
		tickAccumulator = tickAccumulator + dt
		if tickAccumulator >= tickPeriod then
			-- If a tick was rendered fully, process the next tick, and advance
			-- the playback position.
			routine.process()
			routine.step()
			tickAccumulator = tickAccumulator - tickPeriod
			time = time + tickPeriod
		end
	end
end



local noteTf = function(n)
	local symbol = {[0] = '-','#','-','#','-','-','#','-','#','-','#','-'}
	local letter = {[0] = 'C', 'C', 'D', 'D', 'E', 'F', 'F', 'G', 'G', 'A',
		'A', 'B'}
	if n == 254 then
		return '^^ '
	elseif n == 255 then
		return '...'
	else
		local class = n % 0x10
		local oct = math.floor(n / 0x10) + 1
		return ("%1s%1s%1X"):format(letter[class], symbol[class], oct)
	end
end

local textCP, textPP, textNP
textCP = love.graphics.newText(love.graphics.getFont())
textPP = love.graphics.newText(love.graphics.getFont())
textNP = love.graphics.newText(love.graphics.getFont())

local visChOffset = 0

routine.draw = function()
	love.graphics.setBackgroundColor(0.1,0.2,0.4)

	-- Patterns
	---[=[
	love.graphics.push()

	local subOffset = 0
	if smoothScrolling then
		subOffset = -math.floor((currentTick / (speed + patternDelay)) * 12)
	end

	love.graphics.translate(0, 300+(-12*currentRow)+subOffset)

	-- 227*8 == 1816 horizontal width would be needed to show 16 s3m channels.
	local curr = module.pattern[module.order[currentOrder]]

	if patternInvalidated then

		textPP:clear()
		textCP:clear()
		textNP:clear()

		local prev, next, color
		prev = module.pattern[module.order[(currentOrder - 1) %
			module.orderCount]]
		next = module.pattern[module.order[(currentOrder + 1) %
			module.orderCount]]

		for row = 0, 63 do

			if prev then
				color = {0.5,0.5,0.25}
				textPP:add({color, ("%02X"):format(row)},
					0, 84+(row-64)*12)
				for ch = visChOffset, module.channelCount-1 do
					textPP:add({color, ("|%3s %2s %2s %1s%2s"):format(
						prev[row][ch].note and
							noteTf(prev[row][ch].note) or '...',
						prev[row][ch].instrument and
							("%02X"):format(prev[row][ch].instrument) or
							'..',
						prev[row][ch].volume and
							("%02X"):format(prev[row][ch].volume) or
							'..',
						prev[row][ch].effectCommand and
							string.char(prev[row][ch].effectCommand + 0x40) or
							'.',
						prev[row][ch].effectData and
							("%02X"):format(prev[row][ch].effectData) or
							'..')
					}, 2*8+(ch-visChOffset)*14*8, 84+(row-64)*12)
				end
				textPP:add({color, "|"},
					2*8+(module.channelCount-visChOffset)*14*8, 84+(row-64)*12)
			end

			if curr then
				color = {0.75,0.75,0.75}
				textCP:add({color, ("%02X"):format(row)},
					0, 84+row*12)
				for ch = visChOffset, module.channelCount-1 do
					textCP:add({color, ("|%3s %2s %2s %1s%2s"):format(
						curr[row][ch].note and
							noteTf(curr[row][ch].note) or 
							'...',
						curr[row][ch].instrument and
							("%02X"):format(curr[row][ch].instrument) or
							'..',
						curr[row][ch].volume and
							("%02X"):format(curr[row][ch].volume) or 
							'..',
						curr[row][ch].effectCommand and
							string.char(curr[row][ch].effectCommand + 0x40) or
							'.',
						curr[row][ch].effectData and
							("%02X"):format(curr[row][ch].effectData) or
							'..')
					}, 2*8+(ch-visChOffset)*14*8, 84+row*12)
				end
				textCP:add({color, "|"},
					2*8+(module.channelCount-visChOffset)*14*8, 84+row*12)
			end

			if next then
				color = {0.5,0.25,0.75}
				textNP:add({color, ("%02X"):format(row)},
					0, 84+(row+64)*12)
				for ch = visChOffset, module.channelCount-1 do
					textNP:add({color, ("|%3s %2s %2s %1s%2s"):format(
						next[row][ch].note and
							noteTf(next[row][ch].note) or
							'...',
						next[row][ch].instrument and
							("%02X"):format(next[row][ch].instrument) or
							'..',
						next[row][ch].volume and
							("%02X"):format(next[row][ch].volume) or
							'..',
						next[row][ch].effectCommand and
							string.char(next[row][ch].effectCommand + 0x40) or
							'.',
						next[row][ch].effectData and
							("%02X"):format(next[row][ch].effectData) or
							'..')
						},
						2*8+(ch-visChOffset)*14*8, 84+(row+64)*12)
				end
				textNP:add({color, "|"},
					2*8+(module.channelCount-visChOffset)*14*8, 84+(row+64)*12)
			end
		end

		patternInvalidated = false
	end

	-- Draw the play cursor background
	color = {.0, .0, .0}
	love.graphics.setColor(color)
	love.graphics.rectangle('fill',
		0,
		84+currentRow*12+4,---subOffset,
		3*8+(module.channelCount-visChOffset)*14*8,
		12
	)

	-- Draw the pattern data
	love.graphics.setColor(1,1,1)
	love.graphics.draw(textPP, 0, 0)
	love.graphics.draw(textCP, 0, 0)
	love.graphics.draw(textNP, 0, 0)

	-- Draw the play cursor
	if currentTick == 0 then
		color = {1.0,1.0,1.0}
	else
		color = {0.75,0.75,0.25}
	end
	love.graphics.setColor(color)
	love.graphics.print(("%02X"):format(currentRow),
		0, 84+currentRow*12)
	for ch = visChOffset, module.channelCount-1 do
		love.graphics.print(
			("|%3s %2s %2s %1s%2s"):format(
				curr[currentRow][ch].note and
					noteTf(curr[currentRow][ch].note) or
					'...',
				curr[currentRow][ch].instrument and
					("%02X"):format(curr[currentRow][ch].instrument) or
					'..',
				curr[currentRow][ch].volume and
					("%02X"):format(curr[currentRow][ch].volume) or
					'..',
				curr[currentRow][ch].effectCommand and
					string.char(curr[currentRow][ch].effectCommand + 0x40) or
					'.',
				curr[currentRow][ch].effectData and
					("%02X"):format(curr[currentRow][ch].effectData) or
					'..'
			), 2*8+(ch-visChOffset)*14*8, 84+currentRow*12)
	end
	love.graphics.print('|',
		2*8+(module.channelCount-visChOffset)*14*8, 84+currentRow*12)

	love.graphics.pop()
	--]=]

	-- Visualizer
	---[=[
	love.graphics.push()
	love.graphics.setLineStyle('rough')
	love.graphics.setLineWidth(1)
	love.graphics.translate(3*8,384-8)

	for ch = visChOffset, module.channelCount-1 do
		love.graphics.setColor(.4,.4,.4)
		love.graphics.setBlendMode('multiply','premultiplied')
		love.graphics.rectangle('fill',0,-128,104,128)
		love.graphics.setBlendMode('alpha','alphamultiply')
		love.graphics.setColor(.3,.3,.25)
		-- For some reason, aggregating these into one lg.line call kills
		-- efficiency horribly.
		for smp = 0, visualizer[ch].length-2 do
			love.graphics.line(
				smp  , math.floor(visualizer[ch][smp  ]*254)-64,
				smp+1, math.floor(visualizer[ch][smp+1]*254)-64)
		end
		
		love.graphics.setColor(.9,.9,1)
		local points = {}
		-- This one works better like this, though.
		for smp = 0, visualizer[ch].length-1 do
			points[#points+1] = smp
			points[#points+1] = math.floor(visualizer[ch][smp]*254)-64
		end
		love.graphics.points(points)

		love.graphics.translate(104+8,0)
	end
	love.graphics.pop()
	--]=]

	-- Stats
	---[=[
	love.graphics.push()
	love.graphics.setColor(0,0,0.3)
	love.graphics.rectangle('fill',0,0,73*8,60)
	love.graphics.setColor(1,1,1)
	love.graphics.translate(0,-2)
	local i,f
	local y, w = 0, 12
	love.graphics.print(("order:   0x%02X / 0x%02X"):format(
		currentOrder, module.orderCount),   0, y)
	y = y + w
	love.graphics.print(("pattern: 0x%02X / 0x%02X"):format(
		currentPattern, module.patternCount), 0, y)
	y = y + w
	love.graphics.print(("row:     0x%02X / 0x%02X"):format(
		currentRow, 64),     0, y)
	y = y + w
	love.graphics.print(("tick:    0x%02X / 0x%02X"):format(
		currentTick, speed-1),    0, y)
	y = y + w
	local h,m
	h = math.floor(time/3600)
	m = math.floor((time/60)%60)
	i = math.floor(time%60)
	f = math.floor((time%1)*1000000)
	love.graphics.print(("elapsed time: %02d:%02d:%02d.%06d"):format(
		h, m, i, f), 0, y)
	y = 0
	love.graphics.print(("tempo (T): %3d"):format(tempo), 23*8, y)
	y = y + w
	love.graphics.print(("speed (A): %3d"):format(speed), 23*8, y)
	y = y + w
	i = math.floor(samplingPeriod*1000000)
	f = math.floor(samplingPeriod*10000000000) - (i * 10000)
	love.graphics.print(("s-period: %4d.%04d μs"):format(i, f), 23*8, y)
	y = y + w
	i = math.floor(tickPeriod*1000)
	f = math.floor(tickPeriod*10000000) - (i * 10000)
	love.graphics.print(("t-period: %4d.%04d ms"):format(i, f), 23*8, y)
	y = 0
	i = math.floor(actualTempo)
	f = math.floor(actualTempo*10000) - (i * 10000)
	love.graphics.print(("true tempo: %4d.%04d BPM"):format(i, f), 48*8, y)
	y = y + w
	love.graphics.print(("mixed smp-s: %4d"):format(samplesToMix), 48*8, y)
	y = y + w
	love.graphics.print(("Timing:   %s"):format(device.renderMode), 48*8, y)
	y = y + w
	love.graphics.print(("Tracking: %s"):format(device.trackingMode), 48*8, y)
	love.graphics.pop()
	--]=]

	-- NEC98/OPNA player-esque Piano Keyboard
	---[=[
	local White = {[0] = true, [2] = true, [4] = true, [5] = true, [7]  = true, [9] = true, [11] = true}
	local Black = {[1] = true, [3] = true, [6] = true, [8] = true, [10] = true}
	local X = {[0] =  0,  3,  4,  7,  8, 12, 15, 16, 19, 20, 23, 24}
	local W = {[0] =  4,  2,  4,  2,  4,  4,  2,  4,  2,  4,  2,  4}
	local H = {[0] = 12,  7, 12,  7, 12, 12,  7, 12,  7, 12,  7, 12}

	local gX = {[0] =   3,  7, 11, 15, 19, 23, 27}
	local gY = {[0] =   7,  7,  1,  7,  7,  7,  1}
	local gH = {[0] =   5,  5, 11,  5,  5,  5, 11}
	love.graphics.push()
	--love.graphics.translate(189*8, 0)
	--love.graphics.translate(0, (module.channelCount+2)*12)
	love.graphics.translate(680, 432)
	love.graphics.scale(1,1)

	for ch = 0, module.channelCount-1 do
		love.graphics.setColor(1,1,1)
		love.graphics.rectangle('fill',0,0,10*28,12)

		-- N = math.floor(v.n / 0x10) * 12 + (v.n % 0x10)
		local octave = math.floor(voice[ch].n / 16)
		local class  =            voice[ch].n % 16

		local EX = false
		local pitch, poffset
		local octave2
		local class2
		local pitchex, octave2ex, class2ex
		local exalpha, volnorm

		if voice[ch].instPeriod > 0 and voice[ch].instPeriod < 27392 then
			EX = true
			pitch, poffset = PERIODBINSEARCH(voice[ch].instPeriod)
			octave2 = math.floor(pitch / 12)
			class2  =            pitch % 12
			pitchex, octave2ex, class2ex = pitch,0,0
			--if poffset > 0 then
			--	pitchex   = pitch+1
			--	octave2ex = math.floor(pitchex / 12)
			--	class2ex  =            pitchex % 12
			--end
			exalpha   = poffset
			volnorm = voice[ch].currVolume ^ (1/32)
		end

		if White[class] then
			love.graphics.setColor(0,0,1)
			love.graphics.rectangle('fill', octave*28+X[class], 0,
				W[class], H[class])
		end

		if EX and White[class2] then
			love.graphics.setColor(1,0,0, volnorm)
			love.graphics.rectangle('fill', octave2*28+X[class2], 0,
				W[class2], H[class2])
		end

		--if EX and poffset > 0 then
		--	if White[class2ex] then
		--		love.graphics.setColor(1,0,0,(exalpha)*volnorm)
		--		love.graphics.rectangle('fill', octave2ex*28+X[class2ex], 0,
		--			W[class2ex], H[class2ex])
		--	end
		--end

		for o = 0, 9 do
			for c = 0, 11 do
				if Black[c] then
					love.graphics.setColor(0,0,0)
					love.graphics.rectangle('fill', o*28+X[c], 0,
						W[c], H[c])

					if o == octave and c == class then
						love.graphics.setColor(0,0,1)
						love.graphics.rectangle('fill', o*28+X[c], 0,
							W[c], H[c])
					end

					if EX and o == octave2 and c == class2 then
						love.graphics.setColor(1,0,0,volnorm)
						love.graphics.rectangle('fill', o*28+X[c], 0,
							W[c], H[c])
					end

					--if EX and poffset > 0 then
					--	if o == octave2ex and c == class2ex then
					--		love.graphics.setColor(1,0,0,(exalpha)*volnorm)
					--		love.graphics.rectangle('fill', o*28+X[c], 0,
					--			W[c], H[c])
					--	end
					--end
					
				end
			end

			love.graphics.setColor(.5, .5, .5)
			for g = 0, 6 do
				love.graphics.rectangle('fill', o*28+gX[g], gY[g],
					1, gH[g])
			end
		end

		love.graphics.setColor(.5, .5, .5)
		love.graphics.rectangle('fill',0,0,10*28,1)

		love.graphics.translate(0, 12)
	end		
	love.graphics.pop()
	--]=]

	-- Matrix
	---[=[
	love.graphics.push()
	love.graphics.translate(74*8, 0)
	love.graphics.setColor(0,0,0.25)
	love.graphics.rectangle('fill',0,0,122*8,(module.channelCount+1)*12)
	love.graphics.setColor(1,1,1)
	love.graphics.translate(0,-2)
	love.graphics.print(
		"Ch | Nx Ix Vx Cx Dx | nPer gPer iPer cOfs smpL smpS smpE C4-speed T L H S | cI cV cP | FX Fg Fp Fv | Loop DCA T+- ~V# ~T#",
		0, 0)
	for ch = 0, module.channelCount-1 do
		love.graphics.print((
			"%02X | %02X %02X %02X %02X %02X | "..
			"%04X %04X %04X %04X %04X %04X %04X %08X %1X %1X %1X %1X | "..
			"%02X %02X %02X | %02X %02X %02X %02X | "..
			"%02X %1X %1X%1X%1X %1X%1X%1X %1X%02X %1X%02X"
			):format(ch, voice[ch]:getStatistics()), 0, (ch+1)*12)
	end
	love.graphics.pop()
	--]=]

end

routine.keypressed = function(k,s)
	if s == 'left' then
		visChOffset = math.max(0, visChOffset - 1)
		patternInvalidated = true
	elseif s == 'right' then
		visChOffset = math.min(module.channelCount-1, visChOffset + 1)
		patternInvalidated = true
	elseif s == 'up' then
		repeat
			currentOrder = (currentOrder - 1) % module.orderCount
			currentPattern = module.order[currentOrder]
		until currentPattern < 254
		currentRow = 0
		currentTick = 0
		patternInvalidated = true
	elseif s == 'down' then
		repeat
			currentOrder = (currentOrder + 1) % module.orderCount
			currentPattern = module.order[currentOrder]
		until currentPattern < 254
		currentRow = 0
		currentTick = 0
		patternInvalidated = true
	elseif s == 'w' then
		tempo = math.max(32, tempo - 1)
	elseif s == 's' then
		tempo = math.min(255, tempo + 1)
	elseif s == 'a' then
		speed = math.max(1, speed - 1)
	elseif s == 'd' then
		speed = math.min(255, speed + 1)
	elseif s == 'space' then
		smoothScrolling = not smoothScrolling
	end
end

--------------
return routine
