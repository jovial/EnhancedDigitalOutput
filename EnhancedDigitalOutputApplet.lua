--[[

Enhanced Digital Output Applet - support of usb audio and extended digital output capabilties via addon kernel

(c) 2012, Adrian Smith, triode1@btinternet.com

--]]

local oo               = require("loop.simple")
local io               = require("io")
local os               = require("os")
local Applet           = require("jive.Applet")
local System           = require("jive.System")
local Framework        = require("jive.ui.Framework")
local SimpleMenu       = require("jive.ui.SimpleMenu")
local Textarea         = require("jive.ui.Textarea")
local Label            = require("jive.ui.Label")
local Popup            = require("jive.ui.Popup")
local Checkbox         = require("jive.ui.Checkbox")
local RadioGroup       = require("jive.ui.RadioGroup")
local RadioButton      = require("jive.ui.RadioButton")
local Slider           = require("jive.ui.Slider")
local Surface          = require("jive.ui.Surface")
local Task             = require("jive.ui.Task")
local Timer            = require("jive.ui.Timer")
local Icon             = require("jive.ui.Icon")
local Window           = require("jive.ui.Window")
local debug            = require("jive.utils.debug")

local JIVE_VERSION     = jive.JIVE_VERSION
local appletManager    = appletManager

local STOP_SERVER_TIMEOUT = 10

local string, ipairs, tonumber, tostring, require, type = string, ipairs, tonumber, tostring, require, type

module(..., Framework.constants)
oo.class(_M, Applet)


function deviceMenu(self, menuItem, firstUse)
	local window = Window("text_list", self:string("SELECT_OUTPUT"))
	local menu = SimpleMenu("menu")
	window:addWidget(menu)

	-- refreshing menu to detect hotplugging of usb dacs
	local timer

	local updateMenu = function()
		local info = self:_parseCards()
		local curr = self:getSettings()["playbackDevice"]
		
		local items = {}

		--if curr == "default" then
			--if not firstUse then
				--items[#items+1] = {
					--text = tostring(self:string("ANALOG_DIGITAL")) .. tostring(self:string("CURRENT")),
				--}
			--end
		--else
			--items[#items+1] = {
				--text = self:string("ANALOG_DIGITAL"),
				--sound = "WINDOWSHOW",
				--callback = function(event, menuItem)
					--		   timer:stop()
						--	   self:_setCardAndReboot("default", false)
						  -- end,
			--}
		--end
		
		for num, card in ipairs(info) do
			if curr != card.id then
				items[#items+1] = {
					text = card.desc,
					sound = "WINDOWSHOW",
					callback = function(event, menuItem)
								   timer:stop()
								   if card.needshub then
									   -- this is a usb1 async dac without a hub - ask whether to use embeddedTTHack
									   local window = Window("text_list", menuItem.text)
									   local menu = SimpleMenu("menu")
									   menu:setHeaderWidget(Textarea("help_text", self:string("HELP_USB1_DAC")))
									  -- menu:addItem({
										--	text = self:string("USB1_DAC_NO_HUB"),
											--style = 'item_choice',
											--callback = function(event, menuItem)
												--		   self:_setCardAndReboot(card.id, true)
													--   end,
									   --})
									   menu:addItem({
											text = self:string("USB1_DAC_HUB"),
											style = 'item_choice',
											callback = function(event, menuItem)
														   self:_setCardAndReboot(card.id, false)
													   end,
									   })
									   window:addWidget(menu)
									   window:show()
								   else
									   self:_setCardAndReboot(card.id, false)
								   end
							   end,
				}
			elseif card.id == "MID" then
				items[#items+1] = {
					text = card.desc .. tostring(self:string("CURRENT")),
				}
			else
				items[#items+1] = {
					text = card.desc .. tostring(self:string("INFO")),
					sound = "WINDOWSHOW",
					callback = function(event, menuItem)
								   timer:stop()
								   self:_showStats(card.id, card.desc)
							   end,
				}
			end
		end

		if firstUse then
			menu:setHeaderWidget(Textarea("help_text", self:string("HELP_FIRST_USE")))
		end

		menu:setItems(items, #items)
	end

	-- update on a timer
	timer = Timer(1000, function() updateMenu() end, false)
	timer:start()

	-- initial display
	updateMenu()

	-- cancel timer when window is hidden (e.g. screensaver)
	window:addListener(EVENT_WINDOW_ACTIVE | EVENT_HIDE,
		function(event)
			local type = event:getType()
			if type == EVENT_WINDOW_ACTIVE then
				timer:restart()
			else
				timer:stop()
			end
			return EVENT_UNUSED
		end,
		true
	)

	self:tieAndShowWindow(window)
	return window
end


function optionsMenu(self, menuItem)
	local window = Window("text_list", menuItem.text)
	local menu = SimpleMenu("menu")
	window:addWidget(menu)

	menu:addItem({
		text = self:string("SELECT_OUTPUT"),
		sound = "WINDOWSHOW",
		callback = function(event, menuItem)
					   self:deviceMenu(menuItem, false)
				   end
	})




	menu:addItem({
		text = self:string("BUFFER_TUNING"),
		sound = "WINDOWSHOW",
		callback = function(event, menuItem)
					   local options = {
						   { desc = "BUFFER_DEFAULT", time =  20000, count =   2 },
						   { desc = "BUFFER_LARGE",   time = 100000, count =   4 },
						   { desc = "BUFFER_SMALL",   time =   4000, count =   2 },
						   { desc = "BUFFER_RAND",    time = 100000, count = 104 },
						   { desc = "BUFFER_VLARGE",  time =4000000, count =   4 },
						   { desc = "BUFFER_VLRAND",  time =4000000, count = 104 },
					   }
					   local window = Window("text_list", menuItem.text)
					   local menu = SimpleMenu("menu")
					   local group = RadioGroup()
					   local settings = self:getSettings()
					   menu:setHeaderWidget(Textarea("help_text", self:string("HELP_BUFFER_TUNING")))
					   for _, opt in ipairs(options) do
						   menu:addItem({
								text = self:string(opt.desc),
								style = 'item_choice',
								check = RadioButton("radio", group,
													function(event, menuItem)
														settings.bufferTime = opt.time
														settings.periodCount = opt.count
														self:storeSettings()
														self:_restart()
													end,
													settings.bufferTime == opt.time and settings.periodCount == opt.count)
						   })
					   end
					   window:addWidget(menu)
					   window:show()
				   end,
	})

	self:tieAndShowWindow(window)
	return window
end


function _parseCards(self)
	local t = {}

	local cards = io.open("/proc/asound/cards", "r")

	if cards == nil then
		log:error("/proc/asound/cards could not be opened")
		return
	end

	-- read and parse entries
	for line in cards:lines() do
		local num, id, desc = string.match(line, "(%d+)%s+%[(.-)%s+%]:%s+(.*)")
		if id and id != "TXRX" and id != "fab4" and id != "fab4_1" then
			-- usb card - get bitdepth info
			local info = self:_parseStreamInfo(id)
			t[#t+1] = { id = id, desc = desc, needshub = info.needshub }
		end
	end

	cards:close()

	return t
end


function _parseStreamInfo(self, card)
	local bits, needhub, async
	local t = {}
	
	local cards = io.open("/proc/asound/" .. card .. "/stream0", "r")
	
	if cards == nil then
		log:error("/proc/asound/" .. card .. "/stream0 could not be opened")
		return t
	end
	
	-- parsing helper functions
	local last
	local parse = function(regexp, opt)
		local tmp = last or cards:read()
		if tmp == nil then
			return
		end
		local r1, r2, r3 = string.match(tmp, regexp)
		if opt and r1 == nil and r2 == nil and r3 == nil then
			last = tmp
		else
			last = nil
		end
		return r1, r2, r3
	end

	local skip = function(number) 
		if last and number > 0 then
			last = nil
			number = number - 1
		end
		while number > 0 do
			cards:read()
			number = number - 1
		end
	end

	local eof = function()
		if last then return false end
		last = cards:read()
		return last == nil
	end

	-- detect full speed async devices without external hub
	t.id, t.speed = parse("usb%-fsl%-ehci%.(.-),%s(%w+)%sspeed%s:")
	t.hub = (t.id != "0-1")
	skip(2)

	-- detect status
	t.status = parse("  Status: (%w+)")

	if t.status == "Running" then
		t.interface = parse("    Interface = (%d+)")
		t.altset    = parse("    Altset = (%d+)")
		skip(2)
		t.momfreq   = parse("    Momentary freq = (%d+) Hz")
		t.feedbkfmt = parse("    Feedback Format = (.*)", true)
	end
	
	local fmts = {}

	while not eof() do

		local intf = parse("  Interface (%d+)")
		local alt  = parse("    Altset (%d+)")
		local fmt  = parse("    Format: (.*)")
		local chan = parse("    Channels: (%w+)")
		local type = parse("    Endpoint: %d+ %w+ %((%w+)%)")
		local rate = parse("    Rates: (.*)")
		local int  = parse("    Data packet interval: (.*)") or 'unknown'
		skip(2)

		fmts[#fmts+1] = { intf = intf, alt = alt, fmt = fmt, chan = chan, type = type, rate = rate, int = int }

		if t.interface == intf and t.altset == alt then
			t.fmt = fmts[#fmts]
		end

		-- touch needs a hub in this case only due to imx35 embedded TT limitations
		if type == "ASYNC" and t.speed == "full" and not t.hub then
			--t.needshub = true
            t.needshub = false
		end

	end
	
	t.fmts = fmts

	cards:close()

	return t
end


function _setCardAndReboot(self, card, embeddedTTHack)
	local s = self:getSettings()

	s.playbackDevice = card

	self:storeSettings()

	self:_restart()
end


function _showStats(self, card, desc)
	-- check we can open the /proc file
	local info = io.open("/proc/asound/" .. card .. "/stream0", "r")

	if info == nil then
		log:error("/proc/asound/" .. card .. "/stream0" .. " could not be opened")
		return
	end

	info:close()

	local window = Window("text_list", desc)
	local menu = SimpleMenu("menu")
	window:addWidget(menu)
	self:tieAndShowWindow(window)

	-- refreshing menu to detect hotplugging of usb dacs
	local timer

	local display = function()
						log:debug("fetching info...")
						local info = self:_parseStreamInfo(card)
						local items = {}
						local entry = function(text)
										  items[#items+1] = {
											  text = text,
											  style = "item_no_arrow",
										  }
									  end
						entry("Status: " .. info.status)
						entry("Speed: " .. (info.speed == "full" and "Full" or "High"))
						entry("Connection: " .. (info.hub and "via Hub" or "Direct"))
						if info.status == "Running" then
							local first, rest = string.match(info.fmt.type, "(%w)(%w+)")
							entry("Type: " .. string.upper(first) .. string.lower(rest))
							entry("Frequency: " .. info.momfreq .. " Hz")
							entry("Format: " .. info.fmt.fmt)
							entry("Rates: " .. info.fmt.rate)
							entry("Feedback Format: " .. ((info.feedbkfmt == "10.14" and "Full (10.14)") or 
														  (info.feedbkfmt == "16.16" and "High (16.16)") or "None"))
							entry("Interval: " .. info.fmt.int )
						else
							local i = 1
							while info.fmts[i] do
								local fmt = info.fmts[i]
								local cnt = #info.fmts > 1 and (" [" .. i .. "]: ") or ": "
								local first, rest = string.match(fmt.type, "(%w)(%w+)")
								entry("Type" .. cnt .. string.upper(first) .. string.lower(rest))
								entry("Format" .. cnt .. fmt.fmt)
								entry("Rates" .. cnt .. fmt.rate)
								i = i + 1
							end
						end
						menu:setItems(items, #items)
					end
	
	-- initial display
	display()

	-- update on a timer
	local timer = Timer(1000, function() display() end, false)
	timer:start()

	-- cancel timer when window is hidden (e.g. screensaver)
	window:addListener(EVENT_WINDOW_ACTIVE | EVENT_HIDE,
		function(event)
			local type = event:getType()
			if type == EVENT_WINDOW_ACTIVE then
				timer:restart()
			else
				timer:stop()
			end
			return EVENT_UNUSED
		end,
		true
	)
end


function _restart(self)
	self.popup = Popup("update_popup")
	self.popup:addWidget(Icon("icon_restart"))
	self.popup:addWidget(Label("text", self:string("REBOOTING")))
	self:tieAndShowWindow(self.popup)

	self.timer = Timer(3000,
					   function()
						   log:info("rebooting...")
						   os.execute("sudo reboot")
					   end,
					   true)
	self.timer:start()
end


