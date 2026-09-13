// OppodsRfcommHelper — 由 OppoPodsManager (C#) 拉起的蓝牙桥接进程。
//
// 背景：macOS 26/27 的 IOBluetooth RFCOMM API 坏了（sync 版成功也返回错误码、async 版
// 回调永不触发、通道对象始终 not-open），而蓝牙也没有 Linux 风格的 AF_BLUETOOTH socket。
// 因此这里提供两条后端：
//   1. GATT（CoreBluetooth，melody 私有服务 0000079A-…）——macOS 26/27 上的首选；
//   2. RFCOMM（IOBluetooth，HeyMelody SPP 通道）——老系统兜底。
// 两条后端对上层暴露相同的字节流桥接协议，帧编解码由 C# 侧按模式选择。
//
// 用法：OppodsRfcommHelper <MAC>       （如 88:92:CC:E5:BD:F3）
//
// 协议（双向均为 4 字节小端长度 + payload，payload[0] 为 opcode）：
//   stdin  0x01 + 数据     写入当前链路（RFCOMM 通道或 GATT TX 特征）
//   stdin  0x02            放弃当前链路，尝试下一个候选
//   stdout 0x01 + 数据     链路收到的原始字节
//   stdout 0x81 mode id    链路就绪：mode=1 RFCOMM(id=通道号)、mode=2 GATT
//   stdout 0x83            所有后端候选全部尝试完毕（随后 exit 2）
//   stdout 0x84            链路意外关闭（随后 exit 3）
//   stderr：人类可读诊断日志

#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <stdio.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <signal.h>
#import <errno.h>
#import <fcntl.h>

// ---------------- 桥接公共部分 ----------------

static FILE *gOut = NULL;
static NSLock *gOutLock = nil;

static void WriteFramed(uint8_t opcode, const uint8_t *data, uint32_t len)
{
    [gOutLock lock];
    uint32_t total = 1 + len; // 长度含 opcode 本身，与 C# 端 ReadExactly 的约定一致
    uint8_t hdr[4] = { (uint8_t)(total & 0xFF), (uint8_t)((total >> 8) & 0xFF),
                       (uint8_t)((total >> 16) & 0xFF), (uint8_t)((total >> 24) & 0xFF) };
    fwrite(hdr, 1, 4, gOut);
    fwrite(&opcode, 1, 1, gOut);
    if (len > 0 && data) fwrite(data, 1, len, gOut);
    fflush(gOut);
    [gOutLock unlock];
}

static void Log_(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void Log_(NSString *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "[helper] %s\n", s.UTF8String);
    fflush(stderr);
}

static ssize_t ReadExact(int fd, uint8_t *buf, size_t n)
{
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, buf + got, n - got);
        if (r <= 0) return -1;
        got += (size_t)r;
    }
    return (ssize_t)got;
}

// ---------------- 后端状态 ----------------

static volatile int gMode = 0;            // 1=RFCOMM 2=GATT
static volatile BOOL gLinkAlive = NO;
static volatile BOOL gNextRequested = NO;
static volatile BOOL gSuppressClosed = NO;

static void ReportClosed(void)
{
    if (gSuppressClosed) { gSuppressClosed = NO; Log_(@"closed (suppressed)"); return; }
    WriteFramed(0x84, NULL, 0);
    CFRunLoopStop(CFRunLoopGetMain());
}

// ---------------- GATT 后端（CoreBluetooth） ----------------

static CBUUID *MelodyUuid(void)
{
    return [CBUUID UUIDWithString:@"0000079A-D102-11E1-9B23-00025B00A5A5"];
}

@interface GattDelegate : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@property (retain) CBPeripheral *peripheral;
@property (retain) CBCharacteristic *txChar;
@property (retain) CBCharacteristic *rxChar;
@end

@implementation GattDelegate
- (void)centralManagerDidUpdateState:(CBCentralManager *)central
{
    Log_(@"CB state=%ld", (long)central.state);
}

- (void)centralManager:(CBCentralManager *)central
    didDiscoverPeripheral:(CBPeripheral *)peripheral
        advertisementData:(NSDictionary *)adv
                     RSSI:(NSNumber *)rssi
{
    // melody 服务过滤扫描：直接连；全量扫描兜底：只认品牌名，避免连到邻居设备
    NSString *name = peripheral.name ?: @"";
    BOOL branded = NO;
    for (NSString *b in @[@"OPPO", @"OnePlus", @"realme", @"Enco"])
        if ([name rangeOfString:b options:NSCaseInsensitiveSearch].location != NSNotFound) branded = YES;
    BOOL viaService = [adv[CBAdvertisementDataServiceUUIDsKey] containsObject:MelodyUuid()] ||
                      [adv[CBAdvertisementDataOverflowServiceUUIDsKey] containsObject:MelodyUuid()];
    Log_(@"discovered %@ rssi=%@ svcHit=%d branded=%d", name ?: @"(noname)", rssi, viaService, branded);
    if (self.peripheral == nil && (viaService || branded)) {
        self.peripheral = peripheral;
        [central stopScan];
        [central connectPeripheral:peripheral options:nil];
        Log_(@"connecting to %@ …", name ?: @"?");
    }
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral
{
    Log_(@"connected, discovering services…");
    [peripheral setDelegate:self];
    [peripheral discoverServices:@[MelodyUuid()]];
}

- (void)centralManager:(CBCentralManager *)central
       didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error
{
    Log_(@"connect failed: %@", error.localizedDescription);
    self.peripheral = nil;
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error
{
    for (CBService *svc in peripheral.services) {
        Log_(@"service %@", svc.UUID);
        if ([svc.UUID isEqual:MelodyUuid()])
            [peripheral discoverCharacteristics:@[
                [CBUUID UUIDWithString:@"0000079B-D102-11E1-9B23-00025B00A5A5"],
                [CBUUID UUIDWithString:@"0000079C-D102-11E1-9B23-00025B00A5A5"],
            ] forService:svc];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
    didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error
{
    for (CBCharacteristic *c in service.characteristics) {
        Log_(@"char %@ props=0x%lx", c.UUID, (unsigned long)c.properties);
        if ([c.UUID isEqual:[CBUUID UUIDWithString:@"0000079B-D102-11E1-9B23-00025B00A5A5"]])
            self.txChar = c;
        if ([c.UUID isEqual:[CBUUID UUIDWithString:@"0000079C-D102-11E1-9B23-00025B00A5A5"]])
            self.rxChar = c;
    }
    if (self.txChar && self.rxChar)
        [peripheral setNotifyValue:YES forCharacteristic:self.rxChar];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error
{
    if (error) { Log_(@"notify error: %@", error.localizedDescription); return; }
    if (self.txChar && self.rxChar && characteristic.isNotifying) {
        gMode = 2;
        gLinkAlive = YES;
        uint8_t msg[2] = { 2, 0 };
        WriteFramed(0x81, msg, 2);
        Log_(@"GATT link ready");
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
    didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error
{
    if (error) return;
    NSData *d = characteristic.value;
    if (d.length > 0)
        WriteFramed(0x01, (const uint8_t *)d.bytes, (uint32_t)d.length);
}

- (void)peripheral:(CBPeripheral *)peripheral didDisconnectPeripheral:(NSError *)error
{
    Log_(@"peripheral disconnected");
    if (gMode == 2 && gLinkAlive) {
        gLinkAlive = NO;
        ReportClosed();
    }
    self.peripheral = nil; self.txChar = nil; self.rxChar = nil;
}
@end

static GattDelegate *gGatt = nil;
static CBCentralManager *gCentral = nil;

// 驱动 GATT 状态机直到就绪 / 失败 / 超时。返回 YES 表示链路可用。
static BOOL TryGatt(NSString *mac)
{
    if (!gGatt) gGatt = [GattDelegate new];
    gGatt.peripheral = nil; gGatt.txChar = nil; gGatt.rxChar = nil;
    if (!gCentral)
        gCentral = [[CBCentralManager alloc] initWithDelegate:gGatt queue:dispatch_get_main_queue()];

    // 等蓝牙上电
    NSDate *dl = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while (gCentral.state != CBManagerStatePoweredOn &&
           [dl compare:[NSDate date]] == NSOrderedDescending) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    if (gCentral.state != CBManagerStatePoweredOn) { Log_(@"CB not powered"); return NO; }

    // 先按 melody 服务过滤扫描；扫不到再全量扫描按品牌名匹配
    // （Free4 双设备槽位占满时不广播，GATT 通常 8 秒内落空，预算不宜过长）
    CBUUID *melody = MelodyUuid();
    [gCentral scanForPeripheralsWithServices:@[melody] options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
    dl = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while (gGatt.peripheral == nil && [dl compare:[NSDate date]] == NSOrderedDescending) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    if (gGatt.peripheral == nil) {
        Log_(@"no adv with melody svc, fallback brand-name scan");
        [gCentral scanForPeripheralsWithServices:nil options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @YES}];
        dl = [NSDate dateWithTimeIntervalSinceNow:3.0];
        while (gGatt.peripheral == nil && [dl compare:[NSDate date]] == NSOrderedDescending) {
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        }
    }
    [gCentral stopScan];
    if (gGatt.peripheral == nil) { Log_(@"GATT: no candidate found"); return NO; }

    // 等连接 + 服务发现 + 订阅完成（didUpdateNotificationState 里发 0x81）
    dl = [NSDate dateWithTimeIntervalSinceNow:12.0];
    while (!gLinkAlive && [dl compare:[NSDate date]] == NSOrderedDescending) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        if (gGatt.peripheral == nil) break; // 连接失败
    }
    return gLinkAlive;
}

// ---------------- RFCOMM 后端（IOBluetooth，老系统兜底） ----------------

static IOBluetoothRFCOMMChannel *gChannel = nil;
static volatile BOOL gChannelAlive = NO;
// async 打开的回执状态
static volatile BOOL gOpenDone = NO;
static volatile IOReturn gOpenStatus = 0;
static IOBluetoothRFCOMMChannel *gOpenChannel = nil;

@interface ChanDelegate : NSObject <IOBluetoothRFCOMMChannelDelegate>
@end

@implementation ChanDelegate
- (void)rfcommChannelOpenComplete:(IOBluetoothRFCOMMChannel *)ch status:(IOReturn)status
{
    Log_(@"openComplete status=0x%x", status);
    gOpenStatus = status;
    gOpenChannel = ch;
    gOpenDone = YES;
}
- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)ch data:(void *)data length:(size_t)length
{
    if (length > 0)
        WriteFramed(0x01, (const uint8_t *)data, (uint32_t)length);
}
- (void)rfcommChannelWriteComplete:(IOBluetoothRFCOMMChannel *)ch refcon:(void *)refcon status:(IOReturn)status
{
    Log_(@"writeComplete status=0x%x", status);
}
- (void)rfcommChannelControlSignalsChanged:(IOBluetoothRFCOMMChannel *)ch
{
}
- (void)rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)ch
{
    Log_(@"rfcomm channel closed");
    gChannelAlive = NO;
    if (gMode == 1) ReportClosed();
}
@end

static BOOL ChannelUsable(IOBluetoothRFCOMMChannel *ch, NSTimeInterval seconds)
{
    // isOpen 由 blued 侧维护；sync 版"成功也返回错误码"（GalaxyBudsClient 同款踩坑），
    // 返回值不可信，只能轮询 isOpen 实证。
    NSDate *dl = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([dl compare:[NSDate date]] == NSOrderedDescending) {
        if (ch.isOpen) return YES;
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    return ch.isOpen;
}

static BOOL FinalizeOpen(BluetoothRFCOMMChannelID chID, IOBluetoothRFCOMMChannel *ch,
                         IOReturn ret, BOOL done, BOOL confirmed)
{
    if (ch == nil) return NO;
    if (done && gOpenStatus != kIOReturnSuccess) { gSuppressClosed = YES; [ch closeChannel]; return NO; }
    if (ChannelUsable(ch, confirmed ? 3.0 : 0.5)) {
        gChannel = ch;
        gChannelAlive = YES;
        uint8_t msg[2] = { 1, chID };
        WriteFramed(0x81, msg, 2);
        Log_(@"opened ch=%u (ret=0x%x done=%d, isOpen confirmed)", chID, ret, done);
        return YES;
    }
    Log_(@"open ch=%u never became isOpen (ret=0x%x)", chID, ret);
    gSuppressClosed = YES;
    [ch closeChannel];
    return NO;
}

static BOOL TryOpen(IOBluetoothDevice *dev, BluetoothRFCOMMChannelID chID, ChanDelegate *dlg)
{
    // 先试 sync：返回值不可信，以 isOpen 轮询为准
    __autoreleasing IOBluetoothRFCOMMChannel *ch = nil;
    IOReturn r = [dev openRFCOMMChannelSync:&ch withChannelID:chID delegate:dlg];
    if (FinalizeOpen(chID, ch, r, YES, YES)) return YES;

    // 再试 async + 回调；回调不来同样轮询 isOpen
    gOpenDone = NO; gOpenStatus = 0; gOpenChannel = nil;
    r = [dev openRFCOMMChannelAsync:&ch withChannelID:chID delegate:dlg];
    if (r != kIOReturnSuccess) {
        Log_(@"async open call ch=%u failed 0x%x", chID, r);
        return NO;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while (!gOpenDone && [deadline compare:[NSDate date]] == NSOrderedDescending) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        if (ch && ch.isOpen) break;
    }
    if (gOpenDone && gOpenStatus != kIOReturnSuccess) {
        Log_(@"open ch=%u rejected status=0x%x", chID, gOpenStatus);
        if (ch) { gSuppressClosed = YES; [ch closeChannel]; }
        return NO;
    }
    if (FinalizeOpen(chID, ch, r, gOpenDone, YES)) return YES;
    return NO;
}

// ---------------- stdin 命令处理 ----------------

// stdin 曾用管道，但在 macOS 27 + .NET 10 组合下出现"App 写入永远不到达"的怪症
// （内核管道配对正确、cat 独立验证正常）。命令通道改走 127.0.0.1 TCP 环回：
// helper 监听随机端口，把 PORT=xxx 打到 stderr，由 C# 解析后连接。
// 协议：4 字节小端长度 + payload，payload[0] 为 opcode：
//   0x01 + 数据  写入当前链路；0x02 放弃当前链路换下一个候选
#import <sys/socket.h>
#import <arpa/inet.h>
#import <netinet/in.h>

static int gCmdFd = -1;
static int gListenFd = -1;
static int gListenPort = 0;

static void OnSigTerm(int sig)
{
    (void)sig;
    // 进程退出即关 fd，blued 释放 RFCOMM 会话，避免占死耳机唯一的 SPP 服务
    _exit(0);
}

static ssize_t ReadFull(int fd, uint8_t *buf, size_t n)
{
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, buf + got, n - got);
        if (r <= 0) return -1;
        got += (size_t)r;
    }
    return (ssize_t)got;
}

static void HandleCmd(void)
{
    // 诊断：确认 fd 身份与标志位
    {
        struct sockaddr_in peer;
        socklen_t pl = sizeof(peer);
        if (getpeername(gCmdFd, (struct sockaddr *)&peer, &pl) == 0)
            Log_(@"cmd fd=%d peer=%s:%d flags=0x%x", gCmdFd, inet_ntoa(peer.sin_addr), ntohs(peer.sin_port),
                 fcntl(gCmdFd, F_GETFL));
        else
            Log_(@"cmd fd=%d getpeername failed errno=%d", gCmdFd, errno);
    }
    uint8_t hdr[4];
    ssize_t got = ReadFull(gCmdFd, hdr, 4);
    Log_(@"ReadFull hdr got=%zd [%02x %02x %02x %02x]", got, hdr[0], hdr[1], hdr[2], hdr[3]);
    if (got < 0) { Log_(@"cmd EOF"); exit(0); }
    uint32_t len = hdr[0] | (hdr[1] << 8) | (hdr[2] << 16) | ((uint32_t)hdr[3] << 24);
    if (len == 0 || len > 8192) { Log_(@"bad cmd len %u", len); return; }
    uint8_t *buf = (uint8_t *)malloc(len);
    if (!buf) exit(1);
    if (ReadFull(gCmdFd, buf, len) < 0) { free(buf); Log_(@"cmd EOF2"); exit(0); }

    if (buf[0] == 0x01) {
        // RFCOMM 分支用 gChannelAlive（TryOpen/FinalizeOpen 维护）；
        // GATT 分支用 gLinkAlive（didUpdateNotificationState 维护）
        if (gChannelAlive && gMode == 1 && gChannel) {
            Log_(@"cmd data len=%u isOpen=%d", len - 1, (int)gChannel.isOpen);
            uint32_t off = 1;
            while (off < len && gChannelAlive) {
                uint32_t chunk = len - off;
                if (chunk > 512) chunk = 512;
                IOReturn r = [gChannel writeSync:(void *)(buf + off) length:(BluetoothRFCOMMMTU)chunk];
                Log_(@"writeSync len=%u ret=0x%x", chunk, r);
                if (r != kIOReturnSuccess) Log_(@"writeSync err 0x%x", r);
                off += chunk;
            }
        } else if (gLinkAlive && gMode == 2 && gGatt.txChar) {
            NSData *d = [NSData dataWithBytes:buf + 1 length:len - 1];
            CBCharacteristicWriteType t =
                (gGatt.txChar.properties & CBCharacteristicPropertyWriteWithoutResponse)
                    ? CBCharacteristicWriteWithoutResponse : CBCharacteristicWriteWithResponse;
            [gGatt.peripheral writeValue:d forCharacteristic:gGatt.txChar type:t];
        }
    } else if (buf[0] == 0x02) {
        gNextRequested = YES;
    }
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: %s <MAC>\n", argv[0]); return 1; }
        gOut = stdout;
        gOutLock = [NSLock new];
        NSString *mac = @(argv[1]);

        // 孤儿保护：父进程（App）退出后立即自杀，防止泄漏持有 RFCOMM 会话
        // 阻塞耳机唯一的 SPP 服务通道
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *) {
            if (getppid() == 1) {
                Log_(@"orphaned, exiting");
                if (gChannelAlive && gChannel) [gChannel closeChannel];
                exit(0);
            }
        }];
        signal(SIGTERM, OnSigTerm);

        // 命令通道：127.0.0.1 TCP，端口在 main 里同步创建并立刻打到 stderr
        // （曾出现 GCD 分派/进程冷启动延迟 10s+ 导致 C# 端口等待超时）
        {
            int lfd = socket(AF_INET, SOCK_STREAM, 0);
            if (lfd < 0) { Log_(@"socket failed"); return 1; }
            struct sockaddr_in a;
            memset(&a, 0, sizeof(a));
            a.sin_family = AF_INET;
            a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            a.sin_port = 0;
            if (bind(lfd, (struct sockaddr *)&a, sizeof(a)) < 0) { Log_(@"bind failed"); return 1; }
            if (listen(lfd, 1) < 0) { Log_(@"listen failed"); return 1; }
            socklen_t sl = sizeof(a);
            getsockname(lfd, (struct sockaddr *)&a, &sl);
            int port = ntohs(a.sin_port);
            Log_(@"PORT=%d", port);
            gListenFd = lfd;
            gListenPort = port;
        }

        // accept 放后台线程（阻塞等待 C# 连接），随后处理命令
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            gCmdFd = accept(gListenFd, NULL, NULL);
            if (gCmdFd < 0) { Log_(@"accept failed"); return; }
            Log_(@"cmd channel connected");
            while (true) HandleCmd();
        });

        // ---- Phase 1: GATT（macOS 26/27 上 RFCOMM API 已坏，优先走 BLE melody 服务）----
        if (TryGatt(mac)) {
            NSDate *tick = [NSDate dateWithTimeIntervalSinceNow:0.2];
            while (true) {
                [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:tick];
                tick = [NSDate dateWithTimeIntervalSinceNow:0.2];
                if (gNextRequested) {
                    gNextRequested = NO;
                    gLinkAlive = NO;
                    gSuppressClosed = YES;
                    if (gGatt.peripheral) [gCentral cancelPeripheralConnection:gGatt.peripheral];
                    gGatt.peripheral = nil; gGatt.txChar = nil; gGatt.rxChar = nil;
                    if (TryGatt(mac)) continue;
                    WriteFramed(0x83, NULL, 0);
                    return 2;
                }
            }
        }

        // ---- Phase 2: RFCOMM（IOBluetooth，老系统兜底）----
        Log_(@"GATT failed, falling back to RFCOMM");
        IOBluetoothDevice *dev = [IOBluetoothDevice deviceWithAddressString:mac];
        if (!dev) { Log_(@"device %@ not found in IOBluetooth", mac); return 1; }
        Log_(@"device: %@ connected=%d", dev.name ?: @"?", (int)dev.isConnected);

        if ([[dev services] count] == 0) {
            Log_(@"no cached SDP records, querying...");
            [dev performSDPQuery:nil];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
            while ([[dev services] count] == 0 && [deadline compare:[NSDate date]] == NSOrderedDescending) {
                [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            }
            Log_(@"SDP query done, records=%lu", (unsigned long)[[dev services] count]);
        }

        NSMutableArray<NSNumber *> *candidates = [NSMutableArray array];
        for (NSString *u in @[@"00001107-D102-11E1-9B23-00025B00A5A5",
                              @"0000079A-D102-11E1-9B23-00025B00A5A5"]) {
            uint8_t bytes[16];
            NSString *hex = [u stringByReplacingOccurrencesOfString:@"-" withString:@""];
            for (int i = 0; i < 16; i++) {
                unsigned v = 0;
                [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i * 2, 2)]] scanHexInt:&v];
                bytes[i] = (uint8_t)v;
            }
            IOBluetoothSDPUUID *uuid = [IOBluetoothSDPUUID uuidWithBytes:bytes length:16];
            IOBluetoothSDPServiceRecord *rec = uuid ? [dev getServiceRecordForUUID:uuid] : nil;
            if (rec) {
                BluetoothRFCOMMChannelID chID = 0;
                if ([rec getRFCOMMChannelID:&chID] == kIOReturnSuccess) {
                    Log_(@"SDP %@ -> ch=%u", u, chID);
                    [candidates addObject:@(chID)];
                }
            } else {
                Log_(@"SDP %@ -> no record", u);
            }
        }
        for (int c = 1; c <= 30; c++) [candidates addObject:@(c)];

        ChanDelegate *dlg = [ChanDelegate new];
        gMode = 1;
        __block NSUInteger idx = 0;
        BOOL opened = NO;
        while (idx < candidates.count) {
            if (TryOpen(dev, (BluetoothRFCOMMChannelID)candidates[idx].unsignedCharValue, dlg)) { opened = YES; break; }
            idx++;
        }
        if (!opened) {
            WriteFramed(0x83, NULL, 0);
            Log_(@"no RFCOMM channel available");
            return 2;
        }

        NSDate *tick = [NSDate dateWithTimeIntervalSinceNow:0.2];
        while (true) {
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:tick];
            tick = [NSDate dateWithTimeIntervalSinceNow:0.2];
            if (gNextRequested) {
                gNextRequested = NO;
                gChannelAlive = NO;
                idx++;
                gSuppressClosed = YES;
                [gChannel closeChannel];
                gChannel = nil;
                BOOL next = NO;
                while (idx < candidates.count) {
                    if (TryOpen(dev, (BluetoothRFCOMMChannelID)candidates[idx].unsignedCharValue, dlg)) { next = YES; break; }
                    idx++;
                }
                if (!next) { WriteFramed(0x83, NULL, 0); return 2; }
            }
        }
    }
    return 0;
}
