/* =========================================================
   智能家居管理系统 · 历史模拟数据生成脚本
   ---------------------------------------------------------
   schema.sql 只负责建表，本脚本负责把数据"造满"：

     1. tally        数字辅助表，用于生成时间轴
     2. GenerateHistoricalData(p_days)   生成 15 分钟粒度用电明细
     3. BuildHourlyStats()               明细 -> 小时统计表
     4. BuildDailyStats()                明细 -> 日统计表
     5. BuildWeeklyStats()               明细 -> 周统计表
     6. BuildMonthlyStats()              明细 -> 月统计表
     7. GenerateAlerts(p_count)          生成三类报警记录
     8. RebuildAll(p_days, p_count)      一键清空并按顺序重建全部数据

   设计说明
   ---------------------------------------------------------
   · 用电量按「额定功率 x 时段负载率 x 设备系数 x 周末系数 x 随机抖动」计算，
     不是纯 RAND()，因此小时曲线呈现真实的早晚高峰形态，可直接用于报表分析。
   · 负载率与各系数相乘后统一 LEAST(..., 1.00) 截断，
     保证任意一条记录的 15 分钟用电量都不会超过 额定功率 x 0.25 小时，
     即电器始终运行在额定功率以内，数据经得起反算。
   · 设备处于关闭时段时不写入记录（负载率为 0 被过滤掉），
     因此 record_count 具有实际业务含义。
   · 全部走 INSERT ... SELECT 批量写入，不使用逐行 WHILE 循环。
   · 各 Build* 过程执行前先清空目标表，脚本可重复执行。

   执行方式
   ---------------------------------------------------------
     mysql -u root -p --default-character-set=utf8mb4 < sql/generate_history.sql
     mysql -u root -p smart_home -e "CALL RebuildAll(90, 200);"

   前置条件：schema.sql 已执行，smart_home 库与 7 张表、7 台设备已存在。
   ========================================================= */

USE smart_home;

-- =========================================================
-- 0. tally 数字辅助表（0 ~ 999）
-- =========================================================
SET SESSION cte_max_recursion_depth = 2000;

DROP TABLE IF EXISTS tally;
CREATE TABLE tally (
    n INT PRIMARY KEY
) ENGINE = InnoDB;

INSERT INTO tally (n)
WITH RECURSIVE seq (n) AS (
    SELECT 0
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 999
)
SELECT n FROM seq;


-- =========================================================
-- 1. 生成用电明细：15 分钟一个采样点
--    数据量 = p_days x 96 个时间槽 x 7 台设备（关闭时段不计）
-- =========================================================
DROP PROCEDURE IF EXISTS GenerateHistoricalData;

DELIMITER $$
CREATE PROCEDURE GenerateHistoricalData(IN p_days INT)
BEGIN
    DECLARE v_start DATE;
    DECLARE v_end   DATE;

    IF p_days IS NULL OR p_days < 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'p_days 必须为正整数';
    END IF;

    SET v_end   = DATE_SUB(CURDATE(), INTERVAL 1 DAY);          -- 数据截至昨天
    SET v_start = DATE_SUB(v_end, INTERVAL p_days - 1 DAY);

    TRUNCATE TABLE power_consumption;

    -- 分两层派生表：MySQL 不允许在同一层 SELECT 中引用刚定义的列别名，
    -- 因此第一层算出各系数，第二层再算用电量。
    INSERT INTO power_consumption (device_id, power_usage, timestamp)
    SELECT
        y.device_id,
        ROUND(
            y.power_rating / 1000
            * 0.25
            -- 负载率上限截断为 1.0：电器不可能超过额定功率运行
            * LEAST(
                  y.load_factor
                  * y.device_factor
                  * IF(DAYOFWEEK(y.ts) IN (1, 7), 1.10, 1.00)      -- 周末偏高
                  * (0.85 + RAND() * 0.30),                        -- ±15% 抖动
                  1.00
              ),
            4
        ) AS power_usage,
        y.ts
    FROM (
        SELECT
            d.device_id,
            d.power_rating,
            dt.ts,

            -- 按设备类型划分的时段负载率（0 ~ 1，1.0 = 满负荷运行）
            CASE d.device_type
                WHEN 'ac' THEN CASE
                    WHEN HOUR(dt.ts) BETWEEN 18 AND 22 THEN 0.80   -- 晚间制冷高峰
                    WHEN HOUR(dt.ts) BETWEEN 12 AND 13 THEN 0.70   -- 午间
                    WHEN HOUR(dt.ts) BETWEEN 1  AND 5  THEN 0.20   -- 夜间睡眠模式
                    ELSE 0.40
                END
                WHEN 'light' THEN CASE
                    WHEN HOUR(dt.ts) BETWEEN 18 AND 23 THEN 0.85   -- 晚间照明
                    WHEN HOUR(dt.ts) BETWEEN 6  AND 7  THEN 0.50   -- 早起
                    WHEN HOUR(dt.ts) BETWEEN 1  AND 5  THEN 0.00   -- 凌晨熄灭
                    ELSE 0.12
                END
                WHEN 'fan' THEN CASE
                    WHEN HOUR(dt.ts) BETWEEN 11 AND 15 THEN 0.80   -- 午后
                    WHEN HOUR(dt.ts) BETWEEN 18 AND 21 THEN 0.45
                    WHEN HOUR(dt.ts) BETWEEN 1  AND 5  THEN 0.00   -- 凌晨停机
                    ELSE 0.18
                END
            END AS load_factor,

            -- 同类型设备之间的个体差异（倍率，不超过 1）
            CASE d.device_id
                WHEN 'light_001' THEN 1.00   -- 客厅主灯
                WHEN 'light_002' THEN 0.90   -- 卧室灯
                WHEN 'light_003' THEN 0.80   -- 厨房灯
                WHEN 'fan_001'   THEN 1.00   -- 客厅风扇
                WHEN 'fan_002'   THEN 0.85   -- 卧室风扇
                WHEN 'ac_001'    THEN 1.00   -- 客厅空调
                WHEN 'ac_002'    THEN 0.80   -- 卧室空调
                ELSE 0.90
            END AS device_factor
        FROM devices d
        CROSS JOIN (
            -- 时间轴：p_days 天 x 96 个 15 分钟槽
            SELECT DATE_ADD(
                       DATE_ADD(
                           DATE_SUB(DATE_SUB(CURDATE(), INTERVAL 1 DAY), INTERVAL p_days - 1 DAY),
                           INTERVAL t1.n DAY
                       ),
                       INTERVAL (t2.n * 15) MINUTE
                   ) AS ts
            FROM tally t1
            CROSS JOIN tally t2
            WHERE t1.n < p_days
              AND t2.n < 96
        ) dt
    ) y
    WHERE y.load_factor > 0;   -- 设备关闭时段不产生记录

    SELECT CONCAT('明细生成完成：', v_start, ' ~ ', v_end,
                  '，共 ', (SELECT COUNT(*) FROM power_consumption), ' 行') AS result;
END$$
DELIMITER ;


-- =========================================================
-- 2. 回填小时统计表
-- =========================================================
DROP PROCEDURE IF EXISTS BuildHourlyStats;

DELIMITER $$
CREATE PROCEDURE BuildHourlyStats()
BEGIN
    TRUNCATE TABLE hourly_stats;

    INSERT INTO hourly_stats
        (device_id, hour_start, total_power, avg_power, max_power, min_power, record_count)
    SELECT
        device_id,
        DATE_ADD(DATE(timestamp), INTERVAL HOUR(timestamp) HOUR) AS hour_start,
        ROUND(SUM(power_usage), 4),
        ROUND(AVG(power_usage), 4),
        ROUND(MAX(power_usage), 4),
        ROUND(MIN(power_usage), 4),
        COUNT(*)
    FROM power_consumption
    GROUP BY device_id, DATE_ADD(DATE(timestamp), INTERVAL HOUR(timestamp) HOUR);

    SELECT CONCAT('hourly_stats 回填完成：', ROW_COUNT(), ' 行') AS result;
END$$
DELIMITER ;


-- =========================================================
-- 3. 回填日统计表
-- =========================================================
DROP PROCEDURE IF EXISTS BuildDailyStats;

DELIMITER $$
CREATE PROCEDURE BuildDailyStats()
BEGIN
    TRUNCATE TABLE daily_stats;

    INSERT INTO daily_stats
        (device_id, date, total_power, avg_power, max_power, min_power, record_count)
    SELECT
        device_id,
        DATE(timestamp) AS date,
        ROUND(SUM(power_usage), 4),
        ROUND(AVG(power_usage), 4),
        ROUND(MAX(power_usage), 4),
        ROUND(MIN(power_usage), 4),
        COUNT(*)
    FROM power_consumption
    GROUP BY device_id, DATE(timestamp);

    SELECT CONCAT('daily_stats 回填完成：', ROW_COUNT(), ' 行') AS result;
END$$
DELIMITER ;


-- =========================================================
-- 4. 回填周统计表（周一为一周起点，ISO 周序号）
-- =========================================================
DROP PROCEDURE IF EXISTS BuildWeeklyStats;

DELIMITER $$
CREATE PROCEDURE BuildWeeklyStats()
BEGIN
    TRUNCATE TABLE weekly_stats;

    INSERT INTO weekly_stats
        (device_id, week_start, week_number,
         total_power, avg_power, max_power, min_power, record_count)
    SELECT
        device_id,
        DATE_SUB(DATE(timestamp), INTERVAL WEEKDAY(timestamp) DAY) AS week_start,
        WEEK(timestamp, 3) AS week_number,
        ROUND(SUM(power_usage), 4),
        ROUND(AVG(power_usage), 4),
        ROUND(MAX(power_usage), 4),
        ROUND(MIN(power_usage), 4),
        COUNT(*)
    FROM power_consumption
    GROUP BY device_id,
             DATE_SUB(DATE(timestamp), INTERVAL WEEKDAY(timestamp) DAY),
             WEEK(timestamp, 3);

    SELECT CONCAT('weekly_stats 回填完成：', ROW_COUNT(), ' 行') AS result;
END$$
DELIMITER ;


-- =========================================================
-- 5. 回填月统计表
-- =========================================================
DROP PROCEDURE IF EXISTS BuildMonthlyStats;

DELIMITER $$
CREATE PROCEDURE BuildMonthlyStats()
BEGIN
    TRUNCATE TABLE monthly_stats;

    INSERT INTO monthly_stats
        (device_id, month_start, month_number,
         total_power, avg_power, max_power, min_power, record_count)
    SELECT
        device_id,
        DATE_SUB(DATE(timestamp), INTERVAL DAYOFMONTH(timestamp) - 1 DAY) AS month_start,
        MONTH(timestamp) AS month_number,
        ROUND(SUM(power_usage), 4),
        ROUND(AVG(power_usage), 4),
        ROUND(MAX(power_usage), 4),
        ROUND(MIN(power_usage), 4),
        COUNT(*)
    FROM power_consumption
    GROUP BY device_id,
             DATE_SUB(DATE(timestamp), INTERVAL DAYOFMONTH(timestamp) - 1 DAY),
             MONTH(timestamp);

    SELECT CONCAT('monthly_stats 回填完成：', ROW_COUNT(), ' 行') AS result;
END$$
DELIMITER ;


-- =========================================================
-- 6. 生成报警记录
--    p_count 为每一类报警的生成条数
--    三类：high_power 超功率 / device_fault 设备故障 / unusual_pattern 异常用电模式
--    约 12% 保持 active，其余 resolved 并带处理时间
-- =========================================================
DROP PROCEDURE IF EXISTS GenerateAlerts;

DELIMITER $$
CREATE PROCEDURE GenerateAlerts(IN p_count INT)
BEGIN
    DECLARE v_min DATETIME;
    DECLARE v_max DATETIME;

    IF p_count IS NULL OR p_count < 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'p_count 必须为正整数';
    END IF;

    SELECT MIN(timestamp), MAX(timestamp) INTO v_min, v_max FROM power_consumption;

    IF v_min IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'power_consumption 为空，请先执行 GenerateHistoricalData';
    END IF;

    TRUNCATE TABLE alerts;

    -- 6.1 超功率报警：取自明细中负载率真实超过 90% 额定功率的记录
    INSERT INTO alerts
        (device_id, alert_type, alert_message, power_value, threshold, status, created_at, resolved_at)
    SELECT
        s.device_id,
        'high_power',
        CONCAT(d.device_name, ' 用电量超出安全阈值'),
        s.power_value,
        s.threshold,
        s.status,
        s.created_at,
        IF(s.status = 'resolved', DATE_ADD(s.created_at, INTERVAL s.resolve_min MINUTE), NULL)
    FROM (
        SELECT
            p.device_id,
            p.power_usage AS power_value,
            ROUND(d2.power_rating / 1000 * 0.25 * 0.90, 4) AS threshold,
            p.timestamp AS created_at,
            IF(RAND() < 0.12, 'active', 'resolved') AS status,
            FLOOR(5 + RAND() * 175) AS resolve_min
        FROM power_consumption p
        JOIN devices d2 ON d2.device_id = p.device_id
        WHERE p.power_usage > d2.power_rating / 1000 * 0.25 * 0.90
        ORDER BY RAND()
        LIMIT p_count
    ) s
    JOIN devices d ON d.device_id = s.device_id;

    -- 6.2 设备故障报警：随机设备 + 数据时间范围内的随机时刻
    INSERT INTO alerts
        (device_id, alert_type, alert_message, power_value, threshold, status, created_at, resolved_at)
    SELECT
        s.device_id,
        'device_fault',
        CONCAT(d.device_name, ' 响应超时，疑似设备故障'),
        NULL,
        NULL,
        s.status,
        s.created_at,
        IF(s.status = 'resolved', DATE_ADD(s.created_at, INTERVAL s.resolve_min MINUTE), NULL)
    FROM (
        SELECT
            d2.device_id,
            DATE_ADD(
                DATE(DATE_SUB(v_min, INTERVAL -FLOOR(RAND() * DATEDIFF(v_max, v_min)) DAY)),
                INTERVAL (FLOOR(RAND() * 96) * 15) MINUTE
            ) AS created_at,
            IF(RAND() < 0.18, 'active', 'resolved') AS status,
            FLOOR(10 + RAND() * 240) AS resolve_min
        FROM devices d2
        CROSS JOIN tally t
        WHERE t.n < 40
        ORDER BY RAND()
        LIMIT p_count
    ) s
    JOIN devices d ON d.device_id = s.device_id;

    -- 6.3 异常用电模式报警：功率偏离该设备历史均值 1.5 倍标准差以上
    INSERT INTO alerts
        (device_id, alert_type, alert_message, power_value, threshold, status, created_at, resolved_at)
    SELECT
        s.device_id,
        'unusual_pattern',
        CONCAT(d.device_name, ' 出现异常用电模式'),
        s.power_value,
        s.threshold,
        s.status,
        s.created_at,
        IF(s.status = 'resolved', DATE_ADD(s.created_at, INTERVAL s.resolve_min MINUTE), NULL)
    FROM (
        SELECT
            p.device_id,
            p.power_usage AS power_value,
            ROUND(st.avg_power + 1.5 * st.sd_power, 4) AS threshold,
            p.timestamp AS created_at,
            IF(RAND() < 0.15, 'active', 'resolved') AS status,
            FLOOR(5 + RAND() * 300) AS resolve_min
        FROM power_consumption p
        JOIN (
            SELECT device_id,
                   AVG(power_usage) AS avg_power,
                   STDDEV(power_usage) AS sd_power
            FROM power_consumption
            GROUP BY device_id
        ) st ON st.device_id = p.device_id
        WHERE p.power_usage > st.avg_power + 1.5 * st.sd_power
        ORDER BY RAND()
        LIMIT p_count
    ) s
    JOIN devices d ON d.device_id = s.device_id;

    SELECT CONCAT('报警生成完成，共 ', (SELECT COUNT(*) FROM alerts), ' 条') AS result;
END$$
DELIMITER ;


-- =========================================================
-- 7. 一键重建：清空并按顺序生成全部数据
-- =========================================================
DROP PROCEDURE IF EXISTS RebuildAll;

DELIMITER $$
CREATE PROCEDURE RebuildAll(IN p_days INT, IN p_alerts INT)
BEGIN
    CALL GenerateHistoricalData(p_days);
    CALL BuildHourlyStats();
    CALL BuildDailyStats();
    CALL BuildWeeklyStats();
    CALL BuildMonthlyStats();
    CALL GenerateAlerts(p_alerts);
END$$
DELIMITER ;


/* =========================================================
   验证查询（按需手动执行）
   ---------------------------------------------------------
   -- 各表行数
   SELECT 'power_consumption' t, COUNT(*) c FROM power_consumption
   UNION ALL SELECT 'hourly_stats',  COUNT(*) FROM hourly_stats
   UNION ALL SELECT 'daily_stats',   COUNT(*) FROM daily_stats
   UNION ALL SELECT 'weekly_stats',  COUNT(*) FROM weekly_stats
   UNION ALL SELECT 'monthly_stats', COUNT(*) FROM monthly_stats
   UNION ALL SELECT 'alerts',        COUNT(*) FROM alerts;

   -- 时间范围
   SELECT MIN(timestamp), MAX(timestamp) FROM power_consumption;

   -- 各设备类型的小时曲线（应看到空调 18-22 点高峰、照明 1-5 点为 0）
   SELECT d.device_type, HOUR(p.timestamp) AS hh, ROUND(AVG(p.power_usage), 4) AS avg_power
   FROM power_consumption p
   JOIN devices d ON d.device_id = p.device_id
   GROUP BY d.device_type, HOUR(p.timestamp)
   ORDER BY d.device_type, hh;

   -- 报警类型与状态分布
   SELECT alert_type, status, COUNT(*) FROM alerts GROUP BY alert_type, status;
   ========================================================= */
