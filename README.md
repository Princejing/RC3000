# RC3000 / RW3000 OpenWrt 固件构建仓库

为 **H3C Magic RT3000 (RC3000)** 生成 OpenWrt 固件的专用仓库。

硬件配置来自 [硬件信息汇总.md](../硬件信息汇总.md)，移植模板取自 OpenWrt 25.12 的
`ipq5018-mr3000d-ci.dts`（FIT 配置名 `config@mp03.3-m1` 与本机一致）与
`ipq5018-gl-b3000.dts`（QCA8337 拓扑参考）。

---

## 仓库内容

| 文件 | 用途 |
|---|---|
| `ipq5018-rc3000.dts` | RC3000 设备树源，复制到 `target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/` |
| `ipq50xx.mk.fragment` | 设备定义，追加到 `target/linux/qualcommax/image/ipq50xx.mk` |
| `.github/workflows/build.yml` | GitHub Actions 云端编译 |
| `check-dts.sh` | 编译前的 DTS 自检脚本 |
| `patches-6.12/` | （可选）串口等内核补丁 |

---

## 快速开始（3 步）

### 1. 在 GitHub 上建仓库并推送

```bash
cd openwrt-patch
git init
git add -A
git commit -m "RC3000: initial device tree and build workflow"
git branch -M main
git remote add origin https://github.com/<你的用户名>/rc3000-openwrt.git
git push -u origin main
```

### 2. 触发编译

推送后，进入仓库页面：

**Actions → Build RC3000 OpenWrt firmware → Run workflow**

可选输入：

| 输入 | 默认 | 说明 |
|---|---|---|
| `openwrt_version` | `v25.12.5` | OpenWrt 版本 tag |

编译约 1.5–3 小时。完成后在 workflow 页面底部下载 artifact
`rc3000-openwrt-v25.12.5`，内含：

- `openwrt-25.12.5-qualcommax-ipq50xx-h3c_rc3000-initramfs-uImage.itb` ← **先刷这个**
- `openwrt-25.12.5-qualcommax-ipq50xx-h3c_rc3000-squashfs-factory.ubi`
- `openwrt-25.12.5-qualcommax-ipq50xx-h3c_rc3000-squashfs-sysupgrade.bin`
- `build.log`、`config.rc3000`

### 3. 刷机

见下方[刷机流程](#刷机流程)。

---

## 本 DTS 与 GL-B3000 的差异

以 MR3000D-CI 为骨架，按硬件信息汇总逐项改写：

| 项 | GL-B3000 / MR3000D-CI 原值 | 本 DTS | 依据 |
|---|---|---|---|
| WAN | 交换机 port（DSA 口） | `&dp1` 片内 GE PHY 独立口 | §3.1、§13.1 |
| LAN 口数 | 2–4 口 | 3 口（port2/3/4 → PHY 0/1/2） | §3.2 |
| 交换机 CPU 口 | port0 或 port6 | **port6** | §3.2 |
| 交换机 MDIO | 0x11 | 0x11（待现场确认） | §3.3 |
| 交换机复位 | GPIO 39 | GPIO 39 | §3.2 |
| 5G userpd | pd3 或 pd2 | **pd2** | §4、§13.7 |
| fw-memory-mode | 1 | **2** | §4 |
| 5G bdf-addr | `0x4d100000` | **`0x4d200000`** | §5 |
| MAC 来源 | ART nvmem | **无 nvmem** | §13.2 |
| GE PHY | 部分机型带 dac-preset | **不带** | §13.4 |
| 串口 | blsp1_uart1 GPIO28/29 | **blsp0_uart0 GPIO20/21** | §9、§13.6 |
| LED | gpio23/24 | **gpio46** | §8 |
| 按键 | gpio27 reset | **gpio38 WPS** | §8 |
| NAND ECC | MR3000D-CI 写 8 | **默认 4** | §2 |

---

## 刷机流程

### 阶段 0：U-Boot 里确认两个未确认项

上电狂敲回车进 `<H3C>` 提示符：

```
printenv machid
ipq5018 mdio read 1 17 0      # 十进制 17 = 0x11
ipq5018 mdio read 1 28 0      # 十进制 28 = 0x1c
```

哪个返回 `0x004933xx` 就是交换机 MDIO 地址。
**若是 0x1c**，编辑 `ipq5018-rc3000.dts`：

```
ethernet-switch@17  ->  ethernet-switch@28
reg = <17>          ->  reg = <28>
```

然后重新 push，再跑一次 workflow。

### 阶段 1：TFTP 刷 initramfs（不写 NAND，可反悔）

PC 网卡设 `192.168.10.19`，接 LAN 口，TFTP 服务器根目录放 itb 文件。

```
setenv serverip 192.168.10.19
tftpboot 0x84000000 openwrt-25.12.5-qualcommax-ipq50xx-h3c_rc3000-initramfs-uImage.itb
bootm 0x84000000
```

起来后验证（对应硬件信息汇总 §14 的未确认项）：

```bash
free -m                              # 3: 真实 MemTotal
dmesg | grep -i caldata              # 4: 5G caldata 位置
dmesg | grep -i qca8337              # 交换机是否绑定（MDIO 地址验证）
dmesg | grep -i ath11k               # 两块射频是否都起来
ip a                                 # eth0(WAN) + lan1/2/3
iwinfo                               # 2.4G + 5G
```

### 阶段 2：备份 ART 后写 NAND

```bash
# ART 在 0x780000 = mtd13，绝不能丢！
nanddump -f /tmp/art.bin /dev/mtd13
md5sum /tmp/art.bin

# 把 factory.ubi 传到设备 /tmp 后
sysupgrade -n /tmp/openwrt-25.12.5-qualcommax-ipq50xx-h3c_rc3000-squashfs-factory.ubi
```

---

## 本地预检（可选）

推送到 GitHub 前，先跑一次本地自检，能在花 3 小时编译前抓掉手误：

```bash
./check-dts.sh
```

有 dtc 的话做真正的语法编译：

```bash
brew install dtc        # macOS
./check-dts.sh /path/to/openwrt
```

---

## 已知限制

1. **串口在 initramfs 阶段可能不可用**：上游 `ipq5018.dtsi` 只有 `blsp1_uart1`，
   没有 `blsp0_uart0`。DTS 里的 `serial_0_pins` 已按 GPIO 20/21 定义，但需要额外的
   内核补丁才能让 `blsp0_uart0` 节点存在。这也是为什么必须先走 TFTP initramfs，
   **不要直接写 NAND**。
2. **5G board 文件借用 MR3000D-CI**：`ipq-wifi-cmcc_mr3000d-ci`。若 5G 校准异常，
   需用 `ath10k-bdencoder` 从本机 ART 生成专属 board 文件。
3. **交换机 MDIO 地址未最终确认**：0x11 vs 0x1c，见阶段 0。

---

## 参考资料

- [硬件信息汇总.md](../硬件信息汇总.md) — 本机全部硬件信息
- [OpenWrt最新固件-同配置机型对照.md](../OpenWrt最新固件-同配置机型对照.md) — 同配置机型分析
- OpenWrt 25.12.5 ipq50xx: https://downloads.openwrt.org/releases/25.12.5/targets/qualcommax/ipq50xx/