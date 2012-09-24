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

-- custom kernel configuration
local USB_KERNEL_VERSION = 1
local USB_KERNEL_URL     = "http://triodeplugins.googlecode.com/files/kernel-digitalout-1.bin"
local USB_KERNEL_MD5     = "b1df8c851322d1b2bba0d1507e7e8f2e"


local playerPower, cpuActive


function jiveVersion(meta)
	return 1, 1
end


function defaultSettings(self)
	return {
		playbackDevice = "default",
		bufferTime = 20000,
		periodCount = 2,
		autoKernelUpdate = true,
		embeddedTTHack = false,
		cpuIdleFullspeed = false,
		firstUse = true
	}
end


function registerApplet(meta)
	local settings = meta:getSettings()
	local updating
	
	-- check kernel version and install if required, with safety checks...
	local fh1 = io.open("/proc/version")
	if fh1 then
		local text = fh1:read("*a")
		local ver  = string.match(text, "#(%d+)%[usb%]")

		if ver == nil or tonumber(ver) < USB_KERNEL_VERSION then
			log:info("kernel is not latest usb kernel")
			-- check we are enabled by appletInstaller to allow kernel update to be bypassed on factory reset
			local enabled = false
			local fh2 = io.open("/etc/squeezeplay/userpath/settings/SetupAppletInstaller.lua")
			if fh2 then
				local text = fh2:read("*a")
				if string.match(text, "EnhancedDigitalOutput") then
					enabled = true
				end
				fh2:close()
			end
			if enabled and settings.autoKernelUpdate then
				log:info("attempting to update kernel")
				local applet = appletManager:loadApplet('EnhancedDigitalOutput')
				applet:_kernelUpdate({ url = USB_KERNEL_URL, md5 = USB_KERNEL_MD5 })
				updating = true
			else
				log:warn("kernel does not support usb extensions")
			end

		else
			log:info("lastest usb kernel found")
			fh1:close()
		end
	end

	-- check if this is a new install and if so ensure custom jive_alsa is installed
	local newbinary = io.open("/usr/share/jive/applets/EnhancedDigitalOutput/jive_alsa", "r")
	if not updating and newbinary then
		log:info("installing modified jive_alsa")
		newbinary:close()
		os.execute("mv /usr/share/jive/applets/EnhancedDigitalOutput/jive_alsa /usr/bin/jive_alsa")
		os.execute("chmod 755 /usr/bin/jive_alsa")
	end

	-- if usb hack then set kernel option
	if settings.embeddedTTHack then
		_write("/sys/module/snd_usb_audio/parameters/async_embedded_tt_hack", "1")
	end

	-- check output device is available else bring up popup and restart if output attaches
	local playbackDeviceFound = true

	if not updating and settings.playbackDevice != "default" then

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
							appletManager:callService("reboot")
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
		local playbackDevice = (settings.playbackDevice != "default" and "hw:CARD=" or "") .. settings.playbackDevice
		log:info("playbackDevice: ", playbackDevice, " bufferTime: ", settings.bufferTime, " periodCount: ", settings.periodCount)
		Decode:open({
			alsaPlaybackDevice = playbackDevice,
			alsaSampleSize = 24,            -- auto detected by our jive_alsa
			alsaPlaybackBufferTime = settings.bufferTime,
			alsaPlaybackPeriodCount = settings.periodCount,
			alsaEffectsDevice = "disabled", -- rely on jive_alsa exiting as device can't be opened
		})
		
		-- if spdif or usb output increase priority of relavent irq task
		if settings.playbackDevice == "TXRX" then
			os.execute("chrt -f -p 59 `pidof 'IRQ-47'`")
		elseif settings.playbackDevice != "default" then
			os.execute("chrt -f -p 59 `pidof 'IRQ-37'`")
		end
	
	end

	-- register with NetworkThread to get callbacks on for player on/off and audio active/inactive
	jnt:subscribe(meta)
	jnt:registerCpuActive(function(active) cpuActive = active meta:cpuIdle() end)

	-- register menus
	jiveMain:addItem(
		meta:menuItem('appletEnhancedDigitalOutputDevices', 'settingsAudio', meta:string("APPLET_NAME"), 
			function(applet, ...) applet:deviceMenu(...) end
		)
	)
	jiveMain:addItem(
		meta:menuItem('appletEnhancedDigitalOutputOptions', 'advancedSettings', meta:string("APPLET_NAME"), 
			function(applet, ...) 
				applet.cpuIdle = function() meta:cpuIdle(true) end
				applet.kernel = { url = USB_KERNEL_URL, md5 = USB_KERNEL_MD5 }
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


function notify_playerPower(self, player, power)
	if player:isLocal() then
		playerPower = power
		self:cpuIdle()
	end
end


function cpuIdle(self, force)
	local filename = "/sys/power/pm_idle_fullspeed"
	local enabled  = self:getSettings()["cpuIdleFullspeed"]
	local setting  = (enabled and playerPower and cpuActive) and "1" or "0"
	if enabled or force then
		_write(filename, setting)
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
