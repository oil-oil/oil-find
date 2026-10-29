#ifndef COILFIND_H
#define COILFIND_H
#include <stddef.h>
#include <stdint.h>
/* AND clauses of OR terms over fixed-size Bloom blocks; bits are prehashed. */
typedef struct { uint32_t start, count; } SiftBloomSpan;
size_t sift_filter_bloom(const uint8_t *blocks, size_t stride, uint32_t first, uint32_t end,
                         const uint32_t *bits, const SiftBloomSpan *terms,
                         const SiftBloomSpan *clauses, size_t clause_count, uint32_t *out);
int sift_contains_unicode_folded(const uint8_t *text, size_t length, const uint8_t *needle, size_t needle_length);
long sift_find(const uint8_t *hay, size_t len, size_t from, const uint8_t *needle, size_t nlen, int cs);
size_t sift_scan_entries(const uint8_t *blob, const uint32_t *off, uint32_t e0, uint32_t e1, const uint8_t *needle, size_t nlen, int cs, uint32_t *out, size_t cap, uint32_t *resume);
/* out must have capacity for count entry IDs. */
size_t sift_scan_candidates(const uint32_t *ids, size_t count, const uint8_t *blob,
                            const uint32_t *off, const uint8_t *needle, size_t nlen,
                            int cs, int include_non_ascii, uint32_t *out);
size_t sift_filter_entries(uint32_t e0, uint32_t e1, const uint8_t *flags,
                           const uint8_t *kind, uint16_t kind_mask,
                           const uint8_t *path_mask, uint32_t *out);
int sift_has_ancestor(uint32_t id, const uint32_t *parents, const uint8_t *names, const uint32_t *offsets, const uint8_t *needle, size_t length);
int sift_match_quality(const uint8_t *name, size_t len, const uint8_t *needle, size_t nlen, int cs);
int sift_contains(const uint8_t *s, size_t len, const uint8_t *needle, size_t nlen, int cs);
int sift_has_prefix(const uint8_t *s, size_t len, const uint8_t *p, size_t plen, int cs);
int sift_has_suffix(const uint8_t *s, size_t len, const uint8_t *p, size_t plen, int cs);
int sift_equals(const uint8_t *s, size_t len, const uint8_t *p, size_t plen, int cs);
int sift_glob_match(const uint8_t *pat, size_t plen, const uint8_t *s, size_t slen, int cs);
int sift_name_compare(const uint8_t *a, size_t alen, const uint8_t *b, size_t blen);
void sift_score_name_batch(const uint32_t *ids, size_t count,
                           const uint8_t *names, const uint32_t *name_off,
                           const uint8_t *flags, const uint8_t *kind,
                           const uint8_t *depth, const uint32_t *mtime,
                           const uint8_t *needle, size_t needle_len, int cs,
                           uint32_t now, int32_t *scores);
/* Apply a name exclusion only to candidates that passed positive scoring. */
void sift_exclude_name_batch(const uint32_t *ids, size_t count,
                             const uint8_t *names, const uint32_t *name_off,
                             const uint32_t *parents, const uint8_t *flags,
                             const uint8_t *kind, int filter_kind, const uint8_t *needle,
                             size_t needle_len, int cs, int ancestors,
                             int root_matches, int32_t *scores);
/* Batch scores distinguish ASCII misses from names needing alternate-key matching. */
static const int32_t OILFIND_SCORE_NO_MATCH = INT32_MIN;
static const int32_t OILFIND_SCORE_FALLBACK = INT32_MIN + 1;
typedef struct {
    const char *name;
    uint32_t name_len;
    uint32_t type;
    uint32_t bsd_flags;
    int32_t dev;
    int32_t error;
    uint64_t fileid;
    uint64_t size;
    int64_t mtime;
} oilfind_dirent;
int sift_read_dir(int fd, void *scratch, size_t scratch_size, oilfind_dirent *out, int out_cap);
uint64_t sift_entry_hash(uint32_t parent, const uint8_t *name, size_t len, int case_sensitive);
void sift_build_hash(uint32_t *table, size_t capacity, const uint32_t *parents,
                     const uint8_t *names, const uint32_t *offsets, size_t count,
                     int case_sensitive);
void sift_sweep(uint8_t *flags, const uint32_t *parents, size_t count, uint32_t *removed);

int sift_name_equal_folded(const uint8_t *a, size_t alen, const uint8_t *b, size_t blen);
int sift_name_equal(const uint8_t *a, size_t alen, const uint8_t *b, size_t blen,
                    int case_sensitive);
int sift_validate_index(const uint32_t *name_off, const uint32_t *parent,
                        const uint8_t *kind,
                        size_t count, size_t names_len,
                        const uint32_t *alt_off, const uint32_t *alt_owner,
                        size_t alt_count, size_t alt_len,
                        uint32_t home_index, uint32_t deleted_count);
uint64_t sift_resident_bytes(void);
int sift_actual_name(const char *path, uint8_t *out, size_t capacity);
/* Send exactly one descriptor in a one-byte AF_UNIX datagram. The caller retains
   ownership of descriptor. Returns 0 on success or -1 with errno set; sending is
   nonblocking and suppresses SIGPIPE on socket. */
int sift_send_fd(int socket, int descriptor);
/* Receive one descriptor from an AF_UNIX datagram. The function may block. On
   success the caller owns a close-on-exec descriptor; on failure it returns -1
   with errno set and closes any descriptors received in a rejected packet. */
int sift_receive_fd(int socket);
#endif
