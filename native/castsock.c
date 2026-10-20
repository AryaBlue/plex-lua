/* castsock: a blocking TLS client socket for Google Cast (port 8009), using
 * Windows' own TLS (Schannel). Cast receivers present self-signed device
 * certificates, so the certificate is not validated (as in every Cast sender
 * outside Chrome, which checks it against Google's device CA instead).
 *
 * One connection is used from one thread at a time. Build: native/build.bat.
 *
 *   cs_conn *cs_open(const char *host, int port, int timeout_ms);  NULL: see cs_open_error()
 *   int  cs_send(cs_conn *c, const char *buf, int len);           0 ok, -1 error
 *   int  cs_recv(cs_conn *c, char *buf, int cap, int timeout_ms); bytes, 0 timeout, -1 closed/error
 *   const char *cs_error(cs_conn *c);
 *   void cs_close(cs_conn *c);
 *
 * It also holds the RSA key for ADB (cast/adb.lua, the Fire TV remote): made with
 * Windows' CNG the first time and kept in a file, so the TV asks only once.
 *   int cs_adb_pubkey(const char *keyPath, char *out, int cap);  length (with the NUL), -1: cs_open_error()
 *   int cs_adb_sign(const char *keyPath, const unsigned char *token, int len, unsigned char *out, int cap);
 */
#define _CRT_SECURE_NO_WARNINGS
#define WIN32_LEAN_AND_MEAN
#define SECURITY_WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <security.h>
#include <schannel.h>
#include <bcrypt.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EXPORT __declspec(dllexport)
#define IN_CAP (64 * 1024)

typedef struct cs_conn {
    SOCKET s;
    CredHandle cred;
    CtxtHandle ctx;
    int hasCred, hasCtx;
    SecPkgContext_StreamSizes sizes;
    char *in;            /* encrypted bytes received but not yet decrypted */
    int inLen;
    char *plain;         /* decrypted bytes not yet handed out */
    int plainLen, plainOff;
    char err[256];
} cs_conn;

static __declspec(thread) char g_openErr[256];

static void seterr(char *dst, const char *what, long code)
{
    _snprintf(dst, 255, "%s (0x%08lx)", what, (unsigned long)code);
    dst[255] = 0;
}

/* Wait until the socket is readable. 1 ready, 0 timeout, -1 error. */
static int wait_readable(SOCKET s, int timeout_ms)
{
    fd_set rd;
    struct timeval tv;
    FD_ZERO(&rd);
    FD_SET(s, &rd);
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    int r = select(0, &rd, NULL, NULL, timeout_ms < 0 ? NULL : &tv);
    return r < 0 ? -1 : r;
}

/* Append raw bytes to c->in. >0 bytes, 0 timeout, -1 closed/error. */
static int fill(cs_conn *c, int timeout_ms)
{
    if (c->inLen >= IN_CAP) { seterr(c->err, "TLS record too large", 0); return -1; }
    int w = wait_readable(c->s, timeout_ms);
    if (w <= 0) { if (w < 0) seterr(c->err, "select failed", WSAGetLastError()); return w; }
    int n = recv(c->s, c->in + c->inLen, IN_CAP - c->inLen, 0);
    if (n <= 0) { seterr(c->err, n == 0 ? "connection closed" : "recv failed", n == 0 ? 0 : WSAGetLastError()); return -1; }
    c->inLen += n;
    return n;
}

static int send_all(SOCKET s, const char *buf, int len)
{
    while (len > 0) {
        int n = send(s, buf, len, 0);
        if (n <= 0) return -1;
        buf += n;
        len -= n;
    }
    return 0;
}

static SOCKET tcp_connect(const char *host, int port, int timeout_ms, char *err)
{
    struct addrinfo hints, *res = NULL, *ai;
    char portStr[16];
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    _snprintf(portStr, sizeof portStr, "%d", port);
    int gr = getaddrinfo(host, portStr, &hints, &res);
    if (gr != 0) { seterr(err, "could not resolve host", gr); return INVALID_SOCKET; }

    SOCKET s = INVALID_SOCKET;
    for (ai = res; ai; ai = ai->ai_next) {
        s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (s == INVALID_SOCKET) continue;
        u_long nb = 1;
        ioctlsocket(s, FIONBIO, &nb);
        connect(s, ai->ai_addr, (int)ai->ai_addrlen);
        fd_set wr, ex;
        struct timeval tv = { timeout_ms / 1000, (timeout_ms % 1000) * 1000 };
        FD_ZERO(&wr); FD_SET(s, &wr);
        FD_ZERO(&ex); FD_SET(s, &ex);
        int r = select(0, NULL, &wr, &ex, &tv);
        if (r > 0 && FD_ISSET(s, &wr)) {
            nb = 0;
            ioctlsocket(s, FIONBIO, &nb);
            int one = 1;
            setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&one, sizeof one);
            break;
        }
        seterr(err, r == 0 ? "connection timed out" : "connection refused", r == 0 ? 0 : WSAGetLastError());
        closesocket(s);
        s = INVALID_SOCKET;
    }
    freeaddrinfo(res);
    return s;
}

static int handshake(cs_conn *c, const char *host, int timeout_ms)
{
    SCHANNEL_CRED sc;
    memset(&sc, 0, sizeof sc);
    sc.dwVersion = SCHANNEL_CRED_VERSION;
    sc.dwFlags = SCH_CRED_MANUAL_CRED_VALIDATION | SCH_CRED_NO_DEFAULT_CREDS;
    SECURITY_STATUS st = AcquireCredentialsHandleA(NULL, UNISP_NAME_A, SECPKG_CRED_OUTBOUND, NULL, &sc,
                                                   NULL, NULL, &c->cred, NULL);
    if (st != SEC_E_OK) { seterr(c->err, "AcquireCredentialsHandle failed", st); return -1; }
    c->hasCred = 1;

    DWORD flags = ISC_REQ_SEQUENCE_DETECT | ISC_REQ_REPLAY_DETECT | ISC_REQ_CONFIDENTIALITY |
                  ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_STREAM | ISC_REQ_MANUAL_CRED_VALIDATION;
    DWORD outFlags;
    SecBuffer outb = { 0, SECBUFFER_TOKEN, NULL };
    SecBufferDesc outd = { SECBUFFER_VERSION, 1, &outb };

    st = InitializeSecurityContextA(&c->cred, NULL, (SEC_CHAR *)host, flags, 0, 0, NULL, 0,
                                    &c->ctx, &outd, &outFlags, NULL);
    if (st != SEC_I_CONTINUE_NEEDED) { seterr(c->err, "TLS start failed", st); return -1; }
    c->hasCtx = 1;
    if (outb.cbBuffer && send_all(c->s, outb.pvBuffer, outb.cbBuffer) < 0) {
        FreeContextBuffer(outb.pvBuffer);
        seterr(c->err, "TLS send failed", WSAGetLastError());
        return -1;
    }
    FreeContextBuffer(outb.pvBuffer);

    int needRecv = 1;
    for (;;) {
        if (needRecv) {
            int n = fill(c, timeout_ms);
            if (n <= 0) { if (n == 0) seterr(c->err, "TLS handshake timed out", 0); return -1; }
        }
        SecBuffer inb[2] = { { (unsigned long)c->inLen, SECBUFFER_TOKEN, c->in }, { 0, SECBUFFER_EMPTY, NULL } };
        SecBufferDesc ind = { SECBUFFER_VERSION, 2, inb };
        outb.cbBuffer = 0; outb.BufferType = SECBUFFER_TOKEN; outb.pvBuffer = NULL;

        st = InitializeSecurityContextA(&c->cred, &c->ctx, (SEC_CHAR *)host, flags, 0, 0, &ind, 0,
                                        NULL, &outd, &outFlags, NULL);
        if (st == SEC_E_INCOMPLETE_MESSAGE) { needRecv = 1; continue; }

        if (outb.cbBuffer && outb.pvBuffer) {
            int sr = send_all(c->s, outb.pvBuffer, outb.cbBuffer);
            FreeContextBuffer(outb.pvBuffer);
            if (sr < 0) { seterr(c->err, "TLS send failed", WSAGetLastError()); return -1; }
        }
        if (inb[1].BufferType == SECBUFFER_EXTRA && inb[1].cbBuffer > 0) {
            memmove(c->in, c->in + c->inLen - inb[1].cbBuffer, inb[1].cbBuffer);
            c->inLen = inb[1].cbBuffer;
        } else {
            c->inLen = 0;
        }

        if (st == SEC_E_OK) break;
        if (st == SEC_I_CONTINUE_NEEDED) { needRecv = c->inLen == 0; continue; }
        seterr(c->err, "TLS handshake failed", st);
        return -1;
    }

    st = QueryContextAttributesA(&c->ctx, SECPKG_ATTR_STREAM_SIZES, &c->sizes);
    if (st != SEC_E_OK) { seterr(c->err, "TLS sizes unavailable", st); return -1; }
    return 0;
}

EXPORT void cs_close(cs_conn *c)
{
    if (!c) return;
    if (c->hasCtx) DeleteSecurityContext(&c->ctx);
    if (c->hasCred) FreeCredentialsHandle(&c->cred);
    if (c->s != INVALID_SOCKET) closesocket(c->s);
    free(c->in);
    free(c->plain);
    free(c);
}

EXPORT const char *cs_open_error(void) { return g_openErr; }
EXPORT const char *cs_error(cs_conn *c) { return c ? c->err : g_openErr; }

EXPORT cs_conn *cs_open(const char *host, int port, int timeout_ms)
{
    static int wsaReady = 0;
    if (!wsaReady) {
        WSADATA wd;
        if (WSAStartup(MAKEWORD(2, 2), &wd) != 0) { seterr(g_openErr, "WSAStartup failed", 0); return NULL; }
        wsaReady = 1;
    }
    cs_conn *c = calloc(1, sizeof *c);
    if (!c) { seterr(g_openErr, "out of memory", 0); return NULL; }
    c->s = INVALID_SOCKET;
    c->in = malloc(IN_CAP);
    c->plain = malloc(IN_CAP);
    if (!c->in || !c->plain) { seterr(g_openErr, "out of memory", 0); cs_close(c); return NULL; }

    c->s = tcp_connect(host, port, timeout_ms, g_openErr);
    if (c->s == INVALID_SOCKET) { cs_close(c); return NULL; }
    if (handshake(c, host, timeout_ms) < 0) {
        memcpy(g_openErr, c->err, sizeof g_openErr);
        cs_close(c);
        return NULL;
    }
    return c;
}

EXPORT int cs_send(cs_conn *c, const char *buf, int len)
{
    unsigned long hdr = c->sizes.cbHeader, trl = c->sizes.cbTrailer, max = c->sizes.cbMaximumMessage;
    char *rec = malloc(hdr + max + trl);
    if (!rec) { seterr(c->err, "out of memory", 0); return -1; }
    while (len > 0) {
        unsigned long n = (unsigned long)len < max ? (unsigned long)len : max;
        memcpy(rec + hdr, buf, n);
        SecBuffer b[4] = {
            { hdr, SECBUFFER_STREAM_HEADER, rec },
            { n, SECBUFFER_DATA, rec + hdr },
            { trl, SECBUFFER_STREAM_TRAILER, rec + hdr + n },
            { 0, SECBUFFER_EMPTY, NULL },
        };
        SecBufferDesc d = { SECBUFFER_VERSION, 4, b };
        SECURITY_STATUS st = EncryptMessage(&c->ctx, 0, &d, 0);
        if (st != SEC_E_OK) { free(rec); seterr(c->err, "TLS encrypt failed", st); return -1; }
        if (send_all(c->s, rec, b[0].cbBuffer + b[1].cbBuffer + b[2].cbBuffer) < 0) {
            free(rec);
            seterr(c->err, "send failed", WSAGetLastError());
            return -1;
        }
        buf += n;
        len -= (int)n;
    }
    free(rec);
    return 0;
}

EXPORT int cs_recv(cs_conn *c, char *out, int cap, int timeout_ms)
{
    for (;;) {
        if (c->plainOff < c->plainLen) {
            int n = c->plainLen - c->plainOff;
            if (n > cap) n = cap;
            memcpy(out, c->plain + c->plainOff, n);
            c->plainOff += n;
            return n;
        }
        if (c->inLen > 0) {
            SecBuffer b[4] = {
                { (unsigned long)c->inLen, SECBUFFER_DATA, c->in },
                { 0, SECBUFFER_EMPTY, NULL }, { 0, SECBUFFER_EMPTY, NULL }, { 0, SECBUFFER_EMPTY, NULL },
            };
            SecBufferDesc d = { SECBUFFER_VERSION, 4, b };
            SECURITY_STATUS st = DecryptMessage(&c->ctx, &d, 0, NULL);
            if (st == SEC_E_OK) {
                SecBuffer *data = NULL, *extra = NULL;
                for (int i = 1; i < 4; i++) {
                    if (b[i].BufferType == SECBUFFER_DATA && !data) data = &b[i];
                    if (b[i].BufferType == SECBUFFER_EXTRA && !extra) extra = &b[i];
                }
                c->plainOff = 0;
                c->plainLen = 0;
                if (data && data->cbBuffer) {
                    memcpy(c->plain, data->pvBuffer, data->cbBuffer);
                    c->plainLen = data->cbBuffer;
                }
                if (extra && extra->cbBuffer) {
                    memmove(c->in, c->in + c->inLen - extra->cbBuffer, extra->cbBuffer);
                    c->inLen = extra->cbBuffer;
                } else {
                    c->inLen = 0;
                }
                continue;
            }
            if (st == SEC_I_CONTEXT_EXPIRED) { seterr(c->err, "connection closed", 0); return -1; }
            if (st != SEC_E_INCOMPLETE_MESSAGE) { seterr(c->err, "TLS decrypt failed", st); return -1; }
        }
        int n = fill(c, timeout_ms);
        if (n <= 0) return n;
    }
}

/* ---- ADB key ------------------------------------------------------------ */

static BCRYPT_ALG_HANDLE g_rsa;

/* The key in keyPath, made (and saved there) if the file doesn't exist yet. */
static BCRYPT_KEY_HANDLE adb_key(const char *path)
{
    BCRYPT_KEY_HANDLE key = NULL;
    unsigned char buf[4096];
    NTSTATUS st;
    if (!g_rsa && (st = BCryptOpenAlgorithmProvider(&g_rsa, BCRYPT_RSA_ALGORITHM, NULL, 0)) != 0) {
        g_rsa = NULL;
        seterr(g_openErr, "RSA unavailable", st);
        return NULL;
    }
    FILE *f = fopen(path, "rb");
    if (f) {
        size_t n = fread(buf, 1, sizeof buf, f);
        fclose(f);
        st = BCryptImportKeyPair(g_rsa, NULL, BCRYPT_RSAFULLPRIVATE_BLOB, &key, buf, (ULONG)n, 0);
        if (st) { seterr(g_openErr, "couldn't read the ADB key", st); return NULL; }
        return key;
    }
    st = BCryptGenerateKeyPair(g_rsa, &key, 2048, 0);
    if (!st) st = BCryptFinalizeKeyPair(key, 0);
    if (st) { seterr(g_openErr, "couldn't make an ADB key", st); return NULL; }
    ULONG n = 0;
    st = BCryptExportKey(key, NULL, BCRYPT_RSAFULLPRIVATE_BLOB, buf, sizeof buf, &n, 0);
    f = st ? NULL : fopen(path, "wb");
    if (!f || fwrite(buf, 1, n, f) != n) {
        if (f) fclose(f);
        BCryptDestroyKey(key);
        seterr(g_openErr, "couldn't save the ADB key", st);
        return NULL;
    }
    fclose(f);
    return key;
}

/* The public key as adb sends it: base64 of Android's RSAPublicKey struct (word count,
 * -1/n[0] mod 2^32, modulus, R^2 mod n with R = 2^2048, all little-endian words, then
 * the exponent), a space and a name. */
EXPORT int cs_adb_pubkey(const char *path, char *out, int cap)
{
    BCRYPT_KEY_HANDLE key = adb_key(path);
    if (!key) return -1;
    unsigned char blob[1024];
    ULONG bn = 0;
    NTSTATUS st = BCryptExportKey(key, NULL, BCRYPT_RSAPUBLIC_BLOB, blob, sizeof blob, &bn, 0);
    BCryptDestroyKey(key);
    if (st) { seterr(g_openErr, "couldn't export the ADB key", st); return -1; }
    BCRYPT_RSAKEY_BLOB *h = (BCRYPT_RSAKEY_BLOB *)blob;
    const unsigned char *e = blob + sizeof *h, *m = e + h->cbPublicExp;
    if (h->cbModulus != 256) { seterr(g_openErr, "unexpected ADB key size", h->cbModulus); return -1; }

    uint32_t s[1 + 1 + 64 + 64 + 1];
    uint32_t *n = s + 2, *rr = s + 66;
    for (int i = 0; i < 64; i++)
        n[i] = (uint32_t)m[255 - 4 * i] | (uint32_t)m[254 - 4 * i] << 8 | (uint32_t)m[253 - 4 * i] << 16 |
               (uint32_t)m[252 - 4 * i] << 24;
    uint32_t x = n[0];                           /* inverse of n[0] mod 2^32 (Newton) */
    for (int i = 0; i < 5; i++) x *= 2 - n[0] * x;
    s[0] = 64;
    s[1] = 0 - x;
    uint32_t r[65] = { 1 };                      /* 2^4096 mod n by doubling */
    for (int k = 0; k < 4096; k++) {
        uint32_t carry = 0;
        for (int i = 0; i < 65; i++) { uint32_t v = r[i]; r[i] = v << 1 | carry; carry = v >> 31; }
        int ge = r[64] != 0;
        if (!ge) {
            ge = 1;
            for (int i = 63; i >= 0; i--) if (r[i] != n[i]) { ge = r[i] > n[i]; break; }
        }
        if (ge) {
            uint64_t borrow = 0;
            for (int i = 0; i < 64; i++) {
                uint64_t d = (uint64_t)r[i] - n[i] - borrow;
                r[i] = (uint32_t)d;
                borrow = (d >> 63) & 1;
            }
            r[64] -= (uint32_t)borrow;
        }
    }
    memcpy(rr, r, 64 * 4);
    uint32_t exp = 0;
    for (ULONG i = 0; i < h->cbPublicExp; i++) exp = exp << 8 | e[i];
    s[130] = exp;

    static const char b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const unsigned char *p = (const unsigned char *)s;
    int len = (int)sizeof s, o = 0;
    const char *name = " Reel@PC";
    if (cap < (len + 2) / 3 * 4 + (int)strlen(name) + 1) { seterr(g_openErr, "buffer too small", cap); return -1; }
    for (int i = 0; i < len; i += 3) {
        uint32_t v = (uint32_t)p[i] << 16 | (i + 1 < len ? (uint32_t)p[i + 1] << 8 : 0) | (i + 2 < len ? p[i + 2] : 0);
        out[o++] = b64[v >> 18 & 63];
        out[o++] = b64[v >> 12 & 63];
        out[o++] = i + 1 < len ? b64[v >> 6 & 63] : '=';
        out[o++] = i + 2 < len ? b64[v & 63] : '=';
    }
    strcpy(out + o, name);
    return o + (int)strlen(name) + 1;
}

/* Sign the device's 20-byte token as adb does: PKCS#1 v1.5 with a SHA-1 digest header. */
EXPORT int cs_adb_sign(const char *path, const unsigned char *token, int len, unsigned char *out, int cap)
{
    BCRYPT_KEY_HANDLE key = adb_key(path);
    if (!key) return -1;
    BCRYPT_PKCS1_PADDING_INFO pad = { BCRYPT_SHA1_ALGORITHM };
    ULONG n = 0;
    NTSTATUS st = BCryptSignHash(key, &pad, (PUCHAR)token, (ULONG)len, out, (ULONG)cap, &n, BCRYPT_PAD_PKCS1);
    BCryptDestroyKey(key);
    if (st) { seterr(g_openErr, "couldn't sign the ADB token", st); return -1; }
    return (int)n;
}
