local M = {}

local Popup = require("nui.popup")
local Layout = require("nui.layout")
local event = require("nui.utils.autocmd").event

-- ─── History ──────────────────────────────────────────────────────────────────

---@type string
local historyPath = vim.fn.stdpath("data") .. "/popterm-nvim/history.json"

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

-- ─── Terminal ─────────────────────────────────────────────────────────────────

---@class Terminal
---@field terminal_popup any   nui Popup — the main shell panel
---@field input_popup    any   nui Popup — the command input bar
---@field layout         any   nui Layout — manages sizing of both panels
---@field jobId          integer?
local Terminal = {}
Terminal.__index = Terminal

---@return Terminal
function Terminal:new()
	return setmetatable({
		terminal_popup = nil,
		input_popup = nil,
		layout = nil,
		jobId = nil,
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

	self.layout = Layout(
		{
			relative = "editor",
			position = "50%",
			size = { width = "80%", height = "80%" },
		},
		Layout.Box({
			Layout.Box(self.terminal_popup, { size = "85%" }),
			Layout.Box(self.input_popup, { size = "15%" }),
		}, { dir = "col" })
	)

	self.layout:mount()

	self:_initTerminal()
	self:_initInput()
end

-- Starts the shell job inside the terminal popup and sets up its keymaps.
function Terminal:_initTerminal()
	vim.api.nvim_set_current_win(self.terminal_popup.winid)

	self.jobId = vim.fn.termopen({ vim.o.shell, "-i" }, {
		on_exit = function()
			self:destroy()
		end,
	})

	vim.fn.jobresize(
		self.jobId,
		vim.api.nvim_win_get_width(self.terminal_popup.winid),
		vim.api.nvim_win_get_height(self.terminal_popup.winid)
	)

	vim.cmd("startinsert")

	-- cd into the cwd we launched from
	self:_send("cd " .. getCwd())

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
	self.input_popup:map("n", "q", function() self:destroy() end, { noremap = true, silent = true })
	self.input_popup:map("i", "<C-q>", function() self:destroy() end, { noremap = true, silent = true })
end

-- Low-level: send raw text to the running shell job.
---@param cmd string
function Terminal:_send(cmd)
	if not self.jobId then
		return
	end
	vim.fn.jobresize(
		self.jobId,
		vim.api.nvim_win_get_width(self.terminal_popup.winid),
		vim.api.nvim_win_get_height(self.terminal_popup.winid)
	)
	-- clear terminal before every new command
	vim.api.nvim_chan_send(self.jobId, "clear\r")
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

	if vim.fn.filereadable(historyPath) == 0 then
		vim.fn.mkdir(vim.fn.fnamemodify(historyPath, ":h"), "p")
		saveHistory({})
	end
end

return M
