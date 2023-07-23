
-- LuaTools需要PROJECT和VERSION这两个信息
PROJECT = "mqttdemo"
VERSION = "1.0.0"

--[[
本demo需要mqtt库, 大部分能联网的设备都具有这个库
mqtt也是内置库, 无需require
]]

-- sys库是标配
_G.sys = require("sys")
--[[特别注意, 使用mqtt库需要下列语句]]
_G.sysplus = require("sysplus")

-- 自动低功耗, 轻休眠模式
-- Air780E支持uart唤醒和网络数据下发唤醒, 但需要断开USB,或者pm.power(pm.USB, false) 但这样也看不到日志了
-- pm.request(pm.LIGHT)

--根据自己的服务器修改以下参数
local mqtt_host = "your_mqtt_host_ip"
local mqtt_port = 1883
local mqtt_isssl = false
local client_id = "foggy-luatos"
local user_name = "mqtt_user_name"
local password = "mqtt_password"

local mqttc = nil

local RELAY_PIN = 1
gpio.setup(RELAY_PIN, 0, gpio.PULLUP)

local PWM_PIN = 27
local PWM_ID = 4 -- GPIO 27, NetLed
local pwm_duty_cycle = 70   -- default pwm duty cycle 70%
local DHT_PIN = 11
local INPUT_PIN = 9  -- gpio9 as input

sys.taskInit(function()
    -- 这个demo要求有wdt库
    -- wdt库的使用,基本上每个demo的头部都有演示
    -- 模组/芯片的内部硬狗, 能解决绝大多数情况下的死机问题
    -- 但如果有要求非常高的场景, 依然建议外挂硬件,然后通过gpio/i2c定时喂狗
    if wdt == nil then
        while 1 do
            sys.wait(1000)
            log.info("wdt", "this demo need wdt lib")
        end
    end
    -- 注意, 大部分芯片/模块是 2 倍超时时间后才会重启
    -- 以下是常规配置, 9秒超时, 3秒喂一次狗
    -- 若软件崩溃,死循环,硬件死机,那么 最多 18 秒后,自动复位
    -- 注意: 软件bug导致业务失败, 并不能通过wdt解决
    wdt.init(9000)
    sys.timerLoopStart(wdt.feed, 3000)
end)

-- 统一联网函数
sys.taskInit(function()
    local device_id = mcu.unique_id():toHex()
    -----------------------------
    -- 统一联网函数, 可自行删减
    ----------------------------
    if wlan and wlan.connect then
        -- wifi 联网, ESP32系列均支持
        local ssid = "uiot"
        local password = "12345678"
        log.info("wifi", ssid, password)
        -- TODO 改成自动配网
        -- LED = gpio.setup(12, 0, gpio.PULLUP)
        wlan.init()
        wlan.setMode(wlan.STATION) -- 默认也是这个模式,不调用也可以
        device_id = wlan.getMac():toHex()
        wlan.connect(ssid, password, 1)
    elseif mobile then
        -- Air780E/Air600E系列
        --mobile.simid(2) -- 自动切换SIM卡
        -- LED = gpio.setup(27, 0, gpio.PULLUP)
        device_id = mobile.imei()
    elseif w5500 then
        -- w5500 以太网, 当前仅Air105支持
        w5500.init(spi.HSPI_0, 24000000, pin.PC14, pin.PC01, pin.PC00)
        w5500.config() --默认是DHCP模式
        w5500.bind(socket.ETH0)
        -- LED = gpio.setup(62, 0, gpio.PULLUP)
    elseif socket or mqtt then
        -- 适配的socket库也OK
        -- 没有其他操作, 单纯给个注释说明
    else
        -- 其他不认识的bsp, 循环提示一下吧
        while 1 do
            sys.wait(1000)
            log.info("bsp", "本bsp可能未适配网络层, 请查证")
        end
    end
    -- 默认都等到联网成功
    sys.waitUntil("IP_READY")
    sys.publish("net_ready", device_id)
end)

sys.taskInit(function()
    -- 等待联网
    local ret, device_id = sys.waitUntil("net_ready")
    -- 下面的是mqtt的参数均可自行修改
    client_id = device_id
    pub_topic_humi = "/luatos/humi"
    pub_topic_temp = "/luatos/temp"
    sub_topic_relay = "/luatos/relay/cmd"
    sub_topic_pwm = "/loatos/pwm/cmd"
    pub_topic_relay_stat = "/luatos/relay/stat"
    pub_topic_pwm_stat = "/loatos/pwm/stat"
    availability_topic = "/loatos/available"
    -- 打印一下上报(pub)和下发(sub)的topic名称
    -- 上报: 设备 ---> 服务器
    -- 下发: 设备 <--- 服务器
    -- 可使用mqtt.x等客户端进行调试
    -- log.info("mqtt", "pub", pub_topic_humi,pub_topic_temp)
    -- log.info("mqtt", "sub", sub_topic_relay)

    -- 打印一下支持的加密套件, 通常来说, 固件已包含常见的99%的加密套件
    -- if crypto.cipher_suites then
    --     log.info("cipher", "suites", json.encode(crypto.cipher_suites()))
    -- end
    if mqtt == nil then
        while 1 do
            sys.wait(1000)
            log.info("bsp", "本bsp未适配mqtt库, 请查证")
        end
    end

    -------------------------------------
    -------- MQTT 演示代码 --------------
    -------------------------------------

    mqttc = mqtt.create(nil, mqtt_host, mqtt_port, mqtt_isssl, ca_file)

    mqttc:auth(client_id,user_name,password) -- client_id必填,其余选填
    -- mqttc:keepalive(240) -- 默认值240s
    mqttc:autoreconn(true, 3000) -- 自动重连机制

    mqttc:on(function(mqtt_client, event, data, payload)
        -- 用户自定义代码
        log.info("mqtt", "event", event, mqtt_client, data, payload)
        if event == "conack" then
            -- 联上了
            sys.publish("mqtt_conack")
            mqtt_client:subscribe(sub_topic_relay)--单主题订阅
            mqtt_client:subscribe(sub_topic_pwm)--单主题订阅
            mqtt_client:publish(pub_topic_relay_stat, tostring(gpio.get(RELAY_PIN)), 0)
            mqtt_client:publish(pub_topic_pwm_stat,tostring(pwm_duty_cycle), 0)
            mqttc:publish(availability_topic, "online")
            -- mqtt_client:subscribe({[topic1]=1,[topic2]=1,[topic3]=1})--多主题订阅
        elseif event == "recv" then
            log.info("mqtt", "downlink", "topic", data, "payload", payload)
            if data == sub_topic_relay then
                gpio.set(RELAY_PIN, tonumber(payload))
                if tonumber(payload) == 1 then
                    pwm.open(PWM_ID, 1000, pwm_duty_cycle)
                else
                    pwm.close(PWM_ID)
                end
                -- mqtt_client:publish(pub_topic_relay_stat, tostring(gpio.get(RELAY_PIN)), 0)
                sys.publish("pending_topic",pub_topic_relay_stat)
            end
            if data == sub_topic_pwm then
                if tonumber(payload) >0 and tonumber(payload)<=100 then
                    pwm_duty_cycle = tonumber(payload)
                    pwm.open(PWM_ID, 1000, pwm_duty_cycle)
                else
                    pwm.close(PWM_ID)
                end
                sys.publish("pending_topic",pub_topic_pwm_stat)
                -- mqtt_client:publish(pub_topic_pwm_stat,tostring(pwm_duty_cycle), 0)
            end
            sys.publish("mqtt_payload", data, payload)
        elseif event == "sent" then
            log.info("mqtt", "sent", "pkgid", data)
        -- elseif event == "disconnect" then
            -- 非自动重连时,按需重启mqttc
            -- mqtt_client:connect()
        end
    end)

    mqttc:will(availability_topic, "offline")
    -- mqttc自动处理重连, 除非自行关闭
    mqttc:connect()
	sys.waitUntil("mqtt_conack")
    while true do
        -- 演示等待其他task发送过来的上报信息
        local ret, topic, data, qos = sys.waitUntil("mqtt_pub", 300000)
        if ret then
            -- 提供关闭本while循环的途径, 不需要可以注释掉
            if topic == "close" then break end
            mqttc:publish(topic, data, qos)
        end
        -- 如果没有其他task上报, 可以写个空等待
        --sys.wait(60000000)
    end
    mqttc:close()
    mqttc = nil
end)

-- 这里演示在另一个task里上报数据, 会定时上报数据,不需要就注释掉
sys.taskInit(function()
	local temp = ""
    local humi = ""
	local qos = 1 -- QOS0不带puback, QOS1是带puback的
    while true do
        sys.wait(60000)
        local h,t,r = sensor.dht1x(DHT_PIN, true) -- GPIO17且校验CRC值
        humi = tostring(h/100)
        temp = tostring(t/100)
        if mqttc and mqttc:ready() then
            mqttc:publish(pub_topic_temp, temp, qos)
            mqttc:publish(pub_topic_humi, humi, qos)
            mqttc:publish(availability_topic, "online")
            log.info("dht11", h/100,t/100,r)--90.1 23.22
            -- pkgid = mqtt:publish(pub_topic,tostring(h/100), qos)
            -- local pkgid = mqttc:publish(topic2, data, qos)
            -- local pkgid = mqttc:publish(topic3, data, qos)
        end
    end
end)

sys.taskInit(function()           -- 用于反馈设备状态
    while true do
        local result, data = sys.waitUntil("pending_topic",1000)
        if result then   --成功接收到系统消息（更新状态）
            if mqttc and mqttc:ready() then
                if data == pub_topic_relay_stat then
                    mqttc:publish(pub_topic_relay_stat, tostring(gpio.get(RELAY_PIN)), 0)
                elseif data == pub_topic_pwm_stat then
                    mqttc:publish(pub_topic_pwm_stat,tostring(pwm_duty_cycle), 0)
                end
            end
        end
    end
end)


sys.taskInit(function()
    while true do
        sys.wait(10000)
        local net_stat = mobile.status()
        log.info("mobile state ", net_stat)
        if net_stat == "UNREGISTER" then
            pio.set(RELAY_PIN, 0)   -- 如果断网，则关闭排风扇
        end
    end
end)

-- 以下是演示与uart结合, 简单的mqtt-uart透传实现,不需要就注释掉
local uart_id = 1
uart.setup(uart_id, 9600)
uart.on(uart_id, "receive", function(id, len)
    local data = ""
    while 1 do
        local tmp = uart.read(uart_id)
        if not tmp or #tmp == 0 then
            break
        end
        data = data .. tmp
    end
    log.info("uart", "uart收到数据长度", #data)
    sys.publish("mqtt_pub", pub_topic, data)
end)
sys.subscribe("mqtt_payload", function(topic, payload)
    log.info("uart", "uart发送数据长度", #payload)
    uart.write(1, payload)
end)


-- 用户代码已结束---------------------------------------------
-- 结尾总是这一句
sys.run()
-- sys.run()之后后面不要加任何语句!!!!!
