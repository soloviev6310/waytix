#!/bin/bash

# Simple test script for Waytix VPN LuCI controller

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test configuration
TEST_DIR="/tmp/waytix_test"
LUCI_DIR="./luci-app-waytix/luasrc/"
CONTROLLER="${LUCI_DIR}controller/waytix.lua"

# Create test directory
mkdir -p "$TEST_DIR"

# Check if Lua is installed
if ! command -v lua5.1 &> /dev/null; then
    echo -e "${RED}Error: Lua 5.1 is required but not installed.${NC}"
    echo "Please install it with: sudo apt-get install lua5.1"
    exit 1
fi

# Check if controller exists
if [ ! -f "$CONTROLLER" ]; then
    echo -e "${RED}Error: Controller not found at $CONTROLLER${NC}"
    exit 1
fi

# Create a simple test Lua script to test the controller
cat > "${TEST_DIR}/test_controller.lua" << 'EOL'
-- Set up package path
package.path = package.path .. ';./luci-app-waytix/luasrc/?.lua;./luci-app-waytix/luasrc/controller/?.lua;./luci-app-waytix/luasrc/model/cbi/?.lua;'

-- Mock luci.http
local http = {}
http.prepare_content = function(content_type)
    _G.content_type = content_type
    return true
end
http.write = function(data)
    _G.response_data = data
    return true
end
http.close = function()
    return true
end

-- Mock luci.model.uci
local uci = {}
local cursor = {}

function cursor:get(path)
    if path == "waytix.@config[0].selected_server" then
        return "test-server"
    end
    return nil
end

function cursor:set(path, value)
    return true
end

function cursor:commit(section)
    return true
end

function uci.cursor()
    return cursor
end

-- Mock luci.sys
local sys = {}
function sys.exec(cmd)
    if cmd:match("pgrep") then
        return "12345"
    end
    return ""
end

-- Mock nixio
local nixio = {}
nixio.fs = {}
function nixio.fs.access(path)
    return true
end

-- Set up global environment
_G.luci = {
    http = http,
    model = {
        uci = uci
    },
    sys = sys
}

_G.nixio = nixio

-- Load the controller
local status, controller = pcall(require, "luci.controller.waytix")
if not status then
    print("Error loading controller: " .. tostring(controller))
    os.exit(1)
end

-- Test action_status
print("\n=== Testing action_status ===")
controller.action_status()
if _G.response_data then
    print("Status response:")
    print(_G.response_data)
else
    print("No response from action_status")
end

-- Test action_traffic
print("\n=== Testing action_traffic ===")
_G.response_data = nil
controller.action_traffic()
if _G.response_data then
    print("Traffic response:")
    print(_G.response_data)
else
    print("No response from action_traffic")
end

-- Test action_logs
print("\n=== Testing action_logs ===")
_G.response_data = nil
controller.action_logs()
if _G.response_data then
    print("Logs response (first 100 chars):")
    print(string.sub(_G.response_data, 1, 100) .. "...")
else
    print("No response from action_logs")
end
EOL

# Run the test
echo -e "${YELLOW}=== Starting LuCI Controller Tests ===${NC}"

# Set up environment variables for testing
export XRAY_CONFIG="${TEST_DIR}/xray.json"
export XRAY_LOG_DIR="${TEST_DIR}/logs"
export XRAY_PID_FILE="${TEST_DIR}/xray.pid"

# Create test files
mkdir -p "${TEST_DIR}/logs"
echo "Test log entry" > "${TEST_DIR}/logs/access.log"
echo "12345" > "${TEST_DIR}/xray.pid"

# Run the test script
lua5.1 "${TEST_DIR}/test_controller.lua"

# Clean up
rm -rf "$TEST_DIR"

echo -e "${GREEN}=== Tests completed ===${NC}"
