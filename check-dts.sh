#!/usr/bin/env bash
# =============================================================================
# check-dts.sh - 在完整编译前预检 ipq5018-rc3000.dts 的语法与关键属性
#
# 用法:
#   ./check-dts.sh /path/to/openwrt-checkout
#
# 作用:
#   1. 括号/引号配平检查（纯 Python，无需 dtc）
#   2. 关键属性核对（依据硬件信息汇总.md）
#   3. 若系统有 dtc，则做真正的 cpp + dtc 语法编译
# =============================================================================
set -u

DTS_FILE="$(dirname "$0")/ipq5018-rc3000.dts"
OWRT="${1:-}"

echo "=== 1. 检查 DTS 文件 ==="
if [ ! -f "$DTS_FILE" ]; then
    echo "FAIL: 找不到 $DTS_FILE"
    exit 1
fi
echo "OK: $DTS_FILE ($(wc -l < "$DTS_FILE") 行)"

echo
echo "=== 2. 括号/引号配平 ==="
python3 - "$DTS_FILE" <<'PY'
import sys, re
src = open(sys.argv[1], encoding='utf-8').read()
src = re.sub(r'/\*.*?\*/', ' ', src, flags=re.S)
src = re.sub(r'//[^\n]*', ' ', src)
ok = True
pairs = (('{', '}', '花括号'), ('(', ')', '圆括号'), ('[', ']', '方括号'))
for ch, close, name in pairs:
    n = src.count(ch)
    m = src.count(close)
    flag = 'OK ' if n == m else 'FAIL'
    print('  ' + flag + ' ' + name + ': 开 ' + str(n) + ' / 闭 ' + str(m))
    ok = ok and n == m
q = src.count('"')
print('  ' + ('OK ' if q % 2 == 0 else 'FAIL') + ' 双引号: ' + str(q))
ok = ok and q % 2 == 0
sys.exit(0 if ok else 1)
PY
if [ $? -ne 0 ]; then echo "FAIL: 括号/引号不配平"; exit 1; fi

echo
echo "=== 3. 关键属性核对（依据硬件信息汇总.md）==="

check() {
    desc="$1"
    pattern="$2"
    want="$3"
    got=$(grep -c "$pattern" "$DTS_FILE" 2>/dev/null || true)
    got=${got:-0}
    if [ "$got" -gt 0 ]; then
        echo "  OK    $desc"
    else
        if [ "$want" = "absent" ]; then
            echo "  OK    $desc (正确地未出现)"
        else
            echo "  FAIL  $desc"
        fi
    fi
}

echo '--- 必须存在的项 ---'
check '交换机 MDIO 0x11 (ethernet-switch@17)'      'ethernet-switch@17'             present
check '交换机 compatible qca,qca8337'              'compatible = "qca,qca8337"'      present
check '交换机复位 GPIO 39 低有效'                   'reset-gpios = <&tlmm 39'          present
check 'CPU 口 = port6'                              'switch0cpu: port@6'              present
check '面板口 lan1/lan2/lan3'                       'label = "lan[123]"'              present
check 'GE PHY 在 mdio0 地址 7'                      'phy_address = <7>'               present
check 'WAN 独立口 dp1'                              '&dp1'                            present
check 'LAN SGMII dp2'                               '&dp2'                            present
check '2.4G user PD 1'                              'q6_wcss_pd1'                     present
check '5G user PD 2'                                'q6_wcss_pd2'                     present
check 'fw-memory-mode = 2'                          'ath11k-fw-memory-mode = <2>'     present
check 'q6v5_wcss boot-args'                         'q6v5_wcss'                       present
check 'NAND 8-bit 位宽'                             'nand-bus-width = <8>'            present
check 'WPS 键 GPIO 38'                              'tlmm 38 GPIO_ACTIVE_LOW'         present
check '状态 LED GPIO 46'                            'tlmm 46 GPIO_ACTIVE_HIGH'        present
check '串口 pin GPIO 20/21'                         'pins = "gpio20", "gpio21"'      present
check '串口 function blsp0_uart0'                   'function = "blsp0_uart0"'       present

echo '--- 必须不存在的项 ---'
check '不得有 nvmem-cells (ART 无 MAC)'             'nvmem-cells'                     absent
check '不得有 nvmem-layout'                         'nvmem-layout'                    absent
check '不得有 dac-preset-short-cable'               'dac-preset-short-cable'          absent
check '不得引用 BOOT_SCRIPT'                        'BOOT_SCRIPT'                     absent
check '不得引用 gl-qsdk-factory'                    'gl-qsdk-factory'                 absent
check '不得有 GPY/GPY115 等外部 PHY'                'ethernet-phy-id'                 absent

echo
echo "=== 4. dtc 语法编译（若有 dtc 且提供了 OpenWrt 路径）==="
if command -v dtc >/dev/null 2>&1 && [ -n "$OWRT" ] && [ -d "$OWRT" ]; then
    KDIR="$OWRT/build_dir/target-aarch64_cortex-a53_musl/linux-qualcommax_ipq50xx"
    INC=""
    for d in \
        "$OWRT/target/linux/qualcommax/files/arch/arm64/boot/dts" \
        "$OWRT/target/linux/qualcommax/files/arch/arm64/boot/dts/qcom" \
        "$OWRT/target/linux/qualcommax/dts" \
        "$KDIR/linux-*/arch/arm64/boot/dts" \
        "$KDIR/linux-*/arch/arm64/boot/dts/qcom" \
        "$KDIR/linux-*/include" \
        "$KDIR/linux-*/scripts/dtc/include"; do
        for real in $d; do
            [ -d "$real" ] && INC="$INC -I $real"
        done
    done
    echo "  include 路径: $INC"
    echo '  cpp + dtc 运行中...'
    if cpp -nostdinc -undef -D__DTS__ -x c $INC "$DTS_FILE" 2>/tmp/cpp.err \
         | dtc -I dts -O dtb -o /dev/null 2>/tmp/dtc.err; then
        echo '  OK: DTS 语法编译通过'
    else
        echo '  FAIL: 编译错误'
        echo '  --- cpp 错误 ---'; head -20 /tmp/cpp.err
        echo '  --- dtc 错误 ---'; head -40 /tmp/dtc.err
        exit 1
    fi
else
    if command -v dtc >/dev/null 2>&1; then
        echo '  SKIP: 未提供 OpenWrt 路径，无法定位 include'
    else
        echo '  SKIP: 系统没有 dtc（brew install dtc）'
    fi
    echo '        已退化为上面的文本检查'
fi

echo
echo "=== 预检完成 ==="
exit 0
