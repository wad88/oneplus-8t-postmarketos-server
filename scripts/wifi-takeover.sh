#!/bin/sh
# 方案A: 旧binding下qca6390枚举为17cb:0306被mhi_pci_generic抢占,夺回给ath11k_pci
# 在系统启动后跑(rootfs带qca639x旧binding+pcie0 okay)
set -x
LOG=/tmp/wifi-takeover.log
exec >"$LOG" 2>&1

# 1. install方式真正挡住mhi_pci_generic(blacklist挡不住依赖触发)
cat > /etc/modprobe.d/mhi-block.conf <<EOF
install mhi_pci_generic /bin/true
EOF
# 已加载则卸载
rmmod mhi_pci_generic 2>/dev/null

# 2. 确保ath11k模块在
modprobe -a mhi qrtr qrtr-mhi ath11k ath11k_pci 2>/dev/null

# 3. 找qca6390 PCI设备(17cb:0306)
BDF=$(lspci -D 2>/dev/null | grep -i "17cb:0306\|17cb:1101\|Qualcomm.*QCA\|Qualcomm.*Network" | head -1 | cut -d' ' -f1)
[ -z "$BDF" ] && BDF=$(for d in /sys/bus/pci/devices/*/; do v=$(cat "$d/vendor" 2>/dev/null); [ "$v" = "0x17cb" ] && basename "$d" && break; done)
echo "qca6390 BDF: $BDF"

if [ -n "$BDF" ]; then
  # 4. 从mhi-pci-generic解绑(若被抢)
  echo "$BDF" > /sys/bus/pci/drivers/mhi-pci-generic/unbind 2>/dev/null
  sleep 1
  # 5. ath11k_pci 若不认0306, 加new_id (17cb 0306)
  echo "17cb 0306" > /sys/bus/pci/drivers/ath11k_pci/new_id 2>/dev/null
  sleep 1
  # 6. 显式bind
  echo "$BDF" > /sys/bus/pci/drivers/ath11k_pci/bind 2>/dev/null
  sleep 3
fi

# 7. 看结果
echo "=== dmesg ath11k ==="
dmesg | grep -iE "ath11k|qca6390" | tail -15
echo "=== wlan? ==="
ip -br link | grep -iE "wlan|wlp"
