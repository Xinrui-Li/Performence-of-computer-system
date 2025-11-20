# Simulation Topology
#              n1                  n5
#               \                  /
#   4000Mb,500ms \   1000Mb,50ms  / 4000Mb,500ms
#              n3 --------------- n4
#   4000Mb,800ms /                \ 4000Mb,800ms
#               /                  \
#             n2                   n6 

set ns [new Simulator]

# --- 1. 读取随机种子（从环境变量 SEED 获取，默认用当前时间）---
set seed [expr {[info exists ::env(SEED)] ? $::env(SEED) : [clock seconds]}]
puts "Current random seed: $seed"  ;# 打印种子，验证有效性

# --- 2. 读取瓶颈链路带宽（从环境变量 BW 获取，默认 1000Mb）---
set bw [expr {[info exists ::env(BW)] ? $::env(BW) : "1000Mb"}]

$ns color 1 Blue
$ns color 2 Red

# 注意：文件名保持与算法一致（reno.nam、renoTrace.tr）
set namfile [open reno.nam w]
$ns namtrace-all $namfile
set tracefile1 [open renoTrace.tr w]
$ns trace-all $tracefile1

proc finish {} {
    global ns namfile tracefile1
    $ns flush-trace
    close $namfile
    close $tracefile1  ;# 关闭跟踪文件，避免资源泄露
    exit 0
}

set n1 [$ns node]
set n2 [$ns node]
set n3 [$ns node]
set n4 [$ns node]
set n5 [$ns node]
set n6 [$ns node]

# --- 3. 基于种子随机化拓扑参数 ---
# 瓶颈链路延迟：50ms ±20ms（30~70ms 随机）
set bottleneck_delay [expr {50 + ($seed % 41) - 20}]
# 队列长度：10 ±5（5~15 随机）
set queue_limit [expr {10 + ($seed % 11) - 5}]

$ns duplex-link $n1 $n3 4000Mb 500ms RED
$ns duplex-link $n2 $n3 4000Mb 800ms RED 
# 应用随机化的瓶颈延迟
$ns duplex-link $n3 $n4 $bw ${bottleneck_delay}ms RED
$ns duplex-link $n4 $n5 4000Mb 500ms RED
$ns duplex-link $n4 $n6 4000Mb 800ms RED

# 应用随机化的队列长度
$ns queue-limit $n3 $n4 $queue_limit
$ns queue-limit $n4 $n3 $queue_limit

$ns duplex-link-op $n1 $n3 orient right-down
$ns duplex-link-op $n2 $n3 orient right-up
$ns duplex-link-op $n3 $n4 orient right
$ns duplex-link-op $n4 $n5 orient right-up
$ns duplex-link-op $n4 $n6 orient right-down

# --- 4. 随机化 TCP Reno 参数（source1）---
set source1 [new Agent/TCP/Reno]
$source1 set class_ 2
$source1 set ttl_ 64
# 初始窗口：500~999 随机
$source1 set window_ [expr {500 + ($seed % 500)}]
$source1 set packet_size_ 1000
# 重传超时（RTO）：100~299ms 随机
$source1 set rto_ [expr {100 + ($seed % 200)}]

$ns attach-agent $n1 $source1
set sink1 [new Agent/TCPSink/Sack1]  ;# 用 Sack1 提高兼容性
$ns attach-agent $n5 $sink1
$ns connect $source1 $sink1
$source1 set fid_ 1

# --- 5. 随机化 TCP Reno 参数（source2，种子偏移避免同步）---
set source2 [new Agent/TCP/Reno]
$source2 set class_ 1
$source2 set ttl_ 64
# 初始窗口：种子 +100 偏移，保证与 source1 不同
$source2 set window_ [expr {500 + (($seed + 100) % 500)}]
$source2 set packet_size_ 1000
# RTO：种子 +100 偏移
$source2 set rto_ [expr {100 + (($seed + 100) % 200)}]

$ns attach-agent $n2 $source2
set sink2 [new Agent/TCPSink/Sack1]
$ns attach-agent $n6 $sink2
$ns connect $source2 $sink2
$source2 set fid_ 2

# 跟踪 TCP 关键变量（cwnd、ssthresh 等）
$source1 attach $tracefile1
$source1 tracevar cwnd_ 
$source1 tracevar ssthresh_
$source1 tracevar ack_
$source1 tracevar maxseq_
$source1 tracevar rtt_

$source2 attach $tracefile1
$source2 tracevar cwnd_ 
$source2 tracevar ssthresh_
$source2 tracevar ack_
$source2 tracevar maxseq_
$source2 tracevar rtt_

set myftp1 [new Application/FTP]
$myftp1 attach-agent $source1

set myftp2 [new Application/FTP]
$myftp2 attach-agent $source2

# --- 6. 随机化流启动时间（避免同时启动）---
# source1 启动时间：0.1~1.0s 随机
set start1 [expr {0.1 + ($seed % 10) / 10.0}]
# source2 启动时间：种子 +50 偏移，与 source1 错开
set start2 [expr {0.1 + (($seed + 50) % 10) / 10.0}]

$ns at $start1 "$myftp1 start"
$ns at $start2 "$myftp2 start"

$ns at 100.0 "finish"

$ns run
