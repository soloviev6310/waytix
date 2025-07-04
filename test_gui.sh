#!/bin/sh

# Test script for Waytix VPN LuCI interface
# This script tests the backend functionality of the LuCI controller

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
UCI_CONFIG="waytix"
XRAY_CONFIG="/etc/xray/config.json"
LOG_FILE="/var/log/waytix.log"
SCRIPTS_DIR="/etc/waytix/"

# Mock functions for testing outside of OpenWrt
if [ ! -f "/etc/openwrt_release" ]; then
    echo -e "${YELLOW}Running in test mode (not on OpenWrt)${NC}"
    
    # Mock UCI functions
    uci() {
        if [ "$1" = "get" ]; then
            case "$2" in
                "$UCI_CONFIG.@config[0].selected_server")
                    echo "server1"
                    ;;
                *)
                    echo ""
                    ;;
            esac
        elif [ "$1" = "set" ]; then
            echo "[MOCK] uci set $2=$3"
        elif [ "$1" = "commit" ]; then
            echo "[MOCK] uci commit $2"
        elif [ "$1" = "add_list" ]; then
            echo "[MOCK] uci add_list $2=$3"
        elif [ "$1" = "delete" ]; then
            echo "[MOCK] uci delete $2"
        fi
    }
    
    # Mock Xray service
    xray() {
        echo "[MOCK] xray $@"
    }
    
    # Mock iptables
    iptables() {
        if [ "$1" = "-nvx" ] && [ "$2" = "-L" ]; then
            # Return some mock traffic data
            echo "Chain XRAY_IN (1 references)";
            echo "    pkts      bytes target     prot opt in     out     source               destination";
            echo "  123456  123456789            all  --  *      *       0.0.0.0/0            0.0.0.0/0";
            echo "";
            echo "Chain XRAY_OUT (1 references)";
            echo "    pkts      bytes target     prot opt in     out     source               destination";
            echo "   98765   98765432            all  --  *      *       0.0.0.0/0            0.0.0.0/0";
        else
            echo "[MOCK] iptables $@"
        fi
    }
    
    # Mock other commands
    pgrep() {
        if [ "$1" = "-f" ] && [ "$2" = "xray run" ]; then
            echo "12345"  # Mock Xray PID
        fi
    }
    
    # Create a test environment
    mkdir -p /tmp/waytix_test/var/run
    mkdir -p /tmp/waytix_test/var/log/xray
    touch /tmp/waytix_test/var/run/xray.pid
    echo "12345" > /tmp/waytix_test/var/run/xray.pid
    
    # Create a test log file
    cat > /tmp/waytix_test/var/log/xray/access.log <<EOL
2023/01/01 12:00:00 [Info] Xray 1.5.5 started
2023/01/01 12:00:01 [Info] [123456] inbound/*inbound-1 accepted a new TCP connection
2023/01/01 12:00:01 [Info] [123456] inbound/*inbound-1 terminated connection to proxy
EOL
    
    # Update paths for test environment
    XRAY_CONFIG="/tmp/waytix_test${XRAY_CONFIG}"
    LOG_FILE="/tmp/waytix_test${LOG_FILE}"
    SCRIPTS_DIR="/tmp/waytix_test${SCRIPTS_DIR}"
    mkdir -p "$(dirname "$XRAY_CONFIG")"
    mkdir -p "$(dirname "$LOG_FILE")"
    mkdir -p "$SCRIPTS_DIR"
    
    # Create test scripts
    cat > "${SCRIPTS_DIR}connect.sh" <<'EOL'
#!/bin/sh
# Mock connect script
echo "[MOCK] connect.sh $@"
if [ "$1" = "start" ]; then
    echo "Xray started successfully"
    exit 0
elif [ "$1" = "stop" ]; then
    echo "Xray stopped successfully"
    exit 0
else
    echo "Usage: $0 {start|stop}"
    exit 1
fi
EOL
    chmod +x "${SCRIPTS_DIR}connect.sh"
    
    cat > "${SCRIPTS_DIR}update.sh" <<'EOL'
#!/bin/sh
# Mock update script
echo "[MOCK] update.sh $@"
echo "Servers updated successfully"
exit 0
EOL
    chmod +x "${SCRIPTS_DIR}update.sh"
fi

# Test functions
test_status() {
    echo -e "\n${YELLOW}=== Testing status endpoint ===${NC}"
    local result=$(lua5.1 -e "
        package.path = package.path .. ';./luci-app-waytix/luasrc/?.lua;./luci-app-waytix/luasrc/controller/?.lua;./luci-app-waytix/luasrc/model/cbi/?.lua;'
        local c = require 'luci.controller.waytix'
        local uci = require 'luci.model.uci'.cursor()
        
        -- Mock http response
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
        
        -- Run the status action
        c.action_status()
        
        -- Print the result
        print(_G.response_data)
    " 2>&1)
    
    echo "Status response:"
    echo "$result" | jq .
    
    # Check if the response exists and is not empty, and doesn't contain error
    if [ -n "$result" ] && ! echo "$result" | grep -q "Error"; then
        echo -e "${GREEN}✓ Status test passed${NC}"
        return 0
    else
        echo -e "${RED}✗ Status test failed${NC}"
        return 1
    fi
}

test_traffic() {
    echo -e "\n${YELLOW}=== Testing traffic endpoint ===${NC}"
    local result=$(lua5.1 -e '
        -- Set up package path for Alpine Linux
        package.path = package.path .. ";/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;./luci-app-waytix/luasrc/?.lua;./luci-app-waytix/luasrc/controller/?.lua;./luci-app-waytix/luasrc/model/cbi/?.lua"
        package.cpath = package.cpath .. ";/usr/lib/lua/5.1/?.so"
        
        -- Mock luci modules
        _G.luci = {
            http = {},
            controller = {},
            model = {
                uci = {
                    cursor = function()
                        return {
                            get = function(self, path) return nil end
                        }
                    end
                }
            }
        }
        
        -- Mock http module
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
        
        -- Mock nixio module
        local nixio = {
            fs = {
                access = function(path)
                    return true
                end
            },
            sysconf = function()
                return 100
            end,
            CLK_TCK = 2
        }
        
        -- Mock os module
        local os = {
            execute = function(cmd)
                if cmd:match("iptables") then
                    return 0
                end
                return 0
            end
        }
        
        -- Load the controller
        local status, c = pcall(require, "luci.controller.waytix")
        if not status then
            print("Error loading controller: " .. tostring(c))
            return
        end
        
        -- Mock the controller environment
        setmetatable(_G, { __index = function(t, k)
            if k == "http" then return http end
            if k == "nixio" then return nixio end
            if k == "os" then return os end
            return rawget(t, k) or _G[k]
        end})
        
        -- Run the traffic action
        local status, result = pcall(c.action_traffic)
        if not status then
            print("Error in action_traffic: " .. tostring(result))
        end
        
        -- Print the result
        if _G.response_data then
            print(_G.response_data)
        end
    ' 2>&1)
    
    echo "Traffic response:"
    echo "$result" | jq .
    
    # Check if the response contains expected fields (simple check without jq)
    if echo "$result" | grep -q '"upload"' && 
       echo "$result" | grep -q '"download"' && 
       echo "$result" | grep -q '"total"' && 
       echo "$result" | grep -q '"uptime"'; then
        echo -e "${GREEN}✓ Traffic test passed${NC}"
        return 0
    else
        echo -e "${RED}✗ Traffic test failed${NC}"
        return 1
    fi
}

test_logs() {
    echo -e "\n${YELLOW}=== Testing logs endpoint ===${NC}"
    local result=$(lua5.1 -e '
        -- Set up package path for Alpine Linux
        package.path = package.path .. ";/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;./luci-app-waytix/luasrc/?.lua;./luci-app-waytix/luasrc/controller/?.lua;./luci-app-waytix/luasrc/model/cbi/?.lua"
        package.cpath = package.cpath .. ";/usr/lib/lua/5.1/?.so"
        
        -- Mock luci modules
        _G.luci = {
            http = {},
            controller = {},
            model = {
                uci = {
                    cursor = function()
                        return {
                            get = function(self, path) return nil end
                        }
                    end
                }
            }
        }
        
        -- Mock http module
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
        
        -- Mock nixio module
        local nixio = {
            fs = {
                access = function(path)
                    return true
                end
            }
        }
        
        -- Mock io module
        local io = {
            popen = function(cmd)
                return {
                    read = function() 
                        return "2023/01/01 12:00:00 [Info] Test log line\n" 
                    end,
                    close = function() end
                }
            end,
            open = function(path, mode)
                return {
                    read = function() 
                        return "2023/01/01 12:00:00 [Info] Test log line\n" 
                    end,
                    write = function() end,
                    close = function() end
                }
            end
        }
        
        -- Load the controller
        local status, c = pcall(require, "luci.controller.waytix")
        if not status then
            print("Error loading controller: " .. tostring(c))
            return
        end
        
        -- Mock the controller environment
        setmetatable(_G, { __index = function(t, k)
            if k == "http" then return http end
            if k == "nixio" then return nixio end
            if k == "io" then return io end
            return rawget(t, k) or _G[k]
        end})
        
        -- Run the logs action
        local status, result = pcall(c.action_logs)
        if not status then
            print("Error in action_logs: " .. tostring(result))
        end
        
        -- Print the result
        if _G.response_data then
            print(_G.response_data)
        end
    ' 2>&1)
    
    echo "Logs response (first 2 lines):"
    echo "$result" | head -n 2
    echo "..."
    
    # Check if we got some log data
    if [ -n "$result" ]; then
        echo -e "${GREEN}✓ Logs test passed${NC}"
        return 0
    else
        echo -e "${RED}✗ Logs test failed${NC}"
        return 1
    fi
}

# Run tests
passed=0
total=0

if [ "$1" = "--status" ] || [ -z "$1" ]; then
    test_status && passed=$((passed+1))
    total=$((total+1))
fi

if [ "$1" = "--traffic" ] || [ -z "$1" ]; then
    test_traffic && passed=$((passed+1))
    total=$((total+1))
fi

if [ "$1" = "--logs" ] || [ -z "$1" ]; then
    test_logs && passed=$((passed+1))
    total=$((total+1))
fi

# Print summary
echo -e "\n${YELLOW}=== Test Summary ===${NC}"
echo -e "${GREEN}Passed: $passed${NC} / ${YELLOW}Total: $total${NC}"

if [ $passed -eq $total ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi
