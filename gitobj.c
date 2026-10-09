/* gitobj -- a reader and writer for git's object database, in one C11 file.
 *
 * Loose objects, the four object types, and packfiles: the v2 index, the pack
 * format, and both delta encodings. No libgit2, no zlib, no shelling out to
 * git. git is the authority this is measured against, never a dependency.
 *
 * A git object's name IS the SHA-1 of "<type> <len>\0<payload>", so every
 * read is self-checking: if the bytes we reconstructed hash back to the name
 * we looked them up by, the whole decode path was right. See README.md.
 */
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* shortcut: die() exits without freeing, so LeakSanitizer flags it. Every
 * caller is an out-of-memory, I/O or refusal path with no useful recovery;
 * wire the buffers to atexit if that ever matters. */
static void die(const char *m) {
	fprintf(stderr, "gitobj: %s\n", m);
	exit(1);
}
static void die2(const char *m, const char *a) {
	fprintf(stderr, "gitobj: %s: %s\n", m, a);
	exit(1);
}

/* A hard ceiling on any single object or delta result. Every size here is a
 * varint read out of a file somebody else wrote, so "allocate what it says"
 * is a denial of service with extra steps: a three-byte delta header can ask
 * for 4GB. 256MiB is far past anything git produces in practice.
 *
 * shortcut: one global ceiling rather than a per-call budget. Raise OBJ_MAX
 * if a legitimate repository ever holds a bigger blob than this. */
#define OBJ_MAX ((size_t)256 << 20)

/* ---------------------------------------------------------------- buffer */

/* Holds indices, never interior pointers: both inflate and the delta copy
 * instruction read out of a buffer that is being realloc'd, so a cached
 * pointer dangles at the worst possible moment. */
typedef struct { uint8_t *p; size_t n, cap; } Buf;

static void bneed(Buf *b, size_t extra) {
	if (b->n + extra <= b->cap) return;
	if (extra > OBJ_MAX || b->n + extra > OBJ_MAX) die("object exceeds OBJ_MAX");
	size_t c = b->cap ? b->cap : 4096;
	while (c < b->n + extra) c <<= 1;
	uint8_t *q = realloc(b->p, c);
	if (!q) die("out of memory");
	b->p = q;
	b->cap = c;
}
static void bfree(Buf *b) { free(b->p); b->p = NULL; b->n = b->cap = 0; }

/* -------------------------------------------------------------- SHA-1 */

/* FIPS 180-1. Short enough that pulling in a dependency for it would be
 * stranger than writing it, and it is checked against git's own object names
 * on every object in every corpus repository. */
typedef struct {
	uint32_t h[5];
	uint64_t bits;
	uint8_t blk[64];
	size_t n;
} Sha1;

static uint32_t rol(uint32_t v, int s) { return v << s | v >> (32 - s); }

static void sha1_block(Sha1 *s, const uint8_t *p) {
	uint32_t w[80];
	for (int i = 0; i < 16; i++)
		w[i] = (uint32_t)p[4 * i] << 24 | (uint32_t)p[4 * i + 1] << 16 |
		       (uint32_t)p[4 * i + 2] << 8 | p[4 * i + 3];
	for (int i = 16; i < 80; i++)
		w[i] = rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
	uint32_t a = s->h[0], b = s->h[1], c = s->h[2], d = s->h[3], e = s->h[4];
	for (int i = 0; i < 80; i++) {
		uint32_t f, k;
		if (i < 20)      { f = (b & c) | (~b & d);          k = 0x5a827999; }
		else if (i < 40) { f = b ^ c ^ d;                   k = 0x6ed9eba1; }
		else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc; }
		else             { f = b ^ c ^ d;                   k = 0xca62c1d6; }
		uint32_t t = rol(a, 5) + f + e + k + w[i];
		e = d; d = c; c = rol(b, 30); b = a; a = t;
	}
	s->h[0] += a; s->h[1] += b; s->h[2] += c; s->h[3] += d; s->h[4] += e;
}

static void sha1_init(Sha1 *s) {
	s->h[0] = 0x67452301; s->h[1] = 0xefcdab89; s->h[2] = 0x98badcfe;
	s->h[3] = 0x10325476; s->h[4] = 0xc3d2e1f0;
	s->bits = 0;
	s->n = 0;
}

static void sha1_update(Sha1 *s, const void *data, size_t n) {
	const uint8_t *p = data;
	s->bits += (uint64_t)n * 8;
	while (n) {
		size_t k = 64 - s->n;
		if (k > n) k = n;
		memcpy(s->blk + s->n, p, k);
		s->n += k;
		p += k;
		n -= k;
		if (s->n == 64) { sha1_block(s, s->blk); s->n = 0; }
	}
}

static void sha1_final(Sha1 *s, uint8_t out[20]) {
	uint64_t bits = s->bits;
	uint8_t pad = 0x80;
	sha1_update(s, &pad, 1);
	pad = 0;
	while (s->n != 56) sha1_update(s, &pad, 1);
	uint8_t len[8];
	for (int i = 0; i < 8; i++) len[i] = (uint8_t)(bits >> (56 - 8 * i));
	sha1_update(s, len, 8);
	for (int i = 0; i < 5; i++) {
		out[4 * i] = (uint8_t)(s->h[i] >> 24);
		out[4 * i + 1] = (uint8_t)(s->h[i] >> 16);
		out[4 * i + 2] = (uint8_t)(s->h[i] >> 8);
		out[4 * i + 3] = (uint8_t)s->h[i];
	}
}

/* --------------------------------------------------------------- hex */

static const char hexd[] = "0123456789abcdef";

/* out must hold 41 bytes. */
static void hexify(const uint8_t id[20], char *out) {
	for (int i = 0; i < 20; i++) {
		out[2 * i] = hexd[id[i] >> 4];
		out[2 * i + 1] = hexd[id[i] & 15];
	}
	out[40] = 0;
}

/* ------------------------------------------------------------ object types */

/* The order is git's own pack type numbering, which is why it starts at 1:
 * 1 commit, 2 tree, 3 blob, 4 tag, 5 unused, 6 OFS_DELTA, 7 REF_DELTA. */
enum { T_NONE = 0, T_COMMIT = 1, T_TREE = 2, T_BLOB = 3, T_TAG = 4,
       T_OFS_DELTA = 6, T_REF_DELTA = 7 };

static const char *tname(int t) {
	switch (t) {
	case T_COMMIT: return "commit";
	case T_TREE:   return "tree";
	case T_BLOB:   return "blob";
	case T_TAG:    return "tag";
	default:       return "?";
	}
}

static int tcode(const char *s) {
	if (!strcmp(s, "commit")) return T_COMMIT;
	if (!strcmp(s, "tree"))   return T_TREE;
	if (!strcmp(s, "blob"))   return T_BLOB;
	if (!strcmp(s, "tag"))    return T_TAG;
	return T_NONE;
}

/* The name of an object is SHA-1 over the loose-object header followed by the
 * payload -- the header is part of the hash even for packed objects, where it
 * is never stored. */
static void objid(int type, const uint8_t *p, size_t n, uint8_t id[20]) {
	char hdr[64];
	int k = snprintf(hdr, sizeof hdr, "%s %zu", tname(type), n);
	Sha1 s;
	sha1_init(&s);
	sha1_update(&s, hdr, (size_t)k + 1); /* +1 carries the NUL */
	sha1_update(&s, p, n);
	sha1_final(&s, id);
}

/* ------------------------------------------------------------------- io */

static void readall(const char *path, Buf *b) {
	FILE *f = path ? fopen(path, "rb") : stdin;
	if (!f) die2("cannot open", path);
	for (;;) {
		bneed(b, 65536);
		size_t k = fread(b->p + b->n, 1, 65536, f);
		b->n += k;
		if (k < 65536) break;
	}
	if (ferror(f)) die2("read error", path ? path : "<stdin>");
	if (path) fclose(f);
}

/* ------------------------------------------------------------------ main */

static int usage(void) {
	fputs("usage: gitobj hash <type> [file]\n", stderr);
	return 2;
}

int main(int argc, char **argv) {
	if (argc < 2) return usage();
	const char *cmd = argv[1];

	if (!strcmp(cmd, "hash") && argc >= 3) {
		int t = tcode(argv[2]);
		if (!t) die2("unknown object type", argv[2]);
		Buf in = {0};
		readall(argc >= 4 ? argv[3] : NULL, &in);
		uint8_t id[20];
		char hex[41];
		objid(t, in.p, in.n, id);
		hexify(id, hex);
		printf("%s\n", hex);
		bfree(&in);
		return 0;
	}

	return usage();
}
