/* Owned, static test client: the scratch image contains only this executable. */
#include <arpa/inet.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static void stop(int signal_number) {
    (void)signal_number;
    _exit(0);
}

static int write_all(int descriptor, const char *bytes, size_t length) {
    while (length) {
        ssize_t sent = write(descriptor, bytes, length);
        if (sent < 0 && errno == EINTR) continue;
        if (sent <= 0) return -1;
        bytes += sent;
        length -= (size_t)sent;
    }
    return 0;
}

int main(int count, char **arguments) {
    signal(SIGTERM, stop);
    signal(SIGINT, stop);
    if (count == 2 && strcmp(arguments[1], "hold") == 0) {
        sleep(300);
        return 0;
    }
    if (count == 2 && strcmp(arguments[1], "gateway") == 0) {
        FILE *hosts = fopen("/etc/hosts", "r");
        if (!hosts) return 2;
        char line[512], address[64];
        while (fgets(line, sizeof(line), hosts)) {
            if (strstr(line, "host.docker.internal") && sscanf(line, "%63s", address) == 1) {
                puts(address);
                fclose(hosts);
                return 0;
            }
        }
        fclose(hosts);
        return 2;
    }
    if (count != 3) return 2;
    char *end = NULL;
    errno = 0;
    long port = strtol(arguments[2], &end, 10);
    if (errno || !end || *end || port < 1024 || port > 65535) return 2;
    struct sockaddr_in destination = {.sin_family = AF_INET, .sin_port = htons((unsigned short)port)};
    if (inet_pton(AF_INET, arguments[1], &destination.sin_addr) != 1) return 2;
    unsigned int address = ntohl(destination.sin_addr.s_addr);
    if (!(address >> 24 == 10 || address >> 20 == 0xac1 || address >> 16 == 0xc0a8)) return 2;

    char request[32768];
    size_t used = 0;
    while (used < sizeof(request)) {
        ssize_t received = read(STDIN_FILENO, request + used, sizeof(request) - used);
        if (received < 0 && errno == EINTR) continue;
        if (received < 0) return 3;
        if (!received) break;
        used += (size_t)received;
    }
    if (!used || used == sizeof(request)) return 3;
    int connection = socket(AF_INET, SOCK_STREAM, 0);
    if (connection < 0) return 4;
    struct timeval timeout = {.tv_sec = 60};
    if (setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) ||
        setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) ||
        connect(connection, (struct sockaddr *)&destination, sizeof(destination)) ||
        write_all(connection, request, used)) {
        close(connection);
        return 4;
    }
    /* Keep the socket open after stdin EOF while the model produces its reply. */
    char response[8192];
    int status = 0;
    for (;;) {
        ssize_t received = read(connection, response, sizeof(response));
        if (received < 0 && errno == EINTR) continue;
        if (received < 0) { status = 5; break; }
        if (!received) break;
        if (write_all(STDOUT_FILENO, response, (size_t)received)) { status = 5; break; }
    }
    close(connection);
    return status;
}
