# Redis Ground Truth — Benchmark for EDC

Source: https://github.com/redis/redis/security/advisories
Repo: https://github.com/redis/redis

## How to use

For each entry, checkout the **vulnerable commit** (parent of fix), run edc-build, and check if `issues.md` catches the bug.

The `fix_commit` is the commit that fixed the vulnerability. The vulnerable code exists at `fix_commit~1`.

---

## Entries

### CVE-2021-29477
- **category:** integer-overflow
- **severity:** high
- **description:** Integer overflow in STRALGO LCS command. The zmalloc size calculation uses wrong integer type, allowing heap corruption when processing crafted inputs in Redis 6.0+.
- **fix_commit:** `f0c5f920d0f88bd8aa376a2c05af4902789d1ef9`
- **affected_file:** src/t_string.c
- **bug_pattern:** missing size_t cast before multiplication passed to zmalloc, integer overflow in allocation size

### CVE-2021-29478
- **category:** integer-overflow
- **severity:** high
- **description:** Integer overflow in intsetBlobLen(). The multiplication of length * encoding uses 32-bit types, making the COPY command on a large intset corrupt the heap.
- **fix_commit:** `29900d4e6bccdf3691bedf0ea9a5d84863fa3592`
- **affected_file:** src/intset.c
- **bug_pattern:** uint32_t multiplication without size_t promotion, integer overflow in intset blob length calculation

### CVE-2021-32626
- **category:** heap-buffer-overflow
- **severity:** high
- **description:** Specially crafted Lua scripts can overflow the heap-based Lua stack. Call sites in Redis's Lua integration push values without first checking available stack slots, enabling out-of-bounds writes.
- **fix_commit:** `666ed7facf4524bf6d19b11b20faa2cf93fdf591`
- **affected_file:** src/scripting.c
- **bug_pattern:** missing lua_checkstack guard before pushing multiple values onto Lua stack

### CVE-2022-31144
- **category:** heap-buffer-overflow
- **severity:** high
- **description:** XAUTOCLAIM on a stream key in a specific state writes beyond the end of its temporary deleted entries array. The COUNT parameter limits claimed entries but was not decrementing for deleted (expired PEL) entries.
- **fix_commit:** `15ae4e29e537e7ec37f0df1825d9fb2beea67124`
- **affected_file:** src/t_stream.c
- **bug_pattern:** off-by-one in count tracking, count not decremented for deleted-entry path, reply array exceeds allocated bounds

### CVE-2022-35951
- **category:** integer-overflow
- **severity:** high
- **description:** XAUTOCLAIM COUNT argument not capped. An astronomically large value causes integer overflow in zmalloc, resulting in undersized heap allocation and subsequent overflow.
- **fix_commit:** `fa6815e14ea5adff93c5cd7be513c02a7c6e3f2a`
- **affected_file:** src/t_stream.c
- **bug_pattern:** no upper-bound validation of user-supplied COUNT, zmalloc size overflow when count is near LLONG_MAX

### CVE-2023-22458
- **category:** integer-overflow
- **severity:** medium
- **description:** HRANDFIELD and ZRANDMEMBER with extreme negative count values overflow a signed integer comparison, crashing Redis via assertion due to protocol limitation bypass.
- **fix_commit:** `16f408b1a0121cacd44cbf8aee275d69dc627f02`
- **affected_file:** src/t_zset.c
- **bug_pattern:** missing bounds check on count parameter before arithmetic, signed integer overflow in negative count handling

### CVE-2023-28856
- **category:** improper-input-validation
- **severity:** medium
- **description:** HINCRBYFLOAT can create a hash field with a NaN/Infinity value when the increment produces an invalid float. On subsequent access Redis hits an assertion and crashes.
- **fix_commit:** `1c1bd618c95e26a8ff5c12e70cbf0117233ef073`
- **affected_file:** src/t_hash.c
- **bug_pattern:** no NaN or Infinity check on HINCRBYFLOAT result before storing in hash

### CVE-2023-41053
- **category:** access-control-bypass
- **severity:** low
- **description:** SORT_RO getkeys function returns key count 0 instead of 1, so ACL evaluation never sees the accessed key. Users can read keys they are not authorized for.
- **fix_commit:** `9e505e6cd842338424e05883521ca1fb7d0f47f6`
- **affected_file:** src/db.c
- **bug_pattern:** sortROGetKeys missing numkeys assignment before return, numkeys stays 0 so ACL skips key check

### CVE-2023-45145
- **category:** race-condition
- **severity:** low
- **description:** Unix socket listen is called before chmod sets the intended permissions. During the race window any local process can connect to the socket.
- **fix_commit:** `03345ddc7faf7af079485f2cbe5d17a1611cbce1`
- **affected_file:** src/anet.c
- **bug_pattern:** listen called before chmod on unix socket, TOCTOU race between bind and permission application

### CVE-2024-31227
- **category:** improper-input-validation
- **severity:** medium
- **description:** A malformed ACL SETUSER rule with a key-pattern selector but no permission flags creates an invalid ACL selector object. On access it triggers a server panic.
- **fix_commit:** `b351d5a3210e61cc3b22ba38a723d6da8f3c298a`
- **affected_file:** src/acl.c
- **bug_pattern:** key-pattern branch reached without checking flags are nonzero, null dereference on invalid ACL selector

### CVE-2024-31228
- **category:** uncontrolled-recursion
- **severity:** medium
- **description:** stringmatchlen() recurses for every * in a glob pattern with no depth limit. A long pattern of repeated wildcards causes stack overflow and process crash.
- **fix_commit:** `9317bf64659b33166a943ec03d5d9b954e86afb0`
- **affected_file:** src/util.c
- **bug_pattern:** recursive call on wildcard without nesting counter or depth limit, unbounded recursion in glob matching

### CVE-2024-31449
- **category:** stack-buffer-overflow
- **severity:** high
- **description:** bit.tohex in Lua bit library negates width if negative without checking for INT32_MIN, triggering signed integer overflow and writing beyond the stack buffer.
- **fix_commit:** `1f7c148be2cbacf7d50aa461c58b871e87cc5ed9`
- **affected_file:** deps/lua/src/lua_bit.c
- **bug_pattern:** negation of INT32_MIN overflows signed int, no guard for minimum value before negation
