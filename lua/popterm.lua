local M = {}

local Popup = require("nui.popup")
local Layout = require("nui.layout")
local Menu = require("nui.menu")

-- ─── History ──────────────────────────────────────────────────────────────────

---@type string
local historyPath = vim.fn.stdpath("data") .. "/runner-nvim/historyterm.json"

local function saveHistory(data)
	vim.fn.writefile({ vim.json.encode(data) }, historyPath)
end

local function readHistory()
	local ok, lines = pcall(vim.fn.readfile, historyPath)
	if not ok or #lines == 0 then
		return {}
	end
	return vim.json.decode(lines[1]) or {}
end

local function getCwd()
	return string.gsub(vim.fn.getcwd(), "\\", "/")
end

local function updateHistory(cmd)
	local data = readHistory()
	data[getCwd()] = { cmd = cmd, time = os.time() }

	local items = {}
	for cwd, info in pairs(data) do
		table.insert(items, { cwd = cwd, time = info.time })
	end
	table.sort(items, function(a, b)
		return a.time < b.time
	end)

	while #items > 100 do
		data[table.remove(items, 1).cwd] = nil
	end

	saveHistory(data)
end

-- ─── Save Commands ────────────────────────────────────────────────────────────

---@type string
local cmdPath = vim.fn.stdpath("data") .. "/runner-nvim/commandterm.json"

local function saveCommand(data)
	vim.fn.writefile({ vim.json.encode(data) }, cmdPath)
end

local function readCommandList()
	local ok, lines = pcall(vim.fn.readfile, cmdPath)
	if not ok or #lines == 0 then
		return {}
	end
	return vim.json.decode(lines[1])
end

local function addCommandList(cmd)
	local data = readCommandList()
	data[cmd] = 1
	saveCommand(data)
end

local function removeCommandList(cmd)
	local data = readCommandList()
	data[cmd] = nil
	saveCommand(data)
end

-- local function addUnique(tbl, val)
-- 	if not tbl[val] then
-- 		table.insert(tbl, Menu.item(val))
-- 		tbl[val] = true
-- 	end
-- end

local function readCommands(tbl)
	local data = readCommandList()
	for cmd, _ in pairs(data) do
		table.insert(tbl, Menu.item(cmd))
	end
end

-- ─── Terminal ─────────────────────────────────────────────────────────────────

---@class Terminal
---@field terminal_popup any   nui Popup — the main shell panel
---@field input_popup    any   nui Popup — the command input bar
---@field menu_popup     any   nui Popup — the command menu bar
---@field layout         any   nui Layout — manages sizing of both panels
---@field jobId          integer?
---@field menuItems	 table
local Terminal = {}
Terminal.__index = Terminal

---@return Terminal
function Terminal:new()
	return setmetatable({
		terminal_popup = nil,
		input_popup = nil,
		menu_popup = nil,
		layout = nil,
		jobId = nil,
		menuItems = {},
	}, Terminal)
end

-- Creates the two Popup objects and the Layout, then wires up all keymaps.
function Terminal:init()
	self.terminal_popup = Popup({
		focusable = true,
		enter = true,
		border = {
			style = "rounded",
			text = {
				top = " Terminal ",
				top_align = "center",
				bottom = " <Cntl-s> focus input  <Cntl-q> close ",
				bottom_align = "right",
			},
		},
		win_options = {
			winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
		},
		buf_options = { modifiable = true },
	})

	self.input_popup = Popup({
		focusable = true,
		border = {
			style = "rounded",
			text = {
				top = " Command ",
				top_align = "left",
			},
		},
		win_options = {
			winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
		},
		buf_options = { modifiable = true },
	})

	self.menu_popup = Menu({
		focusable = true,
		border = {
			style = "rounded",
			text = {
				top = " Command List ",
				top_align = "center",
			},
		},
		win_options = {
			winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
		},
		-- buf_options = { modifiable = true },
	}, {
		lines = self.menuItems,
		max_width = 20,
		keymap = {
			focus_next = { "j", "<Down>", "<Tab>" },
			focus_prev = { "k", "<Up>", "<S-Tab>" },
			close = { "<Esc>", "<C-c>" },
		},
		on_close = function()
			print("Menu Closed!")
		end,
	})

	self.layout = Layout(
		{
			relative = "editor",
			position = "50%",
			size = { width = "80%", height = "80%" },
		},
		Layout.Box({
			Layout.Box(self.menu_popup, { size = "20%" }),
			Layout.Box({
				Layout.Box(self.terminal_popup, { size = "85%" }),
				Layout.Box(self.input_popup, { size = "15%" }),
			}, { dir = "col", size = "80%" }),
		}, { dir = "row" })
	)

	-- self.layout:mount()

	self:_initTerminal()
	self:_initInput()
	self:_initMenu()
end

-- Starts the shell job inside the terminal popup and sets up its keymaps.
function Terminal:_initTerminal()
	local buffer_dir = vim.fn.expand('%:p:h')
	self.layout:mount()
	vim.api.nvim_set_current_win(self.terminal_popup.winid)

	-- self.jobId = vim.fn.termopen({ vim.o.shell, "-i" }, {
	-- 	on_exit = function()
	-- 		self:destroy()
	-- 	end,
	-- 	cwd = getCwd(),
	-- })

	self.jobId = vim.fn.jobstart({ vim.o.shell, "-i" }, {
		cwd = buffer_dir,
		term = true,
		on_exit = function()
			self:destroy()
		end,
	})

	-- vim.fn.jobresize(
	-- 	self.jobId,
	-- 	vim.api.nvim_win_get_width(self.terminal_popup.winid),
	-- 	vim.api.nvim_win_get_height(self.terminal_popup.winid)
	-- )

	vim.cmd("startinsert")

	-- q closes everything from the terminal panel (normal mode)
	self.terminal_popup:map("n", "q", function()
		self:destroy()
	end, { noremap = true, silent = true })

	-- Tab to jump down to the input bar
	self.terminal_popup:map("n", "<Tab>", function()
		vim.api.nvim_set_current_win(self.input_popup.winid)
		vim.cmd("startinsert")
	end, { noremap = true, silent = true })

	-- Cntl-s to move to input box from terminal insert mode
	self.terminal_popup:map("t", "<C-s>", function()
		vim.api.nvim_set_current_win(self.input_popup.winid)
		vim.schedule(function()
			vim.cmd("startinsert")
		end)
	end, { noremap = true, silent = true })

	-- Cntl-q closes everything from the terminal panel (terminal insert mode)
	self.terminal_popup:map("t", "<C-q>", function()
		self:destroy()
	end, { noremap = true, silent = true })
end

-- Wires up the input bar as a prompt buffer with submit/cancel bindings.
function Terminal:_initInput()
	local buf = self.input_popup.bufnr

	vim.bo[buf].buftype = "prompt"
	vim.bo[buf].swapfile = false
	vim.bo[buf].bufhidden = "hide"
	vim.fn.prompt_setprompt(buf, "> ")

	-- Submit: send whatever is typed to the terminal
	local function submit()
		local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
		local cmd = line:gsub("^> ", "")
		if cmd ~= "" then
			self:_send(cmd)
			updateHistory(cmd)
			-- clear the input line
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
		end
		-- Return focus to the terminal
		--vim.api.nvim_set_current_win(self.terminal_popup.winid)
		--vim.cmd("startinsert")
	end

	self.input_popup:map("i", "<CR>", submit, { noremap = true, silent = true })
	self.input_popup:map("n", "<CR>", submit, { noremap = true, silent = true })

	-- Esc / q from input bar returns focus to terminal without running anything
	local function cancel()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
		vim.api.nvim_set_current_win(self.terminal_popup.winid)
		vim.schedule(function()
			vim.cmd("startinsert")
		end)
	end

	self.input_popup:map("i", "<C-w>", cancel, { noremap = true, silent = true })
	self.input_popup:map("i", "<C-a>", function()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
		vim.api.nvim_set_current_win(self.menu_popup.winid)
	end, { noremap = true, silent = true })
	self.input_popup:map("n", "q", function() self:destroy() end, { noremap = true, silent = true })
	self.input_popup:map("i", "<C-q>", function() self:destroy() end, { noremap = true, silent = true })


	local menuHidden = false
	self.input_popup:map("i", "<C-h>", function()
		if menuHidden == false then
			self.layout:update(
				Layout.Box({
					Layout.Box(self.terminal_popup, { size = "85%" }),
					Layout.Box(self.input_popup, { size = "15%" }),
				}, { dir = "col" }))
			menuHidden = true
		else
			self.layout:update(
				Layout.Box({
					Layout.Box(self.menu_popup, { size = "20%" }),
					Layout.Box({
						Layout.Box(self.terminal_popup, { size = "85%" }),
						Layout.Box(self.input_popup, { size = "15%" }),
					}, { dir = "col", size = "80%" }),
				}, { dir = "row" }))
			vim.api.nvim_set_current_win(self.input_popup.winid)
			vim.schedule(function()
				vim.cmd("startinsert")
			end)
			menuHidden = false
		end
	end, { noremap = true, silent = true })
end

function Terminal:_initMenu()
	self.menu_popup:map("n", "<CR>", function()
		self:_send(self.menu_popup.tree:get_node().text)
	end, { noremap = true, silent = true })
	self.menu_popup:map("n", "<C-q>", function() self:destroy() end, { noremap = true, silent = true })

	-- Cntl-s to move to input box from terminal insert mode
	self.menu_popup:map("n", "<C-d>", function()
		vim.api.nvim_set_current_win(self.input_popup.winid)
		vim.schedule(function()
			vim.cmd("startinsert")
		end)
	end, { noremap = true, silent = true })
end

-- Low-level: send raw text to the running shell job.
---@param cmd string
function Terminal:_send(cmd)
	if not self.jobId then
		return
	end

	-- vim.fn.jobresize(
	-- 	self.jobId,
	-- 	vim.api.nvim_win_get_width(self.terminal_popup.winid),
	-- 	vim.api.nvim_win_get_height(self.terminal_popup.winid)
	-- )

	-- clear terminal before every new command
	-- vim.api.nvim_chan_send(self.jobId, "clear\r")
	vim.api.nvim_chan_send(self.jobId, cmd .. "\r")
end

-- Public: send a command and record it in history.
---@param cmd string
function Terminal:run(cmd)
	self:show()
	vim.schedule(function()
		self:_send(cmd)
		updateHistory(cmd)
	end)
end

-- Hides both panels (keeps the job alive).
function Terminal:hide()
	if self.terminal_popup then
		self.terminal_popup:hide()
	end
	if self.input_popup then
		self.input_popup:hide()
	end
end

-- Shows both panels (or inits if they don't exist yet).
function Terminal:show()
	if not self.terminal_popup then
		self:init()
		return
	end
	self.terminal_popup:show()
	self.input_popup:show()
	vim.api.nvim_set_current_win(self.terminal_popup.winid)
	vim.schedule(function()
		vim.cmd("startinsert")
	end)
end

-- Fully tears down the layout and all popups.
function Terminal:destroy()
	if self.layout then
		self.layout:unmount()
	end
	self.terminal_popup = nil
	self.input_popup = nil
	self.layout = nil
	self.jobId = nil
end

-- Toggles visibility. If the terminal panel is the current window, hides.
-- If visible but not focused, focuses. If hidden, shows.
function Terminal:toggle()
	if not self.terminal_popup then
		self:init()
		return
	end

	local term_win_valid = self.terminal_popup.winid
	    and vim.api.nvim_win_is_valid(self.terminal_popup.winid)

	if not term_win_valid then
		-- Popups are hidden — show them
		self:show()
	elseif vim.api.nvim_get_current_win() == self.terminal_popup.winid
	    or vim.api.nvim_get_current_win() == self.input_popup.winid
	then
		-- We're inside the terminal UI — hide it
		self:hide()
	else
		-- It's open but we're elsewhere — focus it
		vim.api.nvim_set_current_win(self.terminal_popup.winid)
		vim.cmd("startinsert")
	end
end

-- ─── Public API ───────────────────────────────────────────────────────────────

---@type Terminal
local terminal

-- Opens a floating input prompt (separate from the layout) for one-off commands.
-- Useful before the terminal has been opened for the first time.
function M.run()
	-- If the terminal is already open, just focus the input bar directly
	if terminal.terminal_popup and terminal.input_popup then
		terminal:show()
		vim.api.nvim_set_current_win(terminal.input_popup.winid)
		vim.cmd("startinsert")
		return
	end

	-- Otherwise open the whole layout; the input bar is ready to type in
	terminal:init()
	vim.api.nvim_set_current_win(terminal.input_popup.winid)
	vim.cmd("startinsert")
end

-- Re-runs the last command used in this directory.
function M.runLast()
	local data = readHistory()
	local cmdInfo = data[getCwd()]
	if cmdInfo and cmdInfo.cmd then
		terminal:run(cmdInfo.cmd)
	else
		M.run()
	end
end

-- Toggles the terminal popup open/closed.
function M.toggle()
	terminal:toggle()
end

-- Call this from your config: require("runner-nvim").setup({})
---@param opts table?
function M.setup(opts)
	opts = opts or {}
	terminal = Terminal:new()

	vim.api.nvim_create_user_command('PoptermAddCommand', function(opt)
		table.insert(terminal.menuItems, Menu.item(opt.args))
		addCommandList(opt.args)
	end, { nargs = 1, complete = 'shellcmd' })

	vim.api.nvim_create_user_command('PoptermRemoveCommand', function(opt)
		-- table.insert(terminal.menuItems, Menu.item(opt.args))
		removeCommandList(opt.args)
		terminal.menuItems = {}
		readCommands(terminal.menuItems)
	end, { nargs = 1, complete = 'shellcmd' })

	if vim.fn.filereadable(historyPath) == 0 then
		vim.fn.mkdir(vim.fn.fnamemodify(historyPath, ":h"), "p")
		saveHistory({})
	end

	if vim.fn.filereadable(cmdPath) == 0 then
		vim.fn.mkdir(vim.fn.fnamemodify(cmdPath, ":h"), "p")
		saveCommand({})
	end

	readCommands(terminal.menuItems)

	-- local lookup = {}
	-- local function addUnique(value)
	-- 	if not lookup[value] then
	-- 		table.insert(terminal.menuItems, Menu.item(value))
	-- 		lookup[value] = true
	-- 	end
	-- end

	-- local ok, lines = pcall(vim.fn.readfile, historyPath)
	-- if ok or #lines ~= 0 then
	-- 	local data = vim.json.decode(lines[1]) or {}
	-- 	for cwd, cmdInfo in pairs(data) do
	-- 		if cmdInfo and cmdInfo.cmd then
	-- 			-- table.insert(terminal.menuItems, Menu.item(cmdInfo.cmd))
	-- 			addUnique(cmdInfo.cmd)
	-- 		end
	-- 	end
	-- end
end

-- vim.api.nvim_create_user_command('PoptermAddCommand', function(opts)
--   print(opts.args)
-- end, { nargs = 1, complete='shellcmd' })

return M
