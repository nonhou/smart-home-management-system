# 智能家居管理系统

课程实践项目。基于 Node-RED + MySQL 实现的智能家居控制与用电量统计系统，覆盖设备控制、实时用电监测、历史用电量多维度统计与可视化报表。

## 功能

| 模块 | 功能 | 说明 |
| --- | --- | --- |
| 控制 | 单点控制 | 对单一设备单独开关 |
| 控制 | 批量控制 | 对多台设备批量开关 |
| 监测 | 实时电量监测 | 对设备用电量实时监测 |
| 统计 | 小时 / 日 / 周 / 月统计 | 按四个时间维度统计设备用电量 |

性能要求：单点控制响应 ≤ 0.5 秒，批量控制响应 ≤ 1 秒。

## 数据库设计

数据库名 `smart_home`，共 **7 张表**：

| 表名 | 用途 |
| --- | --- |
| `devices` | 设备表，含设备类型（light / fan / ac）、额定功率、开关状态 |
| `power_consumption` | 实时用电记录表，按设备与时间戳记录用电量 |
| `hourly_stats` | 小时用电统计表 |
| `daily_stats` | 日用电统计表 |
| `weekly_stats` | 周用电统计表（含周序号） |
| `monthly_stats` | 月用电统计表（含月序号） |
| `alerts` | 报警记录表，支持高位用电、设备故障、异常模式三类报警 |

**四张统计表结构一致**，每张按「设备 + 时间粒度」输出 **5 类统计量**：

- `total_power` 总量
- `avg_power` 均值
- `max_power` 最大值
- `min_power` 最小值
- `record_count` 记录数

每张统计表都建了 `(device_id, 时间字段)` 的唯一键，保证同一设备同一时间窗口只生成一条统计记录。

### 存储过程与触发器

- **存储过程 `GenerateSimulatedData()`**：遍历设备表，按设备状态与额定功率计算用电量并批量写入 `power_consumption`，用于生成模拟数据。
- **触发器 `after_device_update`**：监听 `devices` 表的状态变更，当设备由 `off` 变为 `on` 时，自动按额定功率写入一条用电记录，实现用电数据的自动生成。

建表、存储过程与触发器的完整脚本见 `sql/schema.sql`。

## 接口设计

共 **6 个数据接口**：

| 接口 | 协议 | 用途 |
| --- | --- | --- |
| `reportDeviceData` | HTTP POST / MQTT | 设备定时上报运行数据，支持实时异常检测 |
| `batchReportData` | HTTP POST | 批量上报，降低网络开销，返回成功 / 失败条数 |
| `subscribeDeviceMetrics` | WebSocket / MQTT | 实时数据订阅推送 |
| `getLiveDashboardData` | Server-Sent Events | 仪表盘实时数据（设备总数、在线数、活跃报警、总用电量） |
| `controlDevice` | HTTP PUT | 单设备控制 |
| `batchControlDevices` | HTTP POST | 批量设备控制，返回成功 / 失败条数与明细 |

## 可视化界面

基于 Node-RED Dashboard 搭建 **5 个页面**，包含 22 个控制按钮、9 个开关、5 张数据表格与 4 个统计图表。流图共 212 个节点。

## 环境要求

| 组件 | 版本 |
| --- | --- |
| Node-RED | 3.x |
| node-red-dashboard | 3.x |
| node-red-node-mysql | 1.x |
| MySQL | 8.0 |

Node-RED 依赖安装：

```bash
cd ~/.node-red
npm install node-red-dashboard node-red-node-mysql
```

## 运行步骤

1. 建库建表：

   ```bash
   mysql -u root -p < sql/schema.sql
   ```

2. 启动 Node-RED：

   ```bash
   node-red
   ```

3. 浏览器打开 `http://localhost:1880`，导入 `flows/flows.json`。

4. 配置 MySQL 节点：填写数据库地址、端口、库名 `smart_home`、用户名与密码。

5. 打开 Dashboard：`http://localhost:1880/ui`。

6. 点击「生成模拟数据」按钮，或手动开关设备触发触发器写入用电记录，统计数据会自动聚合。

## 目录结构

```
smart-home-management-system/
├── README.md
├── requirements.txt
├── .gitignore
├── flows/
│   └── flows.json          # Node-RED 流图
├── sql/
│   └── schema.sql          # 建库建表 + 存储过程 + 触发器 + 模拟设备数据
└── docs/
    └── 接口设计.md          # 6 个接口的输入输出定义
```

## 说明

- 数据库中的设备数据与用电记录为模拟数据，由存储过程按额定功率随机生成，非真实采集数据。
- 课程实践项目，独立完成。
