-- 创建数据库
CREATE DATABASE IF NOT EXISTS smart_home;
USE smart_home;

-- 设备表
CREATE TABLE IF NOT EXISTS devices (
    id INT PRIMARY KEY AUTO_INCREMENT,
    device_id VARCHAR(50) UNIQUE NOT NULL,
    device_name VARCHAR(100) NOT NULL,
    device_type ENUM('light', 'fan', 'ac') NOT NULL,
    power_rating DECIMAL(8,2) NOT NULL, -- 额定功率(W)
    status ENUM('on', 'off') DEFAULT 'off',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- 实时用电记录表
CREATE TABLE IF NOT EXISTS power_consumption (
    id INT PRIMARY KEY AUTO_INCREMENT,
    device_id VARCHAR(50) NOT NULL,
    power_usage DECIMAL(10,4) NOT NULL, -- 用电量(度)
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (device_id) REFERENCES devices(device_id),
    INDEX idx_timestamp (timestamp),
    INDEX idx_device_timestamp (device_id, timestamp)
);

-- 小时用电统计表
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

-- 日用电统计表
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

-- 周用电统计表
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

-- 月用电统计表
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

-- 报警记录表
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

-- 插入模拟设备数据
INSERT INTO devices (device_id, device_name, device_type, power_rating, status) VALUES
('light_001', '客厅主灯', 'light', 60.00, 'off'),
('light_002', '卧室灯', 'light', 40.00, 'off'),
('light_003', '厨房灯', 'light', 30.00, 'off'),
('fan_001', '客厅风扇', 'fan', 75.00, 'off'),
('fan_002', '卧室风扇', 'fan', 60.00, 'off'),
('ac_001', '客厅空调', 'ac', 1500.00, 'off'),
('ac_002', '卧室空调', 'ac', 1200.00, 'off');

-- 创建存储过程：生成模拟用电数据
DELIMITER $$
CREATE PROCEDURE GenerateSimulatedData()
BEGIN
    DECLARE device_count INT DEFAULT 7;
    DECLARE i INT DEFAULT 0;
    DECLARE current_device_id VARCHAR(50);
    DECLARE device_power DECIMAL(8,2);
    DECLARE device_status VARCHAR(10);
    DECLARE usage_power DECIMAL(10,4);
    
    WHILE i < device_count DO
        SELECT device_id, power_rating, status INTO current_device_id, device_power, device_status
        FROM devices LIMIT i, 1;
        
        IF device_status = 'on' THEN
            SET usage_power = device_power * RAND() * 0.1 / 1000; -- 转换为度
            INSERT INTO power_consumption (device_id, power_usage) 
            VALUES (current_device_id, usage_power);
        END IF;
        
        SET i = i + 1;
    END WHILE;
END$$
DELIMITER ;

-- 创建触发器：设备状态变化时更新用电
DELIMITER $$
CREATE TRIGGER after_device_update
AFTER UPDATE ON devices
FOR EACH ROW
BEGIN
    IF NEW.status = 'on' AND OLD.status = 'off' THEN
        INSERT INTO power_consumption (device_id, power_usage) 
        VALUES (NEW.device_id, NEW.power_rating * 0.05 / 1000);
    END IF;
END$$
DELIMITER ;