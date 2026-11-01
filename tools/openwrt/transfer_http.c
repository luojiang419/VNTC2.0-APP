/* 仅供隔离 VM 数据面验收使用，不随 VNT 插件安装。 */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

static int send_all(int fd, const char *buffer, size_t size) {
    while (size) {
        ssize_t sent = send(fd, buffer, size, 0);
        if (sent < 0 && errno == EINTR) continue;
        if (sent <= 0) return -1;
        buffer += sent;
        size -= (size_t)sent;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 3 && argc != 4) return 2;
    unsigned int delay = argc == 4 ? (unsigned int)strtoul(argv[3], NULL, 10) : 0;
    if (delay > 1000000) return 2;
    char *end = NULL;
    long port = strtol(argv[1], &end, 10);
    if (!end || *end || port < 1 || port > 65535) return 2;
    signal(SIGPIPE, SIG_IGN);
    int server = socket(AF_INET, SOCK_STREAM, 0), reuse = 1;
    if (server < 0) return 3;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in addr = {.sin_family = AF_INET,
        .sin_port = htons((unsigned short)port), .sin_addr.s_addr = htonl(INADDR_ANY)};
    if (bind(server, (struct sockaddr *)&addr, sizeof(addr)) || listen(server, 4)) return 4;
    for (;;) {
        int client = accept(server, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) continue;
            return 5;
        }
        struct timeval timeout = {.tv_sec = 30};
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        char request[2048] = {0};
        size_t used = 0;
        while (used < sizeof(request) - 1 && !strstr(request, "\r\n\r\n")) {
            ssize_t got = recv(client, request + used, sizeof(request) - 1 - used, 0);
            if (got <= 0) break;
            used += (size_t)got;
        }
        int file = -1;
        struct stat info;
        if (strncmp(request, "GET /payload.bin ", 17) ||
            (file = open(argv[2], O_RDONLY)) < 0 || fstat(file, &info)) {
            const char *error = "HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n";
            send_all(client, error, strlen(error));
        } else {
            char header[256], buffer[16384];
            int length = snprintf(header, sizeof(header),
                "HTTP/1.0 200 OK\r\nContent-Length: %lld\r\n"
                "Content-Type: application/octet-stream\r\nConnection: close\r\n\r\n",
                (long long)info.st_size);
            if (send_all(client, header, (size_t)length) == 0) {
                ssize_t got;
                while ((got = read(file, buffer, sizeof(buffer))) > 0) {
                    if (send_all(client, buffer, (size_t)got)) break;
                    if (delay) usleep(delay);
                }
            }
        }
        if (file >= 0) close(file);
        close(client);
    }
}
