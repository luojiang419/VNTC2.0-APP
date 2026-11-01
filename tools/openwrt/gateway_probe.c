/* 隔离 LAN 验收工具：UDP 回显、RTSP/RTP H.264 服务及客户端。不安装进插件。 */
#include <arpa/inet.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static void fail(const char *s) { perror(s); exit(1); }
static void check(int good, const char *s) { if (!good) { fprintf(stderr, "%s\n", s); exit(1); } }
static int sendall(int s, const void *data, size_t n) {
    const char *p = data;
    while (n) { ssize_t k = send(s, p, n, 0); if (k < 0 && errno == EINTR) continue; if (k <= 0) return -1; p += k; n -= (size_t)k; }
    return 0;
}
static int readall(int s, void *data, size_t n) {
    char *p = data;
    while (n) { ssize_t k = recv(s, p, n, 0); if (k < 0 && errno == EINTR) continue; if (k <= 0) return -1; p += k; n -= (size_t)k; }
    return 0;
}
static int sock(int udp, const char *ip, int port, int server) {
    check(port > 0 && port <= 65535, "invalid port");
    int s = socket(AF_INET, udp ? SOCK_DGRAM : SOCK_STREAM, 0), one = 1;
    if (s < 0) fail("socket");
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct timeval t = {.tv_sec = 20};
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &t, sizeof(t));
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &t, sizeof(t));
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port)};
    check(inet_pton(AF_INET, ip, &a.sin_addr) == 1, "invalid IP");
    if ((server ? bind(s, (void *)&a, sizeof(a)) : connect(s, (void *)&a, sizeof(a))) < 0) fail("bind/connect");
    if (server && !udp && listen(s, 8)) fail("listen");
    return s;
}
static void udp_server(int port) {
    int s = sock(1, "0.0.0.0", port, 1);
    for (;;) {
        unsigned char b[65536]; struct sockaddr_in a; socklen_t n = sizeof(a);
        ssize_t k = recvfrom(s, b, sizeof(b), 0, (void *)&a, &n);
        if (k > 0 && sendto(s, b, (size_t)k, 0, (void *)&a, n) != k) fail("udp reply");
    }
}
static void udp_client(const char *ip, int port, int count) {
    int s = sock(1, ip, port, 0); FILE *random = fopen("/dev/urandom", "rb");
    check(random && count > 0 && count <= 10000, "udp setup");
    for (int i = 0; i < count; i++) {
        unsigned char b[1300], reply[1400];
        check(fread(b, 1, sizeof(b), random) == sizeof(b), "random");
        check(send(s, b, sizeof(b), 0) == sizeof(b), "udp send");
        ssize_t k = recv(s, reply, sizeof(reply), 0);
        check(k == sizeof(b) && memcmp(b, reply, sizeof(b)) == 0, "udp loss/corruption");
        usleep(1000000);
    }
    fclose(random); close(s); printf("UDP_PASS count=%d bytes=%d\n", count, count * 1300);
}
static int header(int s, char *b, size_t max) {
    size_t n = 0;
    while (n + 1 < max) {
        if (readall(s, b + n, 1)) return -1;
        b[++n] = 0;
        if (n >= 4 && !memcmp(b + n - 4, "\r\n\r\n", 4)) return 0;
    }
    return -1;
}
static void rtp(int s, uint16_t *seq, uint32_t ts, const unsigned char *p, size_t n, int marker) {
    unsigned char h[16] = {'$', 0, 0, 0, 0x80, (unsigned char)(96 | (marker ? 128 : 0)), 0, 0,
                          0, 0, 0, 0, 0x12, 0x34, 0x56, 0x78};
    size_t len = n + 12;
    h[2] = (unsigned char)(len >> 8); h[3] = (unsigned char)len;
    h[6] = (unsigned char)(*seq >> 8); h[7] = (unsigned char)*seq; (*seq)++;
    for (int i = 0; i < 4; i++) h[8 + i] = (unsigned char)(ts >> (24 - 8 * i));
    if (sendall(s, h, sizeof(h)) || sendall(s, p, n)) exit(0);
}
static void stream(int s, const char *path) {
    FILE *f = fopen(path, "rb"); struct stat st;
    check(f && !fstat(fileno(f), &st) && st.st_size < 32 * 1024 * 1024, "fixture file");
    size_t size = (size_t)st.st_size; unsigned char *b = malloc(size);
    check(b && fread(b, 1, size, f) == size, "fixture read"); fclose(f);
    uint16_t seq = 0; uint32_t ts = 0;
    for (size_t pos = 0; pos + 4 < size;) {
        check(!memcmp(b + pos, "\0\0\0\1", 4), "fixture requires canonical Annex B");
        size_t end = pos + 4;
        while (end + 4 <= size && memcmp(b + end, "\0\0\0\1", 4)) end++;
        if (end + 4 > size) end = size;
        const unsigned char *p = b + pos + 4; size_t n = end - pos - 4;
        check(n > 0, "empty NAL"); int type = p[0] & 31, video = type == 1 || type == 5;
        if (n <= 1200) rtp(s, &seq, ts, p, n, video);
        else {
            size_t offset = 1;
            while (offset < n) {
                unsigned char chunk[1200]; size_t k = n - offset;
                if (k > sizeof(chunk) - 2) k = sizeof(chunk) - 2;
                chunk[0] = (p[0] & 0xe0) | 28;
                chunk[1] = (unsigned char)type | (offset == 1 ? 0x80 : 0) | (offset + k == n ? 0x40 : 0);
                memcpy(chunk + 2, p + offset, k);
                rtp(s, &seq, ts, chunk, k + 2, video && offset + k == n); offset += k;
            }
        }
        if (video) { usleep(100000); ts += 9000; }
        pos = end;
    }
    free(b);
}
static void rtsp_serve(int s, const char *path) {
    const char *sdp = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=VNT gateway test\r\nt=0 0\r\na=control:*\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=fmtp:96 packetization-mode=1\r\na=control:trackID=0\r\n";
    char b[4096], response[4096];
    while (!header(s, b, sizeof(b))) {
        char *c = strstr(b, "CSeq:"); int sequence = c ? atoi(c + 5) : 0;
        int describe = !strncmp(b, "DESCRIBE ", 9), setup = !strncmp(b, "SETUP ", 6);
        int play = !strncmp(b, "PLAY ", 5);
        const char *extra = describe ? "Content-Type: application/sdp\r\n" : setup ? "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n" : "";
        int n = snprintf(response, sizeof(response), "RTSP/1.0 200 OK\r\nCSeq: %d\r\nSession: vnt-test\r\n%sContent-Length: %zu\r\n\r\n%s", sequence, extra, describe ? strlen(sdp) : 0, describe ? sdp : "");
        if (sendall(s, response, (size_t)n)) break;
        if (play) { stream(s, path); break; }
    }
}
static void rtsp_server(int port, const char *path) {
    int listener = sock(0, "0.0.0.0", port, 1);
    signal(SIGCHLD, SIG_IGN);
    for (;;) {
        int s = accept(listener, NULL, NULL); if (s < 0) continue;
        pid_t child = fork(); if (child < 0) fail("fork");
        if (!child) { close(listener); rtsp_serve(s, path); close(s); exit(0); }
        close(s);
    }
}
static void rtsp_get(const char *ip, int port, const char *path) {
    int s = sock(0, ip, port, 0); char b[8192];
    const char *verbs[] = {"OPTIONS", "DESCRIBE", "SETUP", "PLAY"};
    for (int i = 0; i < 4; i++) {
        int n = snprintf(b, sizeof(b), "%s rtsp://%s:%d/live%s RTSP/1.0\r\nCSeq: %d\r\nTransport: RTP/AVP/TCP;unicast;interleaved=0-1\r\nSession: vnt-test\r\nAccept: application/sdp\r\n\r\n", verbs[i], ip, port, i == 2 ? "/trackID=0" : "", i + 1);
        check(!sendall(s, b, (size_t)n) && !header(s, b, sizeof(b)), "RTSP handshake");
        check(!strncmp(b, "RTSP/1.0 200 ", 13), "RTSP error");
        char *content = strstr(b, "Content-Length:"); int len = content ? atoi(content + 15) : 0;
        check(len >= 0 && len < (int)sizeof(b), "RTSP body size");
        if (len) check(!readall(s, b, (size_t)len), "SDP read");
    }
    FILE *f = fopen(path, "wb"); check(f != NULL, "output");
    int packets = 0; uint16_t expected = 0;
    for (;;) {
        unsigned char h[4], packet[65536];
        if (readall(s, h, 4)) break;
        size_t len = ((size_t)h[2] << 8) | h[3];
        check(h[0] == '$' && h[1] == 0 && len > 12 && !readall(s, packet, len), "RTP framing");
        uint16_t seq = (uint16_t)((packet[2] << 8) | packet[3]);
        check((packet[0] & 0x3f) == 0 && seq == expected++, "RTP sequence gap"); packets++;
        unsigned char *p = packet + 12; size_t n = len - 12;
        if ((p[0] & 31) == 28) {
            check(n > 2, "FU-A length");
            if (p[1] & 0x80) {
                unsigned char nal = (p[0] & 0xe0) | (p[1] & 31);
                check(fwrite("\0\0\0\1", 1, 4, f) == 4 && fwrite(&nal, 1, 1, f) == 1, "write FU header");
            }
            check(fwrite(p + 2, 1, n - 2, f) == n - 2, "write FU payload");
        } else {
            check(fwrite("\0\0\0\1", 1, 4, f) == 4 && fwrite(p, 1, n, f) == n, "write NAL");
        }
    }
    check(packets >= 100 && !fclose(f), "incomplete stream"); close(s);
    printf("RTSP_PASS rtp_packets=%d\n", packets);
}
int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    if (argc == 3 && !strcmp(argv[1], "udp-server")) udp_server(atoi(argv[2]));
    else if (argc == 5 && !strcmp(argv[1], "udp-client")) udp_client(argv[2], atoi(argv[3]), atoi(argv[4]));
    else if (argc == 4 && !strcmp(argv[1], "rtsp-server")) rtsp_server(atoi(argv[2]), argv[3]);
    else if (argc == 5 && !strcmp(argv[1], "rtsp-get")) rtsp_get(argv[2], atoi(argv[3]), argv[4]);
    else return 2;
    return 0;
}
