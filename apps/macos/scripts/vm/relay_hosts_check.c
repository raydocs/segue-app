/* Prints one IPv4 for argv[1]. Used to prove relay_hosts.dylib is live. */

#include <arpa/inet.h>
#include <netdb.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    struct addrinfo hints;
    struct addrinfo *res = NULL;
    struct addrinfo *it;
    const char *host;

    if (argc < 2) {
        return 2;
    }
    host = argv[1];
    memset(&hints, 0, sizeof(hints));
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, "80", &hints, &res) != 0) {
        return 1;
    }
    for (it = res; it != NULL; it = it->ai_next) {
        char buf[64];
        if (it->ai_family != AF_INET) {
            continue;
        }
        inet_ntop(AF_INET, &((struct sockaddr_in *)it->ai_addr)->sin_addr, buf,
                  sizeof(buf));
        printf("%s\n", buf);
        freeaddrinfo(res);
        return 0;
    }
    freeaddrinfo(res);
    return 1;
}
