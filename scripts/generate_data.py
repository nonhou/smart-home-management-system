# -*- coding: utf-8 -*-
"""
为智能家居管理系统生成 BI 可用的时间序列数据。

原存储过程 GenerateSimulatedData() 每次只插 7 行、且时间戳全是当前时刻，
画不出任何趋势。本脚本生成 90 天 × 7 设备 × 24 小时的逐小时用电数据，
再用 SQL 聚合出小时 / 日 / 周 / 月四张统计表。

用法：
    pip install pymysql
    python generate_data.py --user root --password 你的密码

可选参数：
    --host localhost --port 3306 --db smart_home
    --start 2026-07-02 --days 90
    --reset            先清空四张统计表和用电记录表再生成
"""
import argparse
import datetime as dt
import random
import sys

try:
    import pymysql
except ImportError:
    sys.exit('缺少依赖，请先执行：pip install pymysql')

# ---------------------------------------------------------------- 设备定义
DEVICES = [
    # (device_id,  device_name, device_type, power_rating(W))
    ('light_001', '客厅主灯', 'light', 60.00),
    ('light_002', '卧室灯',   'light', 40.00),
    ('light_003', '厨房灯',   'light', 30.00),
    ('fan_001',   '客厅风扇', 'fan',   75.00),
    ('fan_002',   '卧室风扇', 'fan',   60.00),
    ('ac_001',    '客厅空调', 'ac',  1500.00),
    ('ac_002',    '卧室空调', 'ac',  1200.00),
]

DDL = """
CREATE TABLE IF NOT EXISTS devices (
    id INT PRIMARY KEY AUTO_INCREMENT,
    device_id VARCHAR(50) UNIQUE NOT NULL,
    device_name VARCHAR(100) NOT NULL,
    device_type ENUM('light', 'fan', 'ac') NOT NULL,
    power_rating DECIMAL(8,2) NOT NULL,
    status ENUM('on', 'off') DEFAULT 'off',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS power_consumption (
    id INT PRIMARY KEY AUTO_INCREMENT,
    device_id VARCHAR(50) NOT NULL,
    power_usage DECIMAL(10,4) NOT NULL,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (device_id) REFERENCES devices(device_id),
    INDEX idx_timestamp (timestamp),
    INDEX idx_device_timestamp (device_id, timestamp)
);

CREATE TABLE IF NOT EXISTS hourly_stats (
    id INT PRIMARY KEY AUTO_INCREMENT,
    device_id VARCHAR(50) NOT NULL,
    hour_start DATETIME NOT NULL,
    total_power DECIMAL(12,4) NOT NULL,
    avg_power DECIMAL(10,4) NOT NULL,
    max_power DECIMAL(10,4) NOT NULL,
    min_power DECIMAL(10,4) NOT NULL,
    record_count INT NOT NULL,
    FOREIGN KEY (device_id) REFERENCES devices(device_id),
    UNIQUE KEY unique_device_hour (device_id, hour_start)
);

CREATE TABLE IF NOT EXISTS daily_stats (
    id INT PRIMARY KEY AUTO_INCREMENT,
    device_id VARCHAR(50) NOT NULL,
    date DATE NOT NULL,
    total_power DECIMAL(12,4) NOT NULL,
    avg_power DECIMAL(10,4) NOT NULL,
    max_power DECIMAL(10,4) NOT NULL,
    min_power DECIMAL(10,4) NOT NULL,
    record_count INT NOT NULL,
    FOREIGN KEY (device_id) REFERENCES devices(device_id),
    UNIQUE KEY unique_device_date (device_id, date)
);

CREATE TABLE IF NOT EXISTS weekly_stats (
    id INT PRIMARY KEY AUTO_INCREMENT,
    device_id VARCHAR(50) NOT NULL,
    week_start DATE NOT NULL,
    week_number INT NOT NULL,
    total_power DECIMAL(12,4) NOT NULL,
    avg_power DECIMAL(10,4) NOT NULL,
    max_power DECIMAL(10,4) NOT NULL,
    min_power DECIMAL(10,4) NOT NULL,
    record_count INT NOT NULL,
    FOREIGN KEY (device_id) REFERENCES devices(device_id),
    UNIQUE KEY unique_device_week (device_id, week_start)
);

CREATE TABLE IF NOT EXISTS monthly_stats (
    id INT PRIMARY KEY AUTO_INCREMENT,
    device_id VARCHAR(50) NOT NULL,
    month_start DATE NOT NULL,
    month_number INT NOT NULL,
    total_power DECIMAL(12,4) NOT NULL,
    avg_power DECIMAL(10,4) NOT NULL,
    max_power DECIMAL(10,4) NOT NULL,
    min_power DECIMAL(10,4) NOT NULL,
    record_count INT NOT NULL,
    FOREIGN KEY (device_id) REFERENCES devices(device_id),
    UNIQUE KEY unique_device_month (device_id, month_start)
);

CREATE TABLE IF NOT EXISTS alerts (
    id INT PRIMARY KEY AUTO_INCREMENT,
    device_id VARCHAR(50) NOT NULL,
    alert_type ENUM('high_power', 'device_fault', 'unusual_pattern') NOT NULL,
    alert_message TEXT NOT NULL,
    power_value DECIMAL(10,4),
    threshold DECIMAL(10,4),
    status ENUM('active', 'resolved') DEFAULT 'active',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    resolved_at TIMESTAMP NULL,
    FOREIGN KEY (device_id) REFERENCES devices(device_id)
);
"""

# ------------------------------------------------- 各类型设备的负载曲线（0~1）
def load_factor(device_type, hour, month):
    if device_type == 'ac':
        # 午后到夜间高、凌晨低；7/8 月最热
        base = 0.75 if 12 <= hour <= 22 else (0.15 if hour <= 6 else 0.45)
        season = 1.0 if month in (7, 8) else 0.55
        return base * season
    if device_type == 'light':
        if 18 <= hour <= 23:
            return 0.90
        if hour in (6, 7):
            return 0.40
        return 0.02
    if device_type == 'fan':
        return 0.50 if 10 <= hour <= 22 else 0.05
    return 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', default='localhost')
    ap.add_argument('--port', type=int, default=3306)
    ap.add_argument('--user', default='root')
    ap.add_argument('--password', default='')
    ap.add_argument('--db', default='smart_home')
    ap.add_argument('--start', default='2026-07-02')
    ap.add_argument('--days', type=int, default=90)
    ap.add_argument('--reset', action='store_true')
    args = ap.parse_args()

    conn = pymysql.connect(host=args.host, port=args.port, user=args.user,
                           password=args.password, charset='utf8mb4',
                           autocommit=False)
    cur = conn.cursor()

    # 1. 建库建表
    cur.execute('CREATE DATABASE IF NOT EXISTS `%s` '
                'DEFAULT CHARACTER SET utf8mb4' % args.db)
    cur.execute('USE `%s`' % args.db)
    for stmt in [x.strip() for x in DDL.split(';') if x.strip()]:
        cur.execute(stmt)
    print('建表完成')

    if args.reset:
        for t in ('alerts', 'hourly_stats', 'daily_stats', 'weekly_stats',
                  'monthly_stats', 'power_consumption'):
            cur.execute('DELETE FROM `%s`' % t)
        print('已清空历史数据')

    # 2. 设备
    cur.executemany(
        'INSERT INTO devices (device_id, device_name, device_type, power_rating, status) '
        'VALUES (%s, %s, %s, %s, %s) '
        'ON DUPLICATE KEY UPDATE device_name=VALUES(device_name), '
        'device_type=VALUES(device_type), power_rating=VALUES(power_rating)',
        DEVICES)
    print('设备写入完成：%d 台' % len(DEVICES))

    # 3. 逐小时用电记录
    start = dt.datetime.strptime(args.start, '%Y-%m-%d')
    rows = []
    for day in range(args.days):
        cur_day = start + dt.timedelta(days=day)
        for hour in range(24):
            ts = cur_day + dt.timedelta(hours=hour)
            for dev_id, _, dev_type, rating in DEVICES:
                factor = load_factor(dev_type, hour, cur_day.month)
                if factor <= 0:
                    continue
                # 负载在基准上浮动 ±20%
                kwh = rating / 1000.0 * factor * random.uniform(0.8, 1.2)
                if kwh < 0.001:
                    continue
                rows.append((dev_id, round(kwh, 4), ts))

    cur.executemany(
        'INSERT INTO power_consumption (device_id, power_usage, timestamp) '
        'VALUES (%s, %s, %s)', rows)
    print('用电记录写入完成：%d 行，时间范围 %s ~ %s'
          % (len(rows), start.date(), (start + dt.timedelta(days=args.days - 1)).date()))

    # 4. 用 SQL 聚合四张统计表（GROUP BY 聚合，体现 SQL 功底）
    agg = {
        'hourly_stats': (
            'DATE_FORMAT(timestamp, "%%Y-%%m-%%d %%H:00:00")',
            'hour_start'),
        'daily_stats': ('DATE(timestamp)', 'date'),
        'weekly_stats': (
            'DATE_SUB(DATE(timestamp), INTERVAL WEEKDAY(timestamp) DAY)',
            'week_start'),
        'monthly_stats': (
            'DATE_FORMAT(timestamp, "%%Y-%%m-01")',
            'month_start'),
    }
    for table, (expr, key_col) in agg.items():
        extra_sel, extra_col = '', ''
        if table == 'weekly_stats':
            extra_sel, extra_col = ', WEEK(%s, 3)' % expr, ', week_number'
        if table == 'monthly_stats':
            extra_sel, extra_col = ', MONTH(timestamp)', ', month_number'

        cur.execute('DELETE FROM `%s`' % table)
        sql = (
            'INSERT INTO `{t}` (device_id, {k}{ec}, total_power, avg_power, '
            'max_power, min_power, record_count) '
            'SELECT device_id, {e}{es}, ROUND(SUM(power_usage),4), '
            'ROUND(AVG(power_usage),4), ROUND(MAX(power_usage),4), '
            'ROUND(MIN(power_usage),4), COUNT(*) '
            'FROM power_consumption GROUP BY device_id, {k}{ec2}'
        ).format(t=table, k=key_col, e=expr, ec=extra_col, es=extra_sel, ec2=extra_col)
        cur.execute(sql)
        cur.execute('SELECT COUNT(*) FROM `%s`' % table)
        print('  %-14s 聚合 %d 行' % (table, cur.fetchone()[0]))

    # 5. 告警记录：超过该设备额定功率对应小时电量 1.3 倍的时段
    cur.execute('DELETE FROM alerts')
    cur.execute(
        'INSERT INTO alerts (device_id, alert_type, alert_message, power_value, '
        'threshold, status, created_at) '
        'SELECT p.device_id, "high_power", '
        'CONCAT(d.device_name, " 用电量超出阈值"), p.power_usage, '
        'ROUND(d.power_rating/1000*1.3, 4), '
        'IF(RAND() < 0.6, "resolved", "active"), p.timestamp '
        'FROM power_consumption p JOIN devices d ON d.device_id = p.device_id '
        'WHERE p.power_usage > d.power_rating/1000*1.3')
    cur.execute('SELECT COUNT(*) FROM alerts')
    print('  告警记录   写入 %d 行' % cur.fetchone()[0])

    conn.commit()
    cur.close()
    conn.close()
    print('\n全部完成。数据库：%s' % args.db)


if __name__ == '__main__':
    main()
