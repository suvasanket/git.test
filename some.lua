-- =============================================================================
-- STANDALONE GIT EDITOR REDIRECTION TEST
-- =============================================================================

-- 1. DEFINE THE GLOBAL HANDLER
-- This needs to be global (_G) so the remote headless instance can find it via RPC.
_G.GitHandler = function(file_path, wait_file_path)
    print(">> Request received! Opening: " .. file_path)

    -- Open the file Git wants us to edit in a split
    vim.cmd("split " .. vim.fn.fnameescape(file_path))

    -- Get the buffer ID of the newly opened file
    local buf = vim.api.nvim_get_current_buf()

    -- Set an autocommand to cleanup when you close the buffer
    vim.api.nvim_create_autocmd("BufUnload", {
        buffer = buf,
        once = true,
        callback = function()
            print(">> Buffer closed. Releasing Git process...")
            -- Delete the lockfile. The background process watches for this deletion.
            os.remove(wait_file_path)
        end
    })
end

-- 2. HELPER: GENERATE THE "GHOST" SCRIPT
-- This creates the Lua script that the background "GIT_EDITOR" will run.
local function create_ghost_script()
    local script_path = os.tmpname() .. ".lua"

    -- This Lua code runs inside the HEADLESS Neovim instance spawned by Git
    local content = [[
    local server_addr = os.getenv("NVIM_SERVER_ADDRESS")
    local wait_file = os.getenv("NVIM_WAIT_FILE")
    local target_file = arg[1] -- Git passes the filepath as arg 1

    if not server_addr or not wait_file then os.exit(1) end

    -- A. Connect back to the main Neovim instance
    local chan = vim.fn.sockconnect("pipe", server_addr, { rpc = true })
    if chan == 0 then os.exit(1) end

    -- B. Tell Main Neovim to run the global function _G.GitHandler
    -- We pass the target file and the wait file path
    local ok, err = pcall(vim.rpcrequest, chan, "nvim_exec_lua", 
    "return _G.GitHandler(...)", 
    { target_file, wait_file }
)

if not ok then os.exit(1) end

-- C. Create the Lockfile (Signal that we are ready and waiting)
local f = io.open(wait_file, "w")
if f then f:write("locked"); f:close() end

-- D. The Wait Loop
-- We sleep as long as the file exists. Main Neovim deletes it on BufUnload.
while vim.fn.filereadable(wait_file) == 1 do
    vim.cmd("sleep 50m")
end

-- E. Exit cleanly
os.exit(0)
]]

local f = io.open(script_path, "w")
f:write(content)
f:close()
return script_path
end

-- 3. THE COMMAND FUNCTION
local function run_interactive_git()
    -- Check if we are in a git repo
    local is_git = vim.fn.system("git rev-parse --is-inside-work-tree")
    if vim.v.shell_error ~= 0 then
        print("Error: Not inside a git repository.")
        return
    end

    local wait_file = os.tmpname()
    local ghost_script = create_ghost_script()

    -- The command Git will use as its editor
    local fake_editor = string.format("nvim --clean --headless --noplugin -l %s", ghost_script)

    -- Setup Environment
    local env = vim.fn.environ()
    env["GIT_EDITOR"] = fake_editor
    env["GIT_SEQUENCE_EDITOR"] = fake_editor
    env["NVIM_SERVER_ADDRESS"] = vim.v.servername
    env["NVIM_WAIT_FILE"] = wait_file

    print(">> Starting Git Rebase...")

    -- Run Git
    vim.fn.jobstart({ "git", "commit" }, {
        env = env,
        on_exit = function(_, code)
            -- Cleanup
            os.remove(ghost_script)

            if code == 0 then
                print(">> Git Rebase Finished Successfully.")
            else
                print(">> Git Rebase Aborted or Failed.")
            end
            vim.cmd("checktime") -- Refresh buffers
        end,
        on_stderr = function(_, data)
            if data then
                local msg = table.concat(data, "\n")
                if msg ~= "" then print("Git Error: " .. msg) end
            end
        end
    })
end

-- 4. CREATE USER COMMAND
vim.api.nvim_create_user_command("TestRebase", run_interactive_git, {})

print("Loaded! Run :TestRebase to try it out.")
