-- Update notice: compares the commit hash this copy was released at
-- (drone/VERSION, bundled with the script) against the same file read live
-- from the repo's main branch on GitHub. No version-control logic here --
-- just two short hashes and a string comparison. Silent on any failure
-- (offline, GitHub down, file missing) -- this is a courtesy notice, never
-- something that should interrupt flying.
local M = {}

M.REPO_URL = 'https://github.com/invilso/gta-fpv-drone'
local REMOTE_VERSION_URL = 'https://raw.githubusercontent.com/invilso/gta-fpv-drone/main/drone/VERSION'
local LOCAL_VERSION_PATH = getWorkingDirectory() .. '\\drone\\VERSION'
local TMP_PATH = getWorkingDirectory() .. '\\config\\gta-fpv-drone-remote-version.tmp'

M.localVersion = nil
M.remoteVersion = nil
M.updateAvailable = false

local function readFirstLine(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local line = f:read('*l')
    f:close()
    return line and line:gsub('%s+$', '') or nil
end

-- Fire-and-forget, call once at script startup. Result lands in
-- M.updateAvailable whenever the download finishes (or never, if offline --
-- that's fine, it just means no notice this session).
function M.check()
    M.localVersion = readFirstLine(LOCAL_VERSION_PATH)
    if not M.localVersion then return end -- unreleased/dev copy, no VERSION file -- nothing to compare

    local dlstatus = require('moonloader').download_status
    downloadUrlToFile(REMOTE_VERSION_URL, TMP_PATH, function(_, status)
        if status ~= dlstatus.STATUSEX_ENDDOWNLOAD and status ~= dlstatus.STATUS_ENDDOWNLOADDATA then return end
        M.remoteVersion = readFirstLine(TMP_PATH)
        if M.remoteVersion and M.remoteVersion ~= M.localVersion then
            M.updateAvailable = true
            print(('FPV Drone: update available (you have %s, latest is %s) -- %s')
                :format(M.localVersion, M.remoteVersion, M.REPO_URL))
        end
    end)
end

return M
