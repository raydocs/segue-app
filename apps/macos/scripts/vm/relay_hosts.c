/* Lab-only getaddrinfo interpose for segue-relay.
 *
 * The matrix and the relay share one system resolver. /etc/resolver for the
 * fixture suffix points at the kernel, which answers that name with a
 * 198.18.0.0/15 fake-IP. The relay SSRF-blocks that range (dev_allow_cidrs
 * is only the fixture host), so the home SOCKS dial never starts.
 * /etc/hosts is the wrong place for the real address: the client's own
 * resolver would return it and skip the tunnel. The fixture server's
 * dns.hosts map is never consulted: the relay resolves to an IP before
 * the home SOCKS CONNECT.
 *
 * dyld's dlsym returns the interposer, so the original is the second
 * pointer in the interpose table after dyld binds it. Inserted with
 * DYLD_INSERT_LIBRARIES into segue-relay only.
 */

#include <netdb.h>
#include <string.h>
#include <strings.h>

#ifndef FIXTURE_NAME
#define FIXTURE_NAME "www.ailock-fixture.example.com"
#endif
#ifndef FIXTURE_ADDR
#define FIXTURE_ADDR "198.51.100.10"
#endif

typedef int (*gai_fn)(const char *, const char *, const struct addrinfo *,
                      struct addrinfo **);

typedef struct {
    const void *replacement;
    const void *original;
} interpose_t;

static int interposed_getaddrinfo(const char *hostname, const char *servname,
                                  const struct addrinfo *hints,
                                  struct addrinfo **res);

/* Not const: dyld writes the original function into `original`. */
__attribute__((used)) static interpose_t interposers[]
    __attribute__((section("__DATA,__interpose"))) = {
        {(const void *)interposed_getaddrinfo, (const void *)getaddrinfo},
};

static int name_matches(const char *host) {
    size_t length;
    if (host == NULL) {
        return 0;
    }
    length = strlen(host);
    if (length > 0 && host[length - 1] == '.') {
        length--;
    }
    if (strlen(FIXTURE_NAME) != length) {
        return 0;
    }
    return strncasecmp(host, FIXTURE_NAME, length) == 0;
}

static int interposed_getaddrinfo(const char *hostname, const char *servname,
                                  const struct addrinfo *hints,
                                  struct addrinfo **res) {
    gai_fn real = (gai_fn)interposers[0].original;
    if (real == NULL || real == interposed_getaddrinfo) {
        return EAI_FAIL;
    }
    if (name_matches(hostname)) {
        return real(FIXTURE_ADDR, servname, hints, res);
    }
    return real(hostname, servname, hints, res);
}
