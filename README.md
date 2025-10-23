# Linux 多网卡流量控制方案

本项目提供了针对复杂网络环境（多网卡、虚拟网卡）的 TC (Traffic Control) 流量限速解决方案。

## 快速开始

### 场景 1: IP 配置在物理网卡上

```bash
source scripts/v13.sh
export UPLOAD_RATE="100mbit"
export DOWNLOAD_RATE="200mbit"
__tc_qdisc_enable
```

### 场景 2: IP 配置在虚拟网卡上 - 每个网卡独立限速

```bash
source scripts/v14-virtual-nic.sh
export UPLOAD_RATE="100mbit"   # 每个网卡 100Mbps
export DOWNLOAD_RATE="200mbit" # 每个网卡 200Mbps
__tc_qdisc_enable

# 查看统计
__tc_qdisc_status
```

### 场景 3: IP 配置在虚拟网卡上 - 所有网卡共享总带宽 ⭐

```bash
source scripts/v15-virtual-nic-shared.sh
export RATE_TX="100mbit"   # 所有网卡共享 100Mbps 上传（为空或0表示不限速）
export RATE_RX="200mbit"   # 所有网卡共享 200Mbps 下载（为空或0表示不限速）
__tc_qdisc_enable

# 只限制上传，不限制下载
export RATE_TX="100mbit"
export RATE_RX="0"
__tc_qdisc_enable

# 查看统计
__tc_qdisc_status
```

## 方案选择

### 如何判断使用哪个方案？

运行诊断工具：

```bash
bash scripts/diagnose-traffic-path.sh
```

或者快速测试：

```bash
bash scripts/quick-test-tc.sh
```

### 方案对比

| 特性           | v13 (物理网卡) | v14 (虚拟网卡独立)     | v15 (虚拟网卡共享) ⭐  |
| -------------- | -------------- | ---------------------- | ---------------------- |
| **适用场景**   | IP 在物理网卡  | 每个虚拟网卡需独立限速 | 所有虚拟网卡共享总带宽 |
| **IFB 数量**   | 2 个           | N\*2 个                | 2 个                   |
| **总带宽**     | 限速值         | N × 限速值             | 限速值                 |
| **内存占用**   | 低 (~10MB)     | 高 (~40MB, 10 网卡)    | 低 (~4MB)              |
| **配置复杂度** | 简单           | 中等                   | 简单                   |
| **限速语义**   | 总带宽限制     | 每网卡独立限制         | 总带宽限制             |

详细对比见：

- [docs/v13-vs-v14.md](docs/v13-vs-v14.md) - 物理网卡 vs 虚拟网卡
- [docs/v14-vs-v15.md](docs/v14-vs-v15.md) - 独立限速 vs 共享限速

## 目录结构

```
.
├── README.md                          # 本文件
├── docs/
│   ├── physical-nic-detection.md      # 物理网卡检测方法对比
│   ├── virtual-nic-traffic-analysis.md# 虚拟网卡流量分析
│   ├── v13-vs-v14.md                  # 物理网卡 vs 虚拟网卡对比
│   ├── v14-vs-v15.md                  # 独立限速 vs 共享限速对比
│   └── v15-usage.md                   # v15 使用指南（RATE_TX/RATE_RX）
├── scripts/
│   ├── v13.sh                         # 物理网卡统一限速方案
│   ├── v14-virtual-nic.sh             # 虚拟网卡独立限速方案
│   ├── v15-virtual-nic-shared.sh      # 虚拟网卡共享限速方案 ⭐
│   ├── test_v13.sh                    # v13 测试脚本
│   ├── test_v15_examples.sh           # v15 交互式示例脚本
│   ├── diagnose-traffic-path.sh       # 流量路径诊断工具
│   ├── quick-test-tc.sh               # 快速限速测试
│   ├── debug-tc-rules.sh              # TC 规则调试工具
│   ├── verify-bandwidth-limit.sh      # 带宽限速验证工具
│   └── detect-physical-nics.sh        # 物理网卡检测工具
```

## 典型问题案例

### 案例：虚拟网卡环境限速失败

**环境特征**：

- 物理网卡：`eno1np0`, `eno2np1`（无 IP）
- 虚拟网卡：`m-ss-*`, `m-ms-*`（有 IP 和路由）
- v13 方案失败（TC 统计显示 0 bytes）

**问题原因**：
流量在虚拟化层被处理，绕过了物理网卡的 qdisc 层。

**解决方案**：
使用 v14 方案，直接在虚拟网卡上配置 TC。

**验证结果**：

```
=== m-ss-113cb8238d ===
上传: 289451704 bytes, 254250 packets  ✅
下载: 154656415 bytes, 246645 packets  ✅
```

详见：[docs/v13-vs-v14.md](docs/v13-vs-v14.md)

## 常用命令

### 查看限速状态

```bash
# v14 统计
source scripts/v14-virtual-nic.sh
__tc_qdisc_status

# 查看特定网卡
tc -s qdisc show dev m-ss-113cb8238d
tc -s class show dev m-ss-113cb8238d

# 查看 IFB 设备
ip link show | grep ifb
tc -s qdisc show dev ifb-m-ss-113cb
```

### 禁用限速

```bash
# v13
source scripts/v13.sh
__tc_qdisc_disable

# v14
source scripts/v14-virtual-nic.sh
__tc_qdisc_disable
```

### 验证限速是否生效

```bash
# 自动验证
bash scripts/verify-bandwidth-limit.sh

# 手动测试（下载）
curl -o /dev/null http://speedtest.tele2.net/10MB.zip

# 使用 iperf3
iperf3 -c speedtest.server -t 30
```

## 技术原理

### v13: 物理网卡统一限速

```
所有物理网卡 egress → m-ifb-tx → HTB 限速（上行）
所有物理网卡 ingress → m-ifb-rx → HTB 限速（下行）
```

### v14: 虚拟网卡直接限速

```
每个虚拟网卡 egress → HTB 限速（上行）
每个虚拟网卡 ingress → ifb-xxx → HTB 限速（下行）
```

详见：

- [docs/physical-nic-detection.md](docs/physical-nic-detection.md) - 物理网卡检测原理
- [docs/virtual-nic-traffic-analysis.md](docs/virtual-nic-traffic-analysis.md) - 虚拟网卡流量分析

## 性能影响

### v13 性能开销

- CPU: 2-5% per Gbps
- 内存: ~10 MB (2 IFB 设备)

### v14 性能开销

- CPU: 5-10% per Gbps
- 内存: ~2 MB per 虚拟网卡（假设 10 个虚拟网卡 = 20 MB）

## 高级用法

### 不同网卡配置不同限速

编辑 `v14-virtual-nic.sh`，在配置循环中添加条件：

```bash
echo "$_all_ifaces" | while read -r iface; do
  # 根据网卡名称设置不同限速
  case $iface in
    m-ss-*)
      UPLOAD_RATE="100mbit"
      DOWNLOAD_RATE="200mbit"
      ;;
    m-ms-*)
      UPLOAD_RATE="50mbit"
      DOWNLOAD_RATE="50mbit"
      ;;
  esac

  # 继续配置...
done
```

### 只限速特定网卡

修改 `_all_ifaces` 的过滤条件：

```bash
# 只限速 m-ss 开头的网卡
_all_ifaces=$(... | grep '^m-ss-')

# 手动指定网卡列表
_all_ifaces="m-ss-113cb8238d m-ss-04c6189bf5"
```

## 故障排查

### 1. TC 规则未生效（统计为 0）

```bash
# 运行调试工具
bash scripts/debug-tc-rules.sh

# 检查是否使用了错误的方案
# 如果 IP 在虚拟网卡上，必须用 v14
```

### 2. 速度未被限制

```bash
# 检查 overlimits 计数
tc -s class show dev m-ss-113cb8238d

# 如果 overlimits > 0，说明限速在工作
# 如果 = 0，说明当前流量低于限速阈值
```

### 3. IFB 设备创建失败

```bash
# 加载 IFB 模块
modprobe ifb numifbs=20

# 检查模块是否加载
lsmod | grep ifb
```

## 集成到 v12.sh

如果你想把 v14 集成到原有的 v12.sh（etcd 配置 + 定时任务）：

```bash
# 替换 v12.sh 中的 __tc_qdisc_enable 和 __tc_qdisc_disable
# 使用 v14-virtual-nic.sh 中的对应函数

# 或者在 v12.sh 中 source v14:
source /path/to/v14-virtual-nic.sh
```

## 项目历史

- **v12**: 单网卡环境，基于 etcd 配置的限速方案
- **v13**: 多网卡环境，物理网卡统一限速（IFB tx/rx）
- **v14**: 虚拟网卡环境，每个虚拟网卡独立限速
- **v15**: 虚拟网卡环境，所有虚拟网卡共享总带宽限速 ⭐

## 贡献

如有问题或建议，欢迎提 Issue。

## 许可

MIT License
