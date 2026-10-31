# tools/onecloud — 直刷包外部依赖（已固化入库）

本目录存放 `scripts/onecloud/convert3.sh` 制作 AmlImg 直刷包所需的两个外部二进制。
构建流程**不再联网下载**，完全离线自足：上游仓库删库、改 release 都不再影响编译。

## AmlImg

| 项 | 值 |
|---|---|
| 版本 | `v0.3.2`（固定 tag，不使用 latest） |
| 文件 | `AmlImg`（Linux x86_64 静态编译 ELF，Go，stripped） |
| 来源 | https://github.com/rmoyulong/AmlImg/releases/download/v0.3.2/AmlImg_v0.3.2_linux_amd64 |
| 大小 | 1613824 字节 |
| sha256 | `f91106e9f20d56e4eb83d8be4a7b063e46cbb4c6a151884a4bb74f33c0b2c6e7` |
| 权限 | 需可执行（仓库内已置 0755） |

## uboot.img

| 项 | 值 |
|---|---|
| 版本/标签 | `Onecloud_Uboot_23.12.24_18.15.09`（固定 tag，不使用 latest） |
| 文件 | `uboot.img`（AmlImg 可解包的 eMMC burn 镜像） |
| 来源 | https://github.com/rmoyulong/u-boot-onecloud/releases/download/Onecloud_Uboot_23.12.24_18.15.09/eMMC.burn.img |
| 大小 | 1367548 字节 |
| sha256 | `b4d6fb1abd5b0f1916bf0bab4c1dce933f24c620d2a2d672d4d4f0e95ab02eb4` |

## 校验

```bash
cd tools/onecloud && sha256sum -c SHA256SUMS
```

## 入库方式

**直接提交，不使用 Git LFS。** 理由：两文件合计约 2.9 MB，远低于 LFS 建议阈值；
构建 runner 需要直接读取可执行文件，直接提交可避免 LFS 指针未拉取导致 `AmlImg: cannot execute` 一类故障。

## 更新方式

上游发布新版本时：手工下载新文件覆盖本目录 → 同步更新本文件与 `SHA256SUMS` 中的版本号与校验值 → 提交。
**不要**改回在脚本里 curl 下载。
