#!/bin/bash
#=============================================================
# 修复 luci-app-socat：LuCI 保存规则后不生效（状态列显示 X，必须重启设备才 ✓）
#-------------------------------------------------------------
# 根因（R68S / ImmortalWrt 25.12-SNAPSHOT r38263 实机验证）：
#   1) /etc/init.d/luci_socat 是普通 shell 脚本，未注册 procd，没有
#      config.change 触发器；唯一带触发器的是 /etc/init.d/socat（老的
#      SocatOptions 应用），它 reload 的是自己那个空实例集，与端口转发无关。
#   2) LuCI 侧 luasrc/model/cbi/socat/{config,index}.lua 在保存/删除后
#      没有任何 restart 调用，保存只做 uci commit。
#   3) stop_service() 把 kill -9 丢到后台后立刻 rm -rf，存在竞态；
#      reuseaddr 只能绕过 TIME_WAIT，抢不到仍被旧进程占用的监听端口
#      → bind: Address already in use → 新进程立即退出 → 仍显示 X。
#
# 三个修复：
#   a. ln -s -> ln -sf；stop_service 改为同步 kill + 等待端口释放
#   b. 保存/删除后触发 restart（新增 m.on_after_commit）
#   c. restart 延迟 3 秒执行 + 锁文件去重：若 LuCI 自身架在 socat 转发
#      端口之后（例如 26880->443），立即 restart 会把承载本次请求的连接
#      掐断，浏览器表现为「保存并应用」后 502 / 白屏（配置其实已生效）。
#      延迟后先让响应回写浏览器，再重启；带 /tmp 锁避免连点重复重启。
#
# 做法：用 files/ overlay 覆盖三个文件。构建时 overlay 在包安装之后落盘，
#   确定性最强、不受上游 patch fuzz / 版本漂移影响；全部设备线通用。
#
# 用法（CWD = 编译树根目录，需在 feeds 安装完成之后调用）：
#   bash scripts/common/patch-luci-app-socat.sh [overlay目录，默认 files]
#=============================================================

set -u

OVERLAY="${1:-files}"

echo "===== patch-luci-app-socat.sh：修复 socat 规则保存不生效 ====="

mkdir -p "$OVERLAY/etc/init.d" "$OVERLAY/usr/lib/lua/luci/model/cbi/socat" || {
    echo "❌ 无法创建 overlay 目录：$OVERLAY（CWD 应为编译树根目录）"
    exit 1
}

cat > "$OVERLAY/etc/init.d/luci_socat" <<'SOCAT_INIT_EOF'
#!/bin/sh /etc/rc.common
# Copyright (C) 2020 Lienol <lawlienol@gmail.com>

START=99

CONFIG=socat
CONFIG_PATH=/var/etc/$CONFIG

add_rule() {
	accept_port=$(cat /var/etc/$CONFIG.port | tr "\n" " ")
	if [ "$accept_port" ]; then
		uci -q delete firewall.socat
		uci set firewall.socat=rule
		uci set firewall.socat.name="socat"
		uci set firewall.socat.target="ACCEPT"
		uci set firewall.socat.src="wan"
		uci set firewall.socat.dest_port="$accept_port"
		uci set firewall.socat.enabled="1"
		uci commit firewall
		/etc/init.d/firewall reload >/dev/null 2>&1
	else
		del_rule
	fi
}

del_rule() {
	uci -q delete firewall.socat
	uci commit firewall
	/etc/init.d/firewall reload >/dev/null 2>&1
}

run_service() {
	config_get enable $1 enable
	[ "$enable" = "0" ] && return 0
	config_get remarks $1 remarks
	config_get protocol $1 protocol
	config_get family $1 family
	config_get proto $1 proto
	config_get listen_port $1 listen_port
	config_get reuseaddr $1 reuseaddr
	config_get dest_proto $1 dest_proto
	config_get dest_ip $1 dest_ip
	config_get dest_port $1 dest_port
	config_get firewall_accept $1 firewall_accept
	ln -sf /usr/bin/socat ${CONFIG_PATH}/$1
	
	if [ "$reuseaddr" == "1" ]; then
		reuseaddr=",reuseaddr"
	else
		reuseaddr=""
	fi
	
	if [ "$family" == "6" ]; then
		ipv6only_params=",ipv6-v6only"
	else
		ipv6only_params=""
	fi
	
	# 端口转发
	if [ "$protocol" == "port_forwards" ]; then
		listen=${proto}${family}
		[ "$family" == "" ] && listen=${proto}6
		${CONFIG_PATH}/$1 ${listen}-listen:${listen_port}${ipv6only_params}${reuseaddr},fork ${dest_proto}:${dest_ip}:${dest_port} >/dev/null 2>&1 &
	fi
	
	[ "$firewall_accept" == "1" ] && {
		echo $listen_port >> /var/etc/$CONFIG.port
	}
}

stop_service() {
	local pids i=0
	pids=$(busybox ps -w | grep "$CONFIG_PATH/" | grep -v "grep" | awk '{print $1}')
	[ -n "$pids" ] && kill -9 $pids 2>/dev/null
	# 等待进程真正退出、监听端口释放，避免 restart 时 bind: Address already in use
	while [ $i -lt 25 ] && busybox ps -w | grep "$CONFIG_PATH/" | grep -qv "grep"; do
		sleep 0.2 2>/dev/null || sleep 1
		i=$((i+1))
	done
	del_rule
	rm -rf $CONFIG_PATH /var/etc/$CONFIG.port
}

start() {
	enable=$(uci -q get $CONFIG.@global[0].enable)
	if [ "$enable" = "0" ];then
		stop_service
	else
		mkdir -p $CONFIG_PATH
		rm -f /var/etc/$CONFIG.port
		config_load $CONFIG
		config_foreach run_service "config"
		add_rule
	fi
}

stop() {
	stop_service
}

restart() {
	stop
	start
}
SOCAT_INIT_EOF
chmod 755 "$OVERLAY/etc/init.d/luci_socat"

cat > "$OVERLAY/usr/lib/lua/luci/model/cbi/socat/config.lua" <<'SOCAT_CFG_EOF'
local d = require "luci.dispatcher"

m = Map("socat", translate("Socat Config"))
m.redirect = d.build_url("admin", "network", "socat")

s = m:section(NamedSection, arg[1], "config", "")
s.addremove = false
s.dynamic = false

o = s:option(Flag, "enable", translate("Enable"))
o.default = "1"
o.rmempty = false

o = s:option(Value, "remarks", translate("Remarks"))
o.default = translate("Remarks")
o.rmempty = false

o = s:option(ListValue, "protocol", translate("Protocol"))
o:value("port_forwards", translate("Port Forwards"))

o = s:option(ListValue, "family", translate("Restrict to address family"))
o:value("", translate("IPv4 and IPv6"))
o:value("4", translate("IPv4 only"))
o:value("6", translate("IPv6 only"))
o:depends("protocol", "port_forwards")

o = s:option(ListValue, "proto", translate("Protocol"))
o:value("tcp", "TCP")
o:value("udp", "UDP")
o:depends("protocol", "port_forwards")

o = s:option(Value, "listen_port", translate("Listen port"))
o.datatype = "portrange"
o.rmempty = false
o:depends("protocol", "port_forwards")

o = s:option(Flag, "reuseaddr", translate("REUSEADDR"), translate("Bind to a port local"))
o.default = "1"
o.rmempty = false

o = s:option(ListValue, "dest_proto", translate("Destination Protocol"))
o:value("tcp4", "IPv4-TCP")
o:value("udp4", "IPv4-UDP")
o:value("tcp6", "IPv6-TCP")
o:value("udp6", "IPv6-UDP")
o:depends("protocol", "port_forwards")

dest_ipv4 = s:option(Value, "dest_ipv4", translate("Destination address"))
luci.sys.net.ipv4_hints(function(ip, name)
	dest_ipv4:value(ip, "%s (%s)" %{ ip, name })
end)
function dest_ipv4.cfgvalue(self, section)
	return m:get(section, "dest_ip")
end
function dest_ipv4.write(self, section, value)
	m:set(section, "dest_ip", value)
end
dest_ipv4:depends("dest_proto", "tcp4")
dest_ipv4:depends("dest_proto", "udp4")

dest_ipv6 = s:option(Value, "dest_ipv6", translate("Destination address"))
luci.sys.net.ipv6_hints(function(ip, name)
	dest_ipv6:value(ip, "%s (%s)" %{ ip, name })
end)
function dest_ipv6.cfgvalue(self, section)
	return m:get(section, "dest_ip")
end
function dest_ipv6.write(self, section, value)
	m:set(section, "dest_ip", value)
end
dest_ipv6:depends("dest_proto", "tcp6")
dest_ipv6:depends("dest_proto", "udp6")

o = s:option(Value, "dest_port", translate("Destination port"))
o.datatype = "portrange"
o.rmempty = false

o = s:option(Flag, "firewall_accept", translate("Open firewall port"))
o.default = "1"
o.rmempty = false

m.on_after_commit = function(self)
	luci.sys.call("setsid sh -c '[ -f /tmp/.socat_restart_pending ] && exit 0; touch /tmp/.socat_restart_pending; sleep 3; /etc/init.d/luci_socat restart; rm -f /tmp/.socat_restart_pending' >/dev/null 2>&1 &")
end

return m
SOCAT_CFG_EOF
chmod 644 "$OVERLAY/usr/lib/lua/luci/model/cbi/socat/config.lua"

cat > "$OVERLAY/usr/lib/lua/luci/model/cbi/socat/index.lua" <<'SOCAT_IDX_EOF'
local d = require "luci.dispatcher"
local e = luci.model.uci.cursor()

m = Map("socat")
m.title = translate("Socat")
m.description = translate("Socat is a relay for bidirectional data transfer between two independent data channels.")

s = m:section(NamedSection, "global", "global")
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enable", translate("Enable"))
o.rmempty = false

s = m:section(TypedSection, "config", translate("Port Forwards"))
s.anonymous = true
s.addremove = true
s.template = "cbi/tblsection"
s.extedit = d.build_url("admin", "network", "socat", "config", "%s")
function s.filter(e, t)
	if m:get(t, "protocol") == "port_forwards" then
		return true
	end
end
function s.create(e, t)
	local uuid = string.gsub(luci.sys.exec("echo -n $(cat /proc/sys/kernel/random/uuid)"), "-", "")
	t = uuid
	TypedSection.create(e, t)
	luci.http.redirect(e.extedit:format(t))
end
function s.remove(e, t)
	e.map.proceed = true
	e.map:del(t)
	luci.sys.call("setsid sh -c '[ -f /tmp/.socat_restart_pending ] && exit 0; touch /tmp/.socat_restart_pending; sleep 3; /etc/init.d/luci_socat restart; rm -f /tmp/.socat_restart_pending' >/dev/null 2>&1 &")
	luci.http.redirect(d.build_url("admin", "network", "socat"))
end

o = s:option(Flag, "enable", translate("Enable"))
o.width = "5%"
o.rmempty = false

o = s:option(DummyValue, "status", translate("Status"))
o.template = "socat/status"
o.value = translate("Collecting data...")

o = s:option(DummyValue, "remarks", translate("Remarks"))

o = s:option(DummyValue, "family", translate("Listen Protocol"))
o.cfgvalue = function(t, n)
	local listen = Value.cfgvalue(t, n) or ""
	local protocol = (m:get(n, "proto") or ""):upper()
	if listen == "" then
		return protocol
	else
		return "IPv" .. listen .. "-" .. protocol
	end
end

o = s:option(DummyValue, "listen_port", translate("Listen port"))

o = s:option(DummyValue, "dest_proto", translate("Destination Protocol"))
o.cfgvalue = function(t, n)
	local listen = Value.cfgvalue(t, n)
	local protocol = listen:sub(0, #listen - 1):upper()
	local ip_type = "IPv" .. listen:sub(#listen)
	return ip_type .. "-" .. protocol
end

o = s:option(DummyValue, "dest_ip", translate("Destination address"))

o = s:option(DummyValue, "dest_port", translate("Destination port"))

o = s:option(Flag, "firewall_accept", translate("Open firewall port"))
o.default = "1"
o.rmempty = false

m:append(Template("socat/list_status"))

m.on_after_commit = function(self)
	luci.sys.call("setsid sh -c '[ -f /tmp/.socat_restart_pending ] && exit 0; touch /tmp/.socat_restart_pending; sleep 3; /etc/init.d/luci_socat restart; rm -f /tmp/.socat_restart_pending' >/dev/null 2>&1 &")
end

return m
SOCAT_IDX_EOF
chmod 644 "$OVERLAY/usr/lib/lua/luci/model/cbi/socat/index.lua"


# ── 自检：任一失败即让编译失败，避免带着坏补丁出包 ──────────────
err=0

if sh -n "$OVERLAY/etc/init.d/luci_socat" 2>/dev/null; then
    echo "✅ init 脚本语法通过"
else
    echo "❌ init 脚本语法错误"; err=1
fi

for f in config.lua index.lua; do
    if grep -qF 'on_after_commit' "$OVERLAY/usr/lib/lua/luci/model/cbi/socat/$f"; then
        echo "✅ $f 已注入 on_after_commit"
    else
        echo "❌ $f 缺少 on_after_commit"; err=1
    fi
done

grep -qF 'ln -sf /usr/bin/socat'        "$OVERLAY/etc/init.d/luci_socat" && echo "✅ ln -sf 已修正"          || { echo "❌ ln -sf 未修正"; err=1; }
grep -qF '等待进程真正退出'             "$OVERLAY/etc/init.d/luci_socat" && echo "✅ stop 竞态已修复"        || { echo "❌ stop 竞态未修复"; err=1; }
grep -qF 'socat_restart_pending'        "$OVERLAY/etc/init.d/luci_socat" >/dev/null 2>&1 || true
grep -qF 'socat_restart_pending' "$OVERLAY/usr/lib/lua/luci/model/cbi/socat/config.lua" \
    && echo "✅ 延迟重载已启用（防 502）" || { echo "❌ 延迟重载未启用"; err=1; }

ls -l "$OVERLAY/etc/init.d/luci_socat" \
      "$OVERLAY/usr/lib/lua/luci/model/cbi/socat/"*.lua
echo "===== patch-luci-app-socat.sh 结束（错误数 $err）====="
exit $err
