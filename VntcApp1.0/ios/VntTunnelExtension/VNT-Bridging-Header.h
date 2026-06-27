//
//  VNT-Bridging-Header.h
//  VNT iOS/tvOS Bridging Header
//
//  定义Rust FFI函数的C接口
//

#ifndef VNT_Bridging_Header_h
#define VNT_Bridging_Header_h

#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>

#ifndef AF_SYSTEM
#define AF_SYSTEM 32
#endif

#ifndef MAX_KCTL_NAME
#define MAX_KCTL_NAME 96
#endif

struct ctl_info {
    u_int32_t ctl_id;
    char ctl_name[MAX_KCTL_NAME];
};

struct sockaddr_ctl {
    u_char sc_len;
    u_char sc_family;
    u_int16_t ss_sysaddr;
    u_int32_t sc_id;
    u_int32_t sc_unit;
    u_int32_t sc_reserved[5];
};

#ifndef CTLIOCGINFO
#define CTLIOCGINFO _IOWR('N', 3, struct ctl_info)
#endif

#ifdef __cplusplus
extern "C" {
#endif

static inline int32_t vnt_ios_find_tunnel_fd(void) {
    struct ctl_info ctlInfo;
    memset(&ctlInfo, 0, sizeof(ctlInfo));
    strncpy(ctlInfo.ctl_name, "com.apple.net.utun_control", sizeof(ctlInfo.ctl_name) - 1);

    for (int32_t fd = 0; fd <= 1024; fd++) {
        struct sockaddr_ctl addr;
        socklen_t len = sizeof(addr);
        memset(&addr, 0, sizeof(addr));

        if (getpeername(fd, (struct sockaddr *)&addr, &len) != 0 || addr.sc_family != AF_SYSTEM) {
            continue;
        }

        if (ctlInfo.ctl_id == 0 && ioctl(fd, CTLIOCGINFO, &ctlInfo) != 0) {
            continue;
        }

        if (addr.sc_id == ctlInfo.ctl_id) {
            return fd;
        }
    }

    return -1;
}

/// 初始化iOS日志系统
/// @param log_dir 日志目录路径（C字符串）
/// @return 0=成功, 负数=错误码
int32_t vnt_ios_init_log(const char* log_dir);

/// 从文件描述符启动VNT隧道（iOS/tvOS）
/// @param fd 从NEPacketTunnelProvider获取的文件描述符
/// @param server_addr VNT服务器地址（C字符串）
/// @param token 认证令牌（C字符串）
/// @param device_name 设备名称（C字符串）
/// @param mtu MTU值
/// @return 0表示成功，负数表示错误码
int32_t vnt_ios_start_tunnel(int32_t fd, const char* server_addr, const char* token, const char* device_name, int32_t mtu);

/// 停止VNT隧道
void vnt_ios_stop_tunnel(void);

/// 获取VNT连接状态
/// @return 0=离线, 1=在线, -1=无实例
int32_t vnt_ios_get_status(void);

/// 设置日志级别
/// @param level 日志级别 (0=Error, 1=Warn, 2=Info, 3=Debug, 4=Trace)
void vnt_ios_set_log_level(int32_t level);

#ifdef __cplusplus
}
#endif

#endif /* VNT_Bridging_Header_h */
