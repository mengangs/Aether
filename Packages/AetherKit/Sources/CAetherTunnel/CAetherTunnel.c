#include "CAetherTunnel.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <resolv.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>

// 内核 ABI（xnu bsd/sys/kern_control.h、bsd/sys/sys_domain.h）。
#define AETHER_AF_SYSTEM 32
#define AETHER_MAX_KCTL_NAME 96

struct aether_ctl_info {
    uint32_t ctl_id;
    char ctl_name[AETHER_MAX_KCTL_NAME];
};

struct aether_sockaddr_ctl {
    uint8_t sc_len;
    uint8_t sc_family;
    uint16_t ss_sysaddr;
    uint32_t sc_id;
    uint32_t sc_unit;
    uint32_t sc_reserved[5];
};

#define AETHER_CTLIOCGINFO _IOWR('N', 3, struct aether_ctl_info)

int aether_find_utun_descriptor(void) {
    struct aether_ctl_info info;
    memset(&info, 0, sizeof(info));
    strncpy(info.ctl_name, "com.apple.net.utun_control", sizeof(info.ctl_name) - 1);
    for (int fd = 0; fd <= 1024; fd++) {
        struct aether_sockaddr_ctl address;
        socklen_t length = sizeof(address);
        memset(&address, 0, sizeof(address));
        if (getpeername(fd, (struct sockaddr *)&address, &length) != 0 || address.sc_family != AETHER_AF_SYSTEM) {
            continue;
        }
        if (info.ctl_id == 0 && ioctl(fd, AETHER_CTLIOCGINFO, &info) != 0) {
            continue;
        }
        if (address.sc_id == info.ctl_id) {
            return fd;
        }
    }
    return -1;
}

int aether_copy_system_dns_servers(char *out, int capacity) {
    if (out == NULL || capacity <= 0) {
        return 0;
    }
    struct __res_state state;
    memset(&state, 0, sizeof(state));
    if (res_ninit(&state) != 0) {
        return 0;
    }
    union res_sockaddr_union servers[16];
    int count = res_getservers(&state, servers, 16);
    int written = 0;
    for (int index = 0; index < count && written < capacity; index++) {
        char *slot = out + (size_t)written * 64;
        const char *text = NULL;
        if (servers[index].sin.sin_family == AF_INET) {
            text = inet_ntop(AF_INET, &servers[index].sin.sin_addr, slot, 64);
        } else if (servers[index].sin6.sin6_family == AF_INET6) {
            text = inet_ntop(AF_INET6, &servers[index].sin6.sin6_addr, slot, 64);
        }
        if (text != NULL) {
            written++;
        }
    }
    res_ndestroy(&state);
    return written;
}
