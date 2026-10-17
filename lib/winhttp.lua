-- Synchronous HTTP(S) over Windows' WinHTTP, through the LuaJIT FFI.
-- Blocking: only call this from a love.thread (see lib/http.lua).

local ffi = require("ffi")

ffi.cdef[[
typedef void* HINTERNET;
typedef uint16_t WCHAR;
typedef uint32_t DWORD;
typedef int BOOL;

HINTERNET WinHttpOpen(const WCHAR* agent, DWORD accessType, const WCHAR* proxy, const WCHAR* bypass, DWORD flags);
HINTERNET WinHttpConnect(HINTERNET session, const WCHAR* server, uint16_t port, DWORD reserved);
HINTERNET WinHttpOpenRequest(HINTERNET connect, const WCHAR* verb, const WCHAR* object, const WCHAR* version,
                             const WCHAR* referrer, const WCHAR** acceptTypes, DWORD flags);
BOOL WinHttpSetTimeouts(HINTERNET h, int resolve, int connect, int send, int receive);
BOOL WinHttpSetOption(HINTERNET h, DWORD option, void* buffer, DWORD length);
BOOL WinHttpAddRequestHeaders(HINTERNET request, const WCHAR* headers, DWORD length, DWORD modifiers);
BOOL WinHttpSendRequest(HINTERNET request, const WCHAR* headers, DWORD headersLength, void* optional,
                        DWORD optionalLength, DWORD totalLength, uintptr_t context);
BOOL WinHttpReceiveResponse(HINTERNET request, void* reserved);
BOOL WinHttpQueryHeaders(HINTERNET request, DWORD infoLevel, const WCHAR* name, void* buffer,
                         DWORD* bufferLength, DWORD* index);
BOOL WinHttpQueryDataAvailable(HINTERNET request, DWORD* available);
BOOL WinHttpReadData(HINTERNET request, void* buffer, DWORD toRead, DWORD* read);
BOOL WinHttpCloseHandle(HINTERNET h);

DWORD GetLastError(void);
int MultiByteToWideChar(unsigned codePage, DWORD flags, const char* str, int len, WCHAR* out, int outLen);
int WideCharToMultiByte(unsigned codePage, DWORD flags, const WCHAR* str, int len, char* out, int outLen,
                        const char* defaultChar, BOOL* usedDefault);
]]

local winhttp = ffi.load("winhttp")
local C = ffi.C

local CP_UTF8 = 65001
local ACCESS_TYPE_DEFAULT_PROXY = 0
local ACCESS_TYPE_AUTOMATIC_PROXY = 4    -- Windows 8.1+
local FLAG_SECURE = 0x00800000
local QUERY_STATUS_CODE = 19
local QUERY_RAW_HEADERS_CRLF = 22
local QUERY_FLAG_NUMBER = 0x20000000
local OPTION_DECOMPRESSION = 118
local OPTION_SECURITY_FLAGS = 31
local DECOMPRESSION_FLAG_ALL = 3
local SECURITY_IGNORE_ALL = 0x3300       -- unknown CA | CN invalid | date invalid | wrong usage
local ERROR_TIMEOUT = 12002

local M = {}

local function wide(s)
    local n = C.MultiByteToWideChar(CP_UTF8, 0, s, #s, nil, 0)
    local buf = ffi.new("WCHAR[?]", n + 1)
    C.MultiByteToWideChar(CP_UTF8, 0, s, #s, buf, n)
    buf[n] = 0
    return buf
end

local function narrow(w, nchars)
    local n = C.WideCharToMultiByte(CP_UTF8, 0, w, nchars, nil, 0, nil, nil)
    local buf = ffi.new("char[?]", n)
    C.WideCharToMultiByte(CP_UTF8, 0, w, nchars, buf, n, nil, nil)
    return ffi.string(buf, n)
end

local session
local function get_session()
    if session then return session end
    local agent = wide("PlexLove/1.0")
    session = winhttp.WinHttpOpen(agent, ACCESS_TYPE_AUTOMATIC_PROXY, nil, nil, 0)
    if session == nil then
        session = winhttp.WinHttpOpen(agent, ACCESS_TYPE_DEFAULT_PROXY, nil, nil, 0)
    end
    assert(session ~= nil, "WinHttpOpen failed: " .. C.GetLastError())
    local flags = ffi.new("DWORD[1]", DECOMPRESSION_FLAG_ALL)
    winhttp.WinHttpSetOption(session, OPTION_DECOMPRESSION, flags, 4)
    return session
end

-- Split "https://host:port/path?q" into its parts. IPv6 hosts are bracketed.
function M.parse_url(url)
    local scheme, rest = url:match("^(%a[%w+.-]*)://(.*)$")
    if not scheme then return nil, "bad url: " .. url end
    scheme = scheme:lower()
    local hostport, path = rest:match("^([^/?#]*)(.*)$")
    if path == "" then path = "/" end
    local host, port = hostport:match("^%[(.-)%]:?(%d*)$")
    if not host then host, port = hostport:match("^([^:]*):?(%d*)$") end
    port = tonumber(port) or (scheme == "https" and 443 or 80)
    return { scheme = scheme, host = host, port = port, path = path }
end

local function last_error(what)
    local code = C.GetLastError()
    if code == ERROR_TIMEOUT then return what .. ": timed out", code end
    return ("%s failed (WinHTTP error %d)"):format(what, code), code
end

-- req = { url, method="GET", headers={k=v}, body=string, timeout=seconds, insecure=bool }
-- Returns { status, headers=string, body=string } or nil, errorMessage.
function M.request(req)
    local u, perr = M.parse_url(req.url)
    if not u then return nil, perr end
    if u.scheme ~= "http" and u.scheme ~= "https" then return nil, "unsupported scheme " .. u.scheme end

    local s = get_session()
    local conn, h
    local function cleanup()
        if h ~= nil and h then winhttp.WinHttpCloseHandle(h) end
        if conn ~= nil and conn then winhttp.WinHttpCloseHandle(conn) end
    end

    conn = winhttp.WinHttpConnect(s, wide(u.host), u.port, 0)
    if conn == nil then local e = last_error("connect"); cleanup(); return nil, e end

    h = winhttp.WinHttpOpenRequest(conn, wide(req.method or "GET"), wide(u.path), nil, nil, nil,
                                   u.scheme == "https" and FLAG_SECURE or 0)
    if h == nil then local e = last_error("open request"); cleanup(); return nil, e end

    local ms = math.floor((req.timeout or 20) * 1000)
    winhttp.WinHttpSetTimeouts(h, ms, ms, ms, ms)
    if req.insecure and u.scheme == "https" then
        local flags = ffi.new("DWORD[1]", SECURITY_IGNORE_ALL)
        winhttp.WinHttpSetOption(h, OPTION_SECURITY_FLAGS, flags, 4)
    end

    local lines = {}
    for k, v in pairs(req.headers or {}) do lines[#lines + 1] = k .. ": " .. tostring(v) end
    local hdr = #lines > 0 and wide(table.concat(lines, "\r\n")) or nil

    local body = req.body
    local blen = body and #body or 0
    local bptr = body and ffi.cast("void*", body) or nil
    if winhttp.WinHttpSendRequest(h, hdr, hdr and 0xFFFFFFFF or 0, bptr, blen, blen, 0) == 0 then
        local e = last_error("send"); cleanup(); return nil, e
    end
    if winhttp.WinHttpReceiveResponse(h, nil) == 0 then
        local e = last_error("receive"); cleanup(); return nil, e
    end

    local status = ffi.new("DWORD[1]")
    local len = ffi.new("DWORD[1]", 4)
    winhttp.WinHttpQueryHeaders(h, QUERY_STATUS_CODE + QUERY_FLAG_NUMBER, nil, status, len, nil)

    local raw = ""
    len[0] = 0
    winhttp.WinHttpQueryHeaders(h, QUERY_RAW_HEADERS_CRLF, nil, nil, len, nil)
    if len[0] > 0 then
        local buf = ffi.new("WCHAR[?]", len[0] / 2 + 1)
        if winhttp.WinHttpQueryHeaders(h, QUERY_RAW_HEADERS_CRLF, nil, buf, len, nil) ~= 0 then
            raw = narrow(buf, len[0] / 2)
        end
    end

    local chunks, avail, got = {}, ffi.new("DWORD[1]"), ffi.new("DWORD[1]")
    local bufsize = 65536
    local buf = ffi.new("uint8_t[?]", bufsize)
    local total = 0
    while not (req.maxBytes and total >= req.maxBytes) do   -- maxBytes: stop early (endless streams)
        if winhttp.WinHttpQueryDataAvailable(h, avail) == 0 then
            local e = last_error("read"); cleanup(); return nil, e
        end
        if avail[0] == 0 then break end
        local want = math.min(avail[0], bufsize)
        if winhttp.WinHttpReadData(h, buf, want, got) == 0 then
            local e = last_error("read"); cleanup(); return nil, e
        end
        if got[0] == 0 then break end
        chunks[#chunks + 1] = ffi.string(buf, got[0])
        total = total + got[0]
    end

    cleanup()
    return { status = tonumber(status[0]), headers = raw, body = table.concat(chunks) }
end

return M
