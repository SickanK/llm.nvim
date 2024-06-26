local nio = require("nio")
local M = {}

local timeout_ms = 10000
local streaming_mode = false
local cancel_streaming = false

local service_lookup = {}

local function get_api_key(name)
	return os.getenv(name)
end

function M.setup(opts)
	timeout_ms = opts.timeout_ms or timeout_ms
	if opts.services then
		for key, service in pairs(opts.services) do
			service_lookup[key] = service
		end
	end
	vim.api.nvim_set_keymap(
		"n",
		"<leader>x",
		':lua require("llm").exit_streaming_mode()<CR>',
		{ noremap = true, silent = true }
	)
end

function M.get_lines_until_cursor()
	local current_buffer = vim.api.nvim_get_current_buf()
	local current_window = vim.api.nvim_get_current_win()
	local cursor_position = vim.api.nvim_win_get_cursor(current_window)
	local row = cursor_position[1]

	local lines = vim.api.nvim_buf_get_lines(current_buffer, 0, row, true)

	return table.concat(lines, "\n")
end

local function write_string_at_cursor(str)
	local current_window = vim.api.nvim_get_current_win()
	local cursor_position = vim.api.nvim_win_get_cursor(current_window)
	local row, col = cursor_position[1], cursor_position[2]

	local lines = vim.split(str, "\n")
	vim.api.nvim_buf_set_text(0, row - 1, col, row - 1, col, lines)

	local num_lines = #lines
	local last_line_length = #lines[num_lines]
	vim.api.nvim_win_set_cursor(current_window, { row + num_lines - 1, col + last_line_length })
end

local function get_content_from_data(data, service)
	local content
	if string.find(service, "anthropic") then
		if data.delta and data.delta.text then
			content = data.delta.text
		end
	else
		if data.choices and data.choices[1] and data.choices[1].delta then
			content = data.choices[1].delta.content
		end
	end
	return content
end

local function process_data_lines(lines, service, process_data)
	for _, line in ipairs(lines) do
		local data_start = line:find("data: ")
		if data_start then
			local json_str = line:sub(data_start + 6)
			local stop = false
			if line == "data: [DONE]" then
				return true
			end
			local success, data = pcall(vim.json.decode, json_str)
			if not success then
				print("Failed to decode JSON: " .. json_str)
				goto continue
			end
			if string.find(service, "anthropic") then
				stop = data.type == "message_stop"
			end
			if stop then
				return true
			else
				nio.sleep(5)
				vim.schedule(function()
					vim.cmd("undojoin")
					process_data(data)
				end)
			end
		end
		::continue::
	end
	return false
end

local function process_sse_response(response, service)
	local buffer = ""
	local has_tokens = false
	local start_time = vim.loop.now()

	local function check_timeout()
		local current_time = vim.loop.now()
		if current_time - start_time >= timeout_ms and not has_tokens then
			print("llm.nvim has timed out!")
			streaming_mode = false
			response.stdout.close()
		end
	end

	streaming_mode = true
	cancel_streaming = false

	while streaming_mode do
		check_timeout()

		local chunk = response.stdout.read(1024)
		if chunk == nil then
			break
		end
		buffer = buffer .. chunk

		local lines = {}
		for line in buffer:gmatch("(.-)\r?\n") do
			table.insert(lines, line)
		end

		buffer = buffer:sub(#table.concat(lines, "\n") + 1)

		local done = process_data_lines(lines, service, function(data)
			local content = get_content_from_data(data, service)
			if content and content ~= vim.NIL then
				has_tokens = true
				vim.schedule(function()
					write_string_at_cursor(content)
				end)
			end
		end)

		if done then
			streaming_mode = false
		end

		nio.sleep(10) -- Small sleep to prevent busy-waiting
	end
end

function M.prompt(opts)
	local replace = opts.replace
	local service = opts.service
	local prompt = ""
	local visual_lines = M.get_visual_selection()
	local found_service = service_lookup[service]
	local system_prompt = found_service.system_prompt
		or [[ In the voice of an angry pirate, yell at me and tell me that i haven't set up my system prompt]]
	if visual_lines then
		prompt = table.concat(visual_lines, "\n")
		if replace then
			vim.api.nvim_command("normal! d")
			vim.api.nvim_command("normal! k")
		else
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", false, true, true), "nx", false)
		end
	else
		prompt = M.get_lines_until_cursor()
	end

	local url = ""
	local model = ""
	local api_key_name = ""

	if found_service then
		url = found_service.url
		api_key_name = found_service.api_key_name
		model = found_service.model
	else
		print("Invalid service: " .. service)
		return
	end

	local api_key = api_key_name and get_api_key(api_key_name)

	local data
	if string.find(service, "anthropic") then
		data = {
			system = system_prompt,
			messages = {
				{
					role = "user",
					content = prompt,
				},
			},
			model = model,
			stream = true,
			max_tokens = 1024,
		}
	else
		data = {
			messages = {
				{
					role = "system",
					content = system_prompt,
				},
				{
					role = "user",
					content = prompt,
				},
			},
			model = model,
			temperature = 0.7,
			stream = true,
		}
	end

	local args = {
		"-N",
		"-X",
		"POST",
		"-H",
		"Content-Type: application/json",
		"-d",
		vim.json.encode(data),
	}

	if api_key then
		if string.find(service, "anthropic") then
			table.insert(args, "-H")
			table.insert(args, "x-api-key: " .. api_key)
			table.insert(args, "-H")
			table.insert(args, "anthropic-version: 2023-06-01")
		else
			table.insert(args, "-H")
			table.insert(args, "Authorization: Bearer " .. api_key)
		end
	end

	table.insert(args, url)

	local response = nio.process.run({
		cmd = "curl",
		args = args,
	})
	nio.run(function()
		vim.schedule(function()
			vim.api.nvim_command("normal! o")
		end)
		process_sse_response(response, service)
	end)
end

function M.exit_streaming_mode()
	if streaming_mode then
		cancel_streaming = true
		vim.cmd("stopinsert")
		print("Exiting streaming mode...")
	else
		print("Not in streaming mode.")
	end
end

function M.get_visual_selection()
	local _, srow, scol = unpack(vim.fn.getpos("v"))
	local _, erow, ecol = unpack(vim.fn.getpos("."))

	-- visual line mode
	if vim.fn.mode() == "V" then
		if srow > erow then
			return vim.api.nvim_buf_get_lines(0, erow - 1, srow, true)
		else
			return vim.api.nvim_buf_get_lines(0, srow - 1, erow, true)
		end
	end

	-- regular visual mode
	if vim.fn.mode() == "v" then
		if srow < erow or (srow == erow and scol <= ecol) then
			return vim.api.nvim_buf_get_text(0, srow - 1, scol - 1, erow - 1, ecol, {})
		else
			return vim.api.nvim_buf_get_text(0, erow - 1, ecol - 1, srow - 1, scol, {})
		end
	end

	-- visual block mode
	if vim.fn.mode() == "\22" then
		local lines = {}
		if srow > erow then
			srow, erow = erow, srow
		end
		if scol > ecol then
			scol, ecol = ecol, scol
		end
		for i = srow, erow do
			table.insert(
				lines,
				vim.api.nvim_buf_get_text(0, i - 1, math.min(scol - 1, ecol), i - 1, math.max(scol - 1, ecol), {})[1]
			)
		end
		return lines
	end
end

function M.create_llm_md()
	local cwd = vim.fn.getcwd()
	local cur_buf = vim.api.nvim_get_current_buf()
	local cur_buf_name = vim.api.nvim_buf_get_name(cur_buf)
	local llm_md_path = cwd .. "/llm.md"
	if cur_buf_name ~= llm_md_path then
		vim.api.nvim_command("edit " .. llm_md_path)
		local buf = vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
		vim.api.nvim_win_set_buf(0, buf)
	end
end

return M
