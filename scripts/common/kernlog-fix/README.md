# 构建期补丁包 —— 内核/启动期 Error 日志修复

> 对应报告：`../修正与出厂固化报告-20261107.md`
> 适用固件：ImmortalWrt 25.12-SNAPSHOT（amlogic/meson8b，OneCloud）
> 覆盖条目：K1、K2、U1（可选）、U2、U3、U5/U6

---

## 一、用法

补丁包整体拷入源码树后，在 **diy-part2 阶段**（源码树根目录、`make defconfig` 之后）执行：

```sh
sh /path/to/build-patch/apply-all.sh
```

或在 `diy-part2.sh` 末尾追加：

```sh
sh "$GITHUB_WORKSPACE/scripts/common/kernlog-fix/apply-all.sh"
```

脚本特性：

| 特性 | 说明 |
|---|---|
| 幂等 | 每处写入前都有 grep 守卫，重复执行不会重复追加 |
| 容错 | 单项失败只打印 `[WARN]`，不中断构建（末行 `exit 0`） |
| 汇总 | 结束时输出「成功 N 项 / 告警 M 项」，并列出每个 WARN 行 |

---

## 二、文件清单

| 文件 | 对应条目 | 目标位置 |
|---|---|---|
| `02-kernel-patch-l2c310.patch` | K1 | `target/linux/amlogic/patches-6.12/999-l2c310-loglevel.patch` |
| `03-fstools-quiet-missing-fstab.patch` | U1（**默认不启用**） | `package/system/fstools/patches/100-quiet-missing-fstab.patch` |
| `05-79_move_config` | K2 | `package/base-files/files/lib/preinit/79_move_config` |
| `06-system` | U5/U6 | `recipe/onecloud/files/etc/config/system` |
| `06-dockerd` | U2 | `recipe/onecloud/files/etc/config/dockerd` |

U3（内核 config）不落文件，由 `apply-all.sh` 直接写入 `target/linux/amlogic/config-6.12` 与 `.config`。

---

## 三、逐项说明

### K1 内核：L2C-310 日志级别误标

`arch/arm/mm/cache-l2x0.c` 的 `l2c310_enable()` 在非 Cortex-A9 平台上关闭 A9 专属特性位，用的是 `pr_err`，级别为 3，于是每次开机 `dmesg -r | grep '^<[0-3]>'` 必有一条。OneCloud 是 Cortex-A5，这属**预期行为**，不是故障。

补丁只把该行 `pr_err` 改为 `pr_info`，不改任何控制流。

**验证**：新固件开机后 `dmesg -r | grep -c '^<[0-3]>'` 应少一条，且该行变为 `<6>`。

> patch 上下文取自 linux v6.12 `l2c310_enable()`。若某次构建报 patch 失败，说明上游该段被改动，按 `grep -n "disabling Cortex-A9 specific feature bits" arch/arm/mm/cache-l2x0.c` 重新生成即可。

### K2 preinit：79_move_config 写死 `mount -t ext4`

原脚本：

```sh
if mount -t ext4 -o ro,noatime "/dev/$partdev" /boot; then
```

本板 `mmcblk1p1` 是 **vfat**（`blkid`: `TYPE="vfat" UUID="6AE4-049A"`），ext4 挂载必失败 → 内核 `ext4_fill_super()` 打 `KERN_ERR "VFS: Can't find ext4 filesystem"`。

修复后按 `blkid` 实际类型挂载，无文件系统（如扩展分区壳）直接跳过，`blkid` 不可用时回退原 ext4 行为。

**已在实机验证**：替换该文件并重启后，该条内核 err 消失，且 `/boot` 首次被正确挂载为 vfat（16MiB，86% 使用）。

> 正向副作用：原脚本对本板从未成功挂载过 boot 分区，意味着 `sysupgrade.tgz` 配置恢复链实际是断的。修复后该功能恢复可用。

### U1 fstools：配置文件不存在也报 LOG_ERR（**默认不启用**）

`block.c` 的 `config_try_load()` 对「文件不存在」与「解析失败」用同一个 `ULOG_ERR`。系统按 overlay 两级 → `/etc/config` 顺序找 fstab，非 overlayfs 系统上前两级恒不存在，于是每次开机 2 条 `user.err ... (fstab: Entry not found)`。

补丁改为：文件存在才用 `ULOG_ERR`，不存在降为 `ULOG_DBG`（保留真正的解析失败告警）。

**为什么默认关闭**：该 patch 依赖 `block.c` 的具体上下文，fstools 版本变动会导致打不上，而 OpenWrt 构建期 patch 失败会**直接中断构建**。启用前请先验证：

```sh
cd build_dir/target-*/fstools-*/
patch -p1 --dry-run < /path/to/03-fstools-quiet-missing-fstab.patch
```

dry-run 通过后再：

```sh
ENABLE_FSTOOLS_PATCH=1 sh /path/to/build-patch/apply-all.sh
```

不启用时，这 2 条请纳入出厂日志白名单 —— 它们是**所有非 overlayfs 的 OpenWrt 系统**的通用行为，与本板硬件无关。

### U2 dockerd：二进制自带 aufs 探测

实机已证伪「配置层可关」：

| 实验 | 结果 |
|---|---|
| `uci set dockerd.globals.storage_driver='overlay2'` + 重启 | `daemon.json` 已含 `"storage-driver":"overlay2"`，`docker info` 为 overlay2，**但 `modprobe aufs` 仍出现** |
| 停 dockerd 观察 | 不新增 |
| 启动 dockerd | 立刻新增 1 条 |
| 检查启动命令行 | 仅 `--config-file=/tmp/dockerd/daemon.json`，无 `--storage-driver` 硬编码 |

结论：探测来自 dockerd 进程内部，配置层无开关。

补丁给 dockerd 包注入官方 build tag：

```makefile
BUILDTAGS:= exclude_graphdriver_aufs
```

`exclude_graphdriver_aufs` 是 moby 官方 tag，会把 `daemon/graphdriver/register/register_aufs.go` 排除出编译，aufs driver 不再注册，`modprobe aufs` 调用点随之消失。

**验证**：新固件上 `strings /usr/bin/dockerd | grep -c 'module named aufs'` 或直接重启 dockerd 观察日志。

> 若该 tag 在设备所用的 docker 25.0.6 上未生效（版本差异），退路是白名单 + 保留 `storage_driver=overlay2`。运行态已锁定 overlay2，功能无影响。

### U3 内核 config：CONFIG_MEMCG_SWAP

实机：`/proc/config.gz` 中 `CONFIG_MEMCG=y`、`CONFIG_MEMCG_V1 is not set`，但**无 `CONFIG_MEMCG_SWAP`**；cgroup2 已挂载但 `/sys/fs/cgroup/memory.swap.max` 不存在 → dockerd 报 `WARNING: No swap limit support`，容器 `-m/--memory-swap` 的 swap 部分失效。

`apply-all.sh` 向 `target/linux/amlogic/config-6.12`（含 subtarget 变体）写入：

```
CONFIG_MEMCG_SWAP=y
CONFIG_MEMCG_SWAP_ENABLED=y
```

**验证**：新固件 `zcat /proc/config.gz | grep MEMCG_SWAP` 应有 `=y`，且 `/sys/fs/cgroup/memory.swap.max` 存在，`docker info` 不再出现该警告。

> 这条只能在编译期解决，出厂后用户无法修复，建议在 CI 里加断言：
> `zcat /proc/config.gz | grep -q '^CONFIG_MEMCG_SWAP=y' || exit 1`

### U5/U6 cron 日志

实机量化（同一台设备，插入 `* * * * * /bin/true` 后观测 75 秒）：

| `cronloglevel` | 75 秒新增 `cron.err` | 内容 |
|---|---|---|
| 0 | 12+ | `wakeup dt` / `file root:` / `line ...` / `job:` / `child running` / `USER root pid` |
| 5 | 12 | 同上（少 wakeup） |
| **8** | **1** | 仅 `USER root pid N cmd ...` |

即 busybox 1.37 的 `-l` 数值越大越精简，与 syslog 级别直觉相反。出厂配方固定为 8。

**注意**：该开关无法归零 —— busybox crond 对全部消息统一用 `LOG_ERR` 输出，任何档位都落在 `cron.err`。要彻底消除需改 `busybox/crond.c` 的 syslog 优先级（把 `LOG_ERR` 改为 `LOG_NOTICE`/`LOG_DEBUG`），属核心包改动，本包**不提供**，建议纳入白名单。

---

## 四、构建后验收脚本

```sh
#!/bin/sh
# 在新固件上执行，逐项核对
echo "== K1 ==";  dmesg -r | grep -c 'disabling Cortex-A9'        # 期望 0（且该行变 <6>）
echo "== K2 ==";  dmesg -r | grep '^<[0-3]>'                       # 期望不含 mmcblk1p1
echo "== U2 ==";  strings /usr/bin/dockerd | grep -c 'module named aufs'   # 期望 0
echo "== U3 ==";  zcat /proc/config.gz | grep MEMCG_SWAP           # 期望两条 =y
echo "== U3b =="; ls /sys/fs/cgroup/memory.swap.max                # 期望存在
echo "== U5 ==";  uci get system.@system[0].cronloglevel            # 期望 8
echo "== 总计 =="; dmesg -r | grep -c '^<[0-3]>'                    # 期望仅剩 sdb1（K3，未处理）
```

---

## 五、回滚

| 层级 | 回滚方式 |
|---|---|
| 构建期 | 不执行 `apply-all.sh` 即可；已执行的删除对应 patch 文件与 `recipe` 覆盖文件 |
| 运行态（已改设备） | `backup/` 目录存有原始 `/etc/config/{system,fstab,dockerd}`、`/etc/init.d/loghygiene`、`/lib/preinit/79_move_config` |
| 单条回滚 | `cp backup/lib_preinit_79_move_config.orig /lib/preinit/79_move_config` 后重启 |
