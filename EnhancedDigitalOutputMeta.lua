--[[

Enhanced Digital Output Meta - support of usb audio and extended digital output capabilties via addon kernel

(c) 2012, Adrian Smith, triode1@btinternet.com

--]]

local oo            = require("loop.simple")
local os            = require("os")
local io            = require("io")
local AppletMeta    = require("jive.AppletMeta")
local System        = require("jive.System")
local Decode        = require("squeezeplay.decode")
local Timer         = require("jive.ui.Timer")
local Popup         = require("jive.ui.Popup")
local Label         = require("jive.ui.Label")
local Icon          = require("jive.ui.Icon")
local appletManager = appletManager

local jiveMain, jnt, string, tonumber = jiveMain, jnt, string, tonumber

--local debug = require("jive.utils.debug")

module(...)
oo.class(_M, AppletMeta)



local playerPower


function jiveVersion(meta)
	return 1, 1
end


function defaultSettings(self)
	return {
		playbackDevice = "MID",
		bufferTime = 20000,
		periodCount = 2,
		firstUse = true
	}
end


function registerApplet(meta)
	local settings = meta:getSettings()
    local updating = false


	-- check if this is a new install and if so ensure custom jive_alsa is installed
	local newbinary = io.open("/opt/squeezeplay/share/jive/applets/EnhancedDigitalOutput/jive_alsa", "r")
	if not updating and newbinary then
		log:info("installing modified jive_alsa")
		newbinary:close()
		os.execute("mv /opt/squeezeplay/share/jive/applets/EnhancedDigitalOutput/jive_alsa /opt/squeezeplay/bin/jive_alsa")
		os.execute("chmod 755 /opt/squeezeplay/bin/jive_alsa")
	end


	-- check output device is available else bring up popup and restart if output attaches
	local playbackDeviceFound = true

	if not updating and settings.playbackDevice != "MID" then

		local fh = io.open("/proc/asound/" .. settings.playbackDevice)
		if fh == nil then
			log:warn("playback device not found - waiting")
			playbackDeviceFound = false
			local timer, rebootTime

			-- stop animated wait for dac to be connected
			local popup = Popup("waiting_popup")
			local label = Label("text", meta:string("DAC_NOT_CONNECTED"))
			popup:addWidget(Icon("icon_connecting"))
			popup:addWidget(label)
			popup:show()

			-- restart if dac attached, clear timer if popup dismissed
			local check = function()
				if popup:isVisible() then
					fh = io.open("/proc/asound/" .. settings.playbackDevice)
					if fh ~= nil and not rebootTime then
						log:info("playback device attached - restarting")
						label:setValue(meta:string("REBOOTING"))
						fh:close()
						rebootTime = 3
					end
					if rebootTime then
						rebootTime = rebootTime - 1
						if rebootTime == 0 then
							log:info("rebooting")
							os.execute("sudo reboot")
						end
					end
					
				else
					timer:stop()
				end
			end

			timer = Timer(1000, function() check() end, false)
			timer:start()
		end

	end

	if not updating and playbackDeviceFound then

		-- init the decoder with our settings - we are loaded earlier than SqueezeboxFab4, decode:open ignores reopen
		local playbackDevice = "hw:CARD=" .. settings.playbackDevice
        --if settings.playbackDevice == "MID" then
        --    playbackDevice = "default"
        --end          
		log:info("playbackDevice: ", playbackDevice, " bufferTime: ", settings.bufferTime, " periodCount: ", settings.periodCount)
		Decode:open({
			alsaPlaybackDevice = playbackDevice,
			alsaSampleSize = 24,            -- auto detected by our jive_alsa
			alsaPlaybackBufferTime = settings.bufferTime,
			alsaPlaybackPeriodCount = settings.periodCount,
			alsaEffectsDevice = "disabled", -- rely on jive_alsa exiting as device can't be opened
		})
		
		-- if spdif or usb output increase priority of relavent irq task
		--if settings.playbackDevice == "TXRX" then
		--	os.execute("chrt -f -p 59 `pidof 'IRQ-47'`")
		--elseif settings.playbackDevice != "default" then
		--	os.execute("chrt -f -p 59 `pidof 'IRQ-37'`")
		--end
	
	end

	-- register with NetworkThread to get callbacks on for player on/off and audio active/inactive
	--jnt:subscribe(meta)
	--jnt:registerCpuActive(function(active) cpuActive = active meta:cpuIdle() end)

	-- register menus
	jiveMain:addItem(
		meta:menuItem('appletEnhancedDigitalOutputDevices', 'settingsAudio', meta:string("APPLET_NAME"), 
			function(applet, ...) applet:deviceMenu(...) end
		)
	)
	jiveMain:addItem(
		meta:menuItem('appletEnhancedDigitalOutputOptions', 'advancedSettings', meta:string("APPLET_NAME"), 
			function(applet, ...) 
				applet:optionsMenu(...) 
			end
		)
	)

	-- first use dialog
	if not updating and settings.firstUse then
		settings.firstUse = false
		meta:storeSettings()
		local applet = appletManager:loadApplet('EnhancedDigitalOutput')
		applet:deviceMenu(nil, true)
	end

end


function _write(file, val)
	log:info("writing ", val, " to ", file)

	local fh, err = io.open(file, "w")
	if err then
		log:warn("Can't write to ", file)
		return
	end

	fh:write(val)
	fh:close()
end
