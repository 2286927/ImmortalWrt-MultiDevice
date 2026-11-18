'use strict';
'require baseclass';
'require fs';
'require rpc';
'require uci';

var callGetUnixtime = rpc.declare({
	object: 'luci',
	method: 'getUnixtime',
	expect: { result: 0 }
});

var callLuciVersion = rpc.declare({
	object: 'luci',
	method: 'getVersion'
});

var callSystemBoard = rpc.declare({
	object: 'system',
	method: 'board'
});

var callSystemInfo = rpc.declare({
	object: 'system',
	method: 'info'
});

var callCPUBench = rpc.declare({
	object: 'luci',
	method: 'getCPUBench'
});

var callCPUInfo = rpc.declare({
	object: 'luci',
	method: 'getCPUInfo'
});

var callCPUUsage = rpc.declare({
	object: 'luci',
	method: 'getCPUUsage'
});

var callTempInfo = rpc.declare({
	object: 'luci',
	method: 'getTempInfo'
});

return baseclass.extend({
	title: _('System'),

	load: function() {
		return Promise.all([
			L.resolveDefault(callSystemBoard(), {}),
			L.resolveDefault(callSystemInfo(), {}),
			L.resolveDefault(callCPUBench(), {}),
			L.resolveDefault(callCPUInfo(), {}),
			L.resolveDefault(callCPUUsage(), {}),
			L.resolveDefault(callTempInfo(), {}),
			L.resolveDefault(callLuciVersion(), { revision: _('unknown version'), branch: 'LuCI' }),
			L.resolveDefault(callGetUnixtime(), 0),
			uci.load('system')
		]);
	},

	render: function(data) {
		var boardinfo   = data[0],
		    systeminfo  = data[1],
		    cpubench    = data[2],
		    cpuinfo     = data[3],
		    cpuusage    = data[4],
		    tempinfo    = data[5],
		    luciversion = data[6],
		    unixtime    = data[7];

		luciversion = luciversion.branch + ' ' + luciversion.revision;

		var datestr = null;

		if (unixtime) {
			var date = new Date(unixtime * 1000),
				zn = uci.get('system', '@system[0]', 'zonename')?.replaceAll(' ', '_') || 'UTC',
				ts = uci.get('system', '@system[0]', 'clock_timestyle') || 0,
				hc = uci.get('system', '@system[0]', 'clock_hourcycle') || 0;

			datestr = new Intl.DateTimeFormat(undefined, {
				dateStyle: 'medium',
				timeStyle: (ts == 0) ? 'long' : 'full',
				hourCycle: (hc == 0) ? undefined : hc,
				timeZone: zn
			}).format(date);
		}

		/* r47: 构建日期改为【运行时】读取 —— 原实现由 yml 把日期 sed 进本文件，但镜像打包会把
		 * 全部文件时间戳统一成 SOURCE_DATE_EPOCH（上游提交时间）。同一上游反复构建时本文件
		 * size/mtime 完全不变 → uhttpd 的 ETag（inode-size-mtime）不变 → 浏览器带 If-None-Match
		 * 拿到 304，继续用旧副本，页面构建日期永久停在第一次缓存的那一版
		 * （实机实锤：11-17 固件仍显示 11-11 16:48）。
		 * 现改为编译期写入 UCI（system.@system[0].oc_build_date），本文件内容跨构建恒定，
		 * 浏览器缓存再怎么命中，显示的也是当前固件真实构建时间。 */
		var builddate = uci.get('system', '@system[0]', 'oc_build_date');

		if (!builddate && L.isObject(boardinfo.release)) {
			var bmatch = /AI洲长\(([0-9]{4}\.[0-9]{2}\.[0-9]{2})\)/.exec(boardinfo.release.description || '');

			if (bmatch)
				builddate = bmatch[1];
		}

		if (!builddate)
			builddate = _('unknown');

		var fields = [
			_('Hostname'),         boardinfo.hostname,
			_('Model'),            boardinfo.model + cpubench.cpubench,
			_('Architecture'),     cpuinfo.cpuinfo || boardinfo.system,
			_('Target Platform'),  (L.isObject(boardinfo.release) ? boardinfo.release.target : ''),
			_('Firmware Version'), (L.isObject(boardinfo.release) ? boardinfo.release.description + ' / ' : '') + (luciversion || ''),
			'定制',                E('a', { 'href': 'https://xhslink.cn/o/2GJiuLpYLGE', 'target': '_blank', 'style': 'text-decoration:underline' }, 'AI洲长'),
			'构建日期',            builddate,
			// '编译地址',            E('a', { 'href': 'https://github.com/2286927/ImmortalWrt-MultiDevice', 'target': '_blank', 'style': 'text-decoration:underline' }, 'ImmortalWrt-MultiDevice'),
			'升级通道',            E('span', {}, [ '在线脚本', E('span', { 'style': 'color:#888' }, '　终端预检: upgrade --check　升级: upgrade --reboot') ] ),
			_('Kernel Version'),   boardinfo.kernel,
			_('Local Time'),       datestr,
			_('Uptime'),           systeminfo.uptime ? '%t'.format(systeminfo.uptime) : null,
			_('Load Average'),     Array.isArray(systeminfo.load) ? '%.2f, %.2f, %.2f'.format(
				systeminfo.load[0] / 65535.0,
				systeminfo.load[1] / 65535.0,
				systeminfo.load[2] / 65535.0
			) : null,
			_('CPU usage (%)'),    cpuusage.cpuusage
		];

		if (tempinfo.tempinfo) {
			fields.splice(6, 0, _('Temperature'));
			fields.splice(7, 0, tempinfo.tempinfo);
		}

		var table = E('table', { 'class': 'table' });

		for (var i = 0; i < fields.length; i += 2) {
			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, [ fields[i] ]),
				E('td', { 'class': 'td left' }, [ (fields[i + 1] != null) ? fields[i + 1] : '?' ])
			]));
		}

		return table;
	}
});
