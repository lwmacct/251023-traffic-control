#!/usr/bin/env bash
# shellcheck disable=all

# v15 - 虚拟网卡共享限速方案
# 所有虚拟网卡共享统一的总带宽限制

__tc_qdisc_enable() {
  :
  # 处理限速参数（为空或0表示不限速）
  _tx_enabled=false
  _rx_enabled=false

  if [ -n "$RATE_TX" ] && [ "$RATE_TX" != "0" ] && [ "$RATE_TX" != "0mbit" ]; then
    _tx_enabled=true
  fi

  if [ -n "$RATE_RX" ] && [ "$RATE_RX" != "0" ] && [ "$RATE_RX" != "0mbit" ]; then
    _rx_enabled=true
  fi

  # 如果都不限速，则退出
  if [ "$_tx_enabled" = "false" ] && [ "$_rx_enabled" = "false" ]; then
    echo "错误: RATE_TX 和 RATE_RX 都未设置或为0，无需配置限速"
    echo "提示: export RATE_TX=\"50mbit\" RATE_RX=\"50mbit\""
    exit 1
  fi

  echo "========================================="
  echo "虚拟网卡共享限速（v15）"
  if [ "$_tx_enabled" = "true" ]; then
    echo "总上传限速: $RATE_TX (所有虚拟网卡共享)"
  else
    echo "总上传限速: 不限速"
  fi
  if [ "$_rx_enabled" = "true" ]; then
    echo "总下载限速: $RATE_RX (所有虚拟网卡共享)"
  else
    echo "总下载限速: 不限速"
  fi
  echo "========================================="

  # 获取所有有 IP 的虚拟网卡（排除 lo, docker, ifb）
  _all_ifaces=$(find /sys/class/net/ -type l -lname '*virtual*' -printf '%f\n' 2>/dev/null |
    grep -v -E '^(lo|docker|ifb|m-ifb)' |
    while read -r iface; do
      # 检查是否有 IPv4 地址
      if ip -4 addr show "$iface" 2>/dev/null | grep -q "inet "; then
        echo "$iface"
      fi
    done | sort)

  if [ -z "$_all_ifaces" ]; then
    echo "错误: 未找到任何有 IP 地址的虚拟网卡"
    exit 1
  fi

  echo "检测到的虚拟网卡（有IP）:"
  echo "$_all_ifaces" | while read -r iface; do
    _ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    _type=$(ip -d link show "$iface" 2>/dev/null | grep -oP '(macvlan|ipvlan|veth|vxlan)' | head -1 || echo "unknown")
    echo "  - $iface: $_ip (类型: $_type)"
  done
  echo ""

  # 清理所有虚拟网卡上的旧规则
  echo "清理旧规则..."
  echo "$_all_ifaces" | while read -r iface; do
    tc qdisc del dev "$iface" root 2>/dev/null
    tc qdisc del dev "$iface" ingress 2>/dev/null
  done

  # 清理旧的统一 IFB 设备
  ip link del m-ifb-tx-shared 2>/dev/null || true
  ip link del m-ifb-rx-shared 2>/dev/null || true
  echo ""

  # 加载 IFB 模块
  if ! lsmod | grep -q "^ifb"; then
    echo "加载 IFB 模块..."
    modprobe ifb numifbs=2 2>/dev/null || true
    sleep 1
  fi

  # 创建统一的 IFB 设备（所有虚拟网卡共享）
  echo "创建 IFB 设备..."
  _ifb_info=""

  # m-ifb-tx-shared: 所有虚拟网卡的上传流量汇总到这里
  if [ "$_tx_enabled" = "true" ]; then
    if ! ip link show m-ifb-tx-shared &>/dev/null; then
      ip link add m-ifb-tx-shared type ifb 2>/dev/null || true
    fi
    ip link set dev m-ifb-tx-shared up
    tc qdisc del dev m-ifb-tx-shared root 2>/dev/null || true
    _ifb_info="m-ifb-tx-shared(上传)"
  fi

  # m-ifb-rx-shared: 所有虚拟网卡的下载流量汇总到这里
  if [ "$_rx_enabled" = "true" ]; then
    if ! ip link show m-ifb-rx-shared &>/dev/null; then
      ip link add m-ifb-rx-shared type ifb 2>/dev/null || true
    fi
    ip link set dev m-ifb-rx-shared up
    tc qdisc del dev m-ifb-rx-shared root 2>/dev/null || true
    if [ -n "$_ifb_info" ]; then
      _ifb_info="$_ifb_info, m-ifb-rx-shared(下载)"
    else
      _ifb_info="m-ifb-rx-shared(下载)"
    fi
  fi

  echo "IFB 设备就绪: $_ifb_info"
  echo ""

  # 为所有虚拟网卡配置流量重定向
  echo "配置流量重定向..."
  echo "$_all_ifaces" | while read -r iface; do
    echo "处理网卡: $iface"

    _redirect_info=""

    # 1. 配置 egress 重定向到 m-ifb-tx-shared（上传流量）
    if [ "$_tx_enabled" = "true" ]; then
      tc qdisc add dev "$iface" root handle 1: prio
      tc filter add dev "$iface" parent 1: protocol ip prio 1 u32 \
        match u32 0 0 \
        action mirred egress redirect dev m-ifb-tx-shared
      _redirect_info="m-ifb-tx-shared(egress)"
    fi

    # 2. 配置 ingress 重定向到 m-ifb-rx-shared（下载流量）
    if [ "$_rx_enabled" = "true" ]; then
      tc qdisc add dev "$iface" handle ffff: ingress
      tc filter add dev "$iface" parent ffff: protocol ip prio 1 u32 \
        match u32 0 0 \
        action mirred egress redirect dev m-ifb-rx-shared
      if [ -n "$_redirect_info" ]; then
        _redirect_info="$_redirect_info + m-ifb-rx-shared(ingress)"
      else
        _redirect_info="m-ifb-rx-shared(ingress)"
      fi
    fi

    echo "  ✓ $iface -> $_redirect_info"
  done
  echo ""

  # 在统一的 IFB 上配置总带宽限速
  if [ "$_tx_enabled" = "true" ]; then
    echo "配置共享带宽限速 (m-ifb-tx-shared): $RATE_TX"
    tc qdisc add dev m-ifb-tx-shared root handle 1: htb default 10
    tc class add dev m-ifb-tx-shared parent 1: classid 1:1 htb rate "$RATE_TX" ceil "$RATE_TX"
    tc class add dev m-ifb-tx-shared parent 1:1 classid 1:10 htb rate "$RATE_TX" ceil "$RATE_TX"
    tc qdisc add dev m-ifb-tx-shared parent 1:10 handle 10: fq_codel
  fi

  if [ "$_rx_enabled" = "true" ]; then
    echo "配置共享带宽限速 (m-ifb-rx-shared): $RATE_RX"
    tc qdisc add dev m-ifb-rx-shared root handle 2: htb default 10
    tc class add dev m-ifb-rx-shared parent 2: classid 2:1 htb rate "$RATE_RX" ceil "$RATE_RX"
    tc class add dev m-ifb-rx-shared parent 2:1 classid 2:10 htb rate "$RATE_RX" ceil "$RATE_RX"
    tc qdisc add dev m-ifb-rx-shared parent 2:10 handle 20: fq_codel
  fi

  echo ""
  echo "========================================="
  echo "限速配置完成"
  echo "========================================="
  echo ""

  if [ "$_tx_enabled" = "true" ]; then
    echo "=== 共享上传限速状态 (m-ifb-tx-shared) ==="
    tc -s qdisc show dev m-ifb-tx-shared
    tc -s class show dev m-ifb-tx-shared
    echo ""
  fi

  if [ "$_rx_enabled" = "true" ]; then
    echo "=== 共享下载限速状态 (m-ifb-rx-shared) ==="
    tc -s qdisc show dev m-ifb-rx-shared
    tc -s class show dev m-ifb-rx-shared
    echo ""
  fi

  _count=$(echo "$_all_ifaces" | wc -l)
  echo "已为 $_count 个虚拟网卡配置共享限速"
  if [ "$_tx_enabled" = "true" ]; then
    echo "  上传: $RATE_TX (共享)"
  else
    echo "  上传: 不限速"
  fi
  if [ "$_rx_enabled" = "true" ]; then
    echo "  下载: $RATE_RX (共享)"
  else
    echo "  下载: 不限速"
  fi
  echo ""
}

__tc_qdisc_disable() {
  :
  echo "========================================="
  echo "禁用虚拟网卡共享限速"
  echo "========================================="

  # 获取所有有 IP 的虚拟网卡
  _all_ifaces=$(find /sys/class/net/ -type l -lname '*virtual*' -printf '%f\n' 2>/dev/null |
    grep -v -E '^(lo|docker|ifb|m-ifb)' |
    while read -r iface; do
      if ip -4 addr show "$iface" 2>/dev/null | grep -q "inet "; then
        echo "$iface"
      fi
    done | sort)

  # 清理所有虚拟网卡的规则
  if [ -n "$_all_ifaces" ]; then
    echo "清理虚拟网卡规则..."
    echo "$_all_ifaces" | while read -r iface; do
      tc qdisc del dev "$iface" root 2>/dev/null && echo "  ✓ $iface (root)" || true
      tc qdisc del dev "$iface" ingress 2>/dev/null && echo "  ✓ $iface (ingress)" || true
    done
  fi

  # 清理统一的 IFB 设备
  echo "清理共享 IFB 设备..."
  tc qdisc del dev m-ifb-tx-shared root 2>/dev/null && echo "  ✓ m-ifb-tx-shared" || true
  tc qdisc del dev m-ifb-rx-shared root 2>/dev/null && echo "  ✓ m-ifb-rx-shared" || true

  # 关闭 IFB 设备（但不删除，避免模块问题）
  ip link set dev m-ifb-tx-shared down 2>/dev/null || true
  ip link set dev m-ifb-rx-shared down 2>/dev/null || true

  echo ""
  echo "限速已禁用"
  echo ""
}

# 显示共享带宽统计
__tc_qdisc_status() {
  :
  echo "========================================="
  echo "共享带宽限速统计"
  echo "========================================="
  echo ""

  _has_config=false

  # 检查上传限速
  if ip link show m-ifb-tx-shared &>/dev/null 2>&1; then
    echo "=== 上传统计 (m-ifb-tx-shared) ==="
    tc -s class show dev m-ifb-tx-shared 2>/dev/null | grep -A 3 "class htb 1:10"
    echo ""
    _has_config=true
  fi

  # 检查下载限速
  if ip link show m-ifb-rx-shared &>/dev/null 2>&1; then
    echo "=== 下载统计 (m-ifb-rx-shared) ==="
    tc -s class show dev m-ifb-rx-shared 2>/dev/null | grep -A 3 "class htb 2:10"
    echo ""
    _has_config=true
  fi

  if [ "$_has_config" = "false" ]; then
    echo "未配置共享限速"
    echo "提示: export RATE_TX=\"50mbit\" RATE_RX=\"50mbit\" && __tc_qdisc_enable"
    return
  fi

  # 显示各虚拟网卡的流量（仅供参考）
  echo "=== 各虚拟网卡流量（汇总前） ==="
  _all_ifaces=$(find /sys/class/net/ -type l -lname '*virtual*' -printf '%f\n' 2>/dev/null |
    grep -v -E '^(lo|docker|ifb|m-ifb)' |
    while read -r iface; do
      if ip -4 addr show "$iface" 2>/dev/null | grep -q "inet "; then
        echo "$iface"
      fi
    done | sort)

  if [ -n "$_all_ifaces" ]; then
    echo "$_all_ifaces" | while read -r iface; do
      _ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
      _tx=$(cat /sys/class/net/"$iface"/statistics/tx_bytes 2>/dev/null || echo "0")
      _rx=$(cat /sys/class/net/"$iface"/statistics/rx_bytes 2>/dev/null || echo "0")
      _tx_mb=$(echo "scale=2; $_tx / 1024 / 1024" | bc)
      _rx_mb=$(echo "scale=2; $_rx / 1024 / 1024" | bc)
      echo "  $iface ($_ip): TX ${_tx_mb} MB, RX ${_rx_mb} MB"
    done
  fi
  echo ""
}

# 帮助信息
__help() {
  cat <<'EOF'
========================================
虚拟网卡共享限速方案 v15
========================================

适用场景：
  - 多个虚拟网卡需要共享总带宽限制
  - IP 配置在虚拟网卡上（m-ss-*, m-ms-* 等）
  - 需要控制所有虚拟网卡的总流量
  - 支持单向限速（只限上传或只限下载）

工作原理：
  1. 自动检测所有有 IP 地址的虚拟网卡
  2. 将所有虚拟网卡的上传流量重定向到 m-ifb-tx-shared
  3. 将所有虚拟网卡的下载流量重定向到 m-ifb-rx-shared
  4. 在统一的 IFB 设备上配置总带宽限速
  5. RATE_TX 或 RATE_RX 为空/0 时不限速该方向

核心特性：
  ✅ 所有虚拟网卡共享总带宽（非独立限速）
  ✅ 支持单向限速（只限上传或只限下载）
  ✅ 资源占用低（最多 2 个 IFB 设备）
  ✅ 灵活配置（RATE_TX=0 表示不限速）

使用方法：
----------------------------------------
# 启用限速（所有虚拟网卡共享）
export RATE_TX="50mbit"    # 上传限速（为空或0表示不限速）
export RATE_RX="50mbit"    # 下载限速（为空或0表示不限速）
source v15-virtual-nic-shared.sh
__tc_qdisc_enable

# 只限制上传，不限制下载
export RATE_TX="100mbit"
export RATE_RX="0"         # 或不设置 RATE_RX
__tc_qdisc_enable

# 只限制下载，不限制上传
export RATE_TX="0"         # 或不设置 RATE_TX
export RATE_RX="50mbit"
__tc_qdisc_enable

# 查看统计
__tc_qdisc_status

# 禁用限速
__tc_qdisc_disable

查看状态：
----------------------------------------
# 查看共享限速配置
tc -s qdisc show dev m-ifb-tx-shared
tc -s qdisc show dev m-ifb-rx-shared

# 查看详细统计
tc -s class show dev m-ifb-tx-shared
tc -s class show dev m-ifb-rx-shared

# 查看单个虚拟网卡的重定向规则
tc filter show dev m-ss-113cb8238d

架构图：
----------------------------------------
   ┌───────────┬───────────┬───────────┐
   │m-ss-*-1   │m-ss-*-2   │m-ss-*-3   │
   │(虚拟网卡) │(虚拟网卡) │(虚拟网卡) │
   └─────┬─────┴─────┬─────┴─────┬─────┘
         │           │           │
         │ redirect  │ redirect  │ redirect
         ▼           ▼           ▼
    ┌────────────────────────────────┐
    │    m-ifb-tx-shared (上传)      │ ← 50Mbps 总限速
    │    m-ifb-rx-shared (下载)      │ ← 50Mbps 总限速
    └────────────────────────────────┘
                    │
                    ▼
               物理网卡...

EOF
}

# 如果直接执行脚本，显示帮助
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  __help
fi
