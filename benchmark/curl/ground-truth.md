# curl Ground Truth — Benchmark for EDC

Source: https://curl.se/docs/security.html
Repo: https://github.com/curl/curl

## How to use

For each entry, checkout the **vulnerable commit** (parent of fix), run edc-build, and check if `issues.md` catches the bug.

The `fix_commit` is the commit that fixed the vulnerability. The vulnerable code exists at `fix_commit~1`.

---

## Entries

### CVE-2023-38545
- **category:** heap-buffer-overflow
- **severity:** critical
- **description:** SOCKS5 heap buffer overflow. When curl is told to use a SOCKS5 proxy and pass the hostname to the proxy (rather than resolving it locally), the maximum hostname length is 255 bytes. If the hostname is longer, curl switches to local resolution and sends the resolved address to the proxy. However, due to a bug, the local variable that tells curl to "let the host resolve the name" could get set wrong during a slow SOCKS5 handshake, and then copy the overly long hostname to a too-small heap buffer.
- **fix_commit:** `fb4415d8ae`
- **affected_file:** lib/socks.c
- **bug_pattern:** hostname length check bypassed during slow handshake, buffer overflow on copy

### CVE-2021-22945
- **category:** use-after-free, double-free
- **severity:** high
- **description:** UAF and double free in MQTT sending. When sending MQTT data, libcurl could use and free a pointer to a heap-based buffer that was already freed in an earlier call.
- **fix_commit:** `43157490a5`
- **affected_file:** lib/mqtt.c
- **bug_pattern:** pointer not cleared after free, reused in subsequent send call

### CVE-2020-8177
- **category:** local-file-overwrite
- **severity:** high
- **description:** curl overwrite local file with -J. curl could be tricked by a malicious server into overwriting a local file when using -J (--remote-header-name) and -i (--include) together in the same command line.
- **fix_commit:** `8236aba585`
- **affected_file:** src/tool_getparam.c
- **bug_pattern:** missing validation that -i and -J flags are incompatible

### CVE-2021-22947
- **category:** protocol-injection
- **severity:** high
- **description:** STARTTLS protocol injection via MITM. When curl connects to FTP, IMAP, POP3, or SMTP servers using STARTTLS to upgrade to TLS, a man-in-the-middle attacker could inject extra responses before the TLS upgrade, which curl would then process as if they came from the TLS-protected server.
- **fix_commit:** `8ef147c436`
- **affected_file:** lib/ftp.c, lib/imap.c, lib/pop3.c, lib/smtp.c
- **bug_pattern:** server responses processed before TLS handshake completes, no buffer flush on STARTTLS

### CVE-2018-16890
- **category:** out-of-bounds-read
- **severity:** high
- **description:** NTLM type-2 out-of-bounds buffer read. The function handling incoming NTLM type-2 messages does not validate incoming data correctly, which could lead to an out-of-bounds buffer read.
- **fix_commit:** `b780b30d13`
- **affected_file:** lib/vauth/ntlm.c
- **bug_pattern:** insufficient size check on NTLM type-2 received data

### CVE-2019-3822
- **category:** stack-buffer-overflow
- **severity:** critical
- **description:** NTLMv2 type-3 header stack buffer overflow. The function creating an outgoing NTLM type-3 header generates the request HTTP header contents based on previously received data. The check that exists to prevent the local buffer from getting overflowed is implemented incorrectly.
- **fix_commit:** `50c9484278`
- **affected_file:** lib/vauth/ntlm.c
- **bug_pattern:** incorrect size check condition allows stack buffer overflow in type-3 message generation

### CVE-2018-0500
- **category:** heap-buffer-overflow
- **severity:** high
- **description:** SMTP send heap buffer overflow. When an SMTP connection is made to send data, curl allocates a scratch buffer for encoding. The buffer size was calculated incorrectly, leading to a heap buffer overflow when sending large data.
- **fix_commit:** `ba1dbd78e5`
- **affected_file:** lib/smtp.c
- **bug_pattern:** scratch buffer malloc uses wrong size constant, overflow when data exceeds expected size

### CVE-2016-8617
- **category:** out-of-bounds-write
- **severity:** high
- **description:** OOB write via unchecked multiplication. In the base64 encode function, the output buffer size is calculated using multiplication that can overflow on 32-bit systems, leading to a heap buffer overflow.
- **fix_commit:** `efd24d5742`
- **affected_file:** lib/base64.c
- **bug_pattern:** integer overflow in size calculation (multiplication without overflow check) before malloc

### CVE-2018-1000301
- **category:** out-of-bounds-read
- **severity:** medium
- **description:** RTSP bad headers buffer over-read. When parsing RTSP response headers, curl could read past the end of the buffer if the server sent a bad response line.
- **fix_commit:** `8c7b3737d2`
- **affected_file:** lib/http.c
- **bug_pattern:** buffer pointer not restored when response line parsing fails, subsequent reads go out of bounds

### CVE-2022-27776
- **category:** credential-leak
- **severity:** medium
- **description:** Auth/cookie leak on redirect. When following redirects, curl could leak authentication headers and cookies to servers on different ports of the same host.
- **fix_commit:** `6e65999395`
- **affected_file:** lib/http.c
- **bug_pattern:** redirect target port not compared against original request port when deciding to send credentials

### CVE-2020-8285
- **category:** stack-overflow
- **severity:** medium
- **description:** FTP wildcard stack overflow. Due to a flaw in the FTP wildcard matching function, a pattern containing `[` could cause unbounded recursion, leading to a stack overflow and potential crash.
- **fix_commit:** `cb5accab9e`
- **affected_file:** lib/ftp-wildcard.c
- **bug_pattern:** unbounded recursion in bracket pattern matching without depth limit
