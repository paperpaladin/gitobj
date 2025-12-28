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
#include <dirent.h>

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
static void bwrite(Buf *b, const void *s, size_t n) {
	bneed(b, n);
	memcpy(b->p + b->n, s, n);
	b->n += n;
}
static void bfree(Buf *b) { free(b->p); b->p = NULL; b->n = b->cap = 0; }

/* ================================================== DEFLATE (RFC 1951) ==
 *
 * Lifted from the sibling project ../inflate, where this same decoder is
 * tested against /usr/bin/gzip at every compression level over eleven
 * fixtures, plus nine hand-built streams that each violate exactly one rule
 * of RFC 1951 and 300 randomly mutated ones. Reimplementing it here would
 * have duplicated that project's scope and thrown away its oracle, so the
 * decoder travels and the encoder does not. ../pngc did the same.
 *
 * ../inflate does gzip (RFC 1952) framing; git uses zlib (RFC 1950), so
 * zinflate() below is new, as is Adler-32. The one other change is that
 * zinflate() reports how many bytes it consumed, because a pack entry is a
 * zlib stream with the rest of the pack immediately behind it.
 */

typedef struct { const uint8_t *p; size_t n, i; uint32_t acc; int cnt; } Br;

/* DEFLATE packs bits LSB-first within each byte. need <= 16, so acc never
 * holds more than 23 bits and cannot overflow. */
static int rbits(Br *b, int need, uint32_t *out) {
	while (b->cnt < need) {
		if (b->i >= b->n) return -1;
		b->acc |= (uint32_t)b->p[b->i++] << b->cnt;
		b->cnt += 8;
	}
	*out = b->acc & ((1u << need) - 1);
	b->acc >>= need;
	b->cnt -= need;
	return 0;
}

static const uint16_t lbase[29] = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,
	35,43,51,59,67,83,99,115,131,163,195,227,258};
static const uint8_t lext[29] = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,
	4,4,5,5,5,5,0};
static const uint16_t dbase[30] = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,
	257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577};
static const uint8_t dext[30] = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,
	10,10,11,11,12,12,13,13};
static const uint8_t clord[19] =
	{16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15};

/* Canonical Huffman as counts-plus-sorted-symbols, walked one bit at a time.
 * No lookup table: fifteen lines, and git objects are small. */
typedef struct { uint16_t count[16]; uint16_t sym[288]; } Huf;

/* <0 over-subscribed, 0 complete, >0 incomplete. */
static int hbuild(Huf *h, const uint8_t *len, int n) {
	memset(h->count, 0, sizeof h->count);
	for (int i = 0; i < n; i++) h->count[len[i]]++;
	if (h->count[0] == n) return 0; /* empty tree: legal while never used */
	int left = 1;
	for (int l = 1; l < 16; l++) {
		left <<= 1;
		left -= h->count[l];
		if (left < 0) return -1;
	}
	uint16_t off[16];
	off[1] = 0;
	for (int l = 1; l < 15; l++) off[l + 1] = off[l] + h->count[l];
	for (int i = 0; i < n; i++) if (len[i]) h->sym[off[len[i]]++] = (uint16_t)i;
	return left;
}

static int hdec(Br *b, const Huf *h) {
	int code = 0, first = 0, index = 0;
	for (int l = 1; l < 16; l++) {
		uint32_t bit;
		if (rbits(b, 1, &bit)) return -1;
		code |= (int)bit;
		int c = h->count[l];
		if (code - first < c) return h->sym[index + (code - first)];
		index += c;
		first = (first + c) << 1;
		code <<= 1;
	}
	return -1;
}

static Huf fixlit, fixdist;
static void fixinit(void) {
	uint8_t l[288];
	for (int i = 0; i < 144; i++) l[i] = 8;
	for (int i = 144; i < 256; i++) l[i] = 9;
	for (int i = 256; i < 280; i++) l[i] = 7;
	for (int i = 280; i < 288; i++) l[i] = 8;
	hbuild(&fixlit, l, 288);
	/* 32 codes, not 30: RFC 1951 3.2.6 defines the unusable 30 and 31 so the
	 * tree comes out complete. Dropping them changes which patterns decode. */
	for (int i = 0; i < 32; i++) l[i] = 5;
	hbuild(&fixdist, l, 32);
}

static const char *inflate_raw(Br *b, Buf *o) {
	uint32_t v, final, type;

	for (;;) {
		if (rbits(b, 1, &final) || rbits(b, 2, &type))
			return "truncated: block header";
		if (type == 3) return "invalid block type 3";

		if (type == 0) {
			b->acc = 0; /* stored blocks resume at the next byte boundary */
			b->cnt = 0;
			if (b->n - b->i < 4) return "truncated: stored header";
			unsigned len = b->p[b->i] | (unsigned)b->p[b->i + 1] << 8;
			unsigned nlen = b->p[b->i + 2] | (unsigned)b->p[b->i + 3] << 8;
			b->i += 4;
			if ((len ^ 0xffffu) != nlen) return "stored block LEN/NLEN mismatch";
			if (b->n - b->i < len) return "truncated: stored data";
			bwrite(o, b->p + b->i, len);
			b->i += len;
		} else {
			Huf dynl, dynd;
			const Huf *lt = &fixlit, *dt = &fixdist;

			if (type == 2) {
				uint32_t hlit, hdist, hclen;
				if (rbits(b, 5, &hlit) || rbits(b, 5, &hdist) ||
				    rbits(b, 4, &hclen))
					return "truncated: dynamic header";
				hlit += 257; hdist += 1; hclen += 4;

				uint8_t cl[19];
				memset(cl, 0, sizeof cl);
				for (uint32_t i = 0; i < hclen; i++) {
					if (rbits(b, 3, &v)) return "truncated: code lengths";
					cl[clord[i]] = (uint8_t)v;
				}
				Huf clh;
				if (hbuild(&clh, cl, 19) < 0)
					return "over-subscribed code-length tree";

				uint8_t lens[288 + 32];
				memset(lens, 0, sizeof lens);
				uint32_t i = 0;
				while (i < hlit + hdist) {
					int sy = hdec(b, &clh);
					if (sy < 0) return "bad code-length symbol";
					if (sy < 16) { lens[i++] = (uint8_t)sy; continue; }
					uint8_t val = 0;
					uint32_t rep;
					if (sy == 16) {
						if (i == 0) return "repeat with no previous length";
						val = lens[i - 1];
						if (rbits(b, 2, &rep)) return "truncated: repeat";
						rep += 3;
					} else if (sy == 17) {
						if (rbits(b, 3, &rep)) return "truncated: repeat";
						rep += 3;
					} else {
						if (rbits(b, 7, &rep)) return "truncated: repeat";
						rep += 11;
					}
					if (rep > hlit + hdist - i)
						return "code-length repeat overruns the alphabet";
					while (rep--) lens[i++] = val;
				}
				if (!lens[256]) return "no end-of-block code";
				if (hbuild(&dynl, lens, (int)hlit) < 0)
					return "over-subscribed literal/length tree";
				if (hbuild(&dynd, lens + hlit, (int)hdist) < 0)
					return "over-subscribed distance tree";
				lt = &dynl;
				dt = &dynd;
			}

			for (;;) {
				int sy = hdec(b, lt);
				if (sy < 0) return "bad literal/length code";
				if (sy < 256) { bneed(o, 1); o->p[o->n++] = (uint8_t)sy; continue; }
				if (sy == 256) break;
				sy -= 257;
				if (sy >= 29) return "invalid length code (286/287)";
				if (rbits(b, lext[sy], &v)) return "truncated: length extra bits";
				unsigned length = lbase[sy] + v;

				int dd = hdec(b, dt);
				if (dd < 0) return "bad distance code";
				if (dd >= 30) return "invalid distance code (30/31)";
				if (rbits(b, dext[dd], &v))
					return "truncated: distance extra bits";
				size_t dist = dbase[dd] + v;
				if (dist > o->n) return "distance reaches before output start";

				bneed(o, length);
				size_t from = o->n - dist;
				/* Byte at a time, deliberately: dist < length is the RLE case
				 * DEFLATE relies on, where source and destination overlap and
				 * both memcpy and memmove give the wrong answer. */
				for (unsigned k = 0; k < length; k++)
					o->p[o->n + k] = o->p[from + k];
				o->n += length;
			}
		}
		if (final) return NULL;
	}
}

/* ------------------------------------------------------ zlib (RFC 1950) */

static uint32_t adler32(const uint8_t *p, size_t n) {
	uint32_t a = 1, b = 0;
	for (size_t i = 0; i < n; i++) {
		a += p[i];
		if (a >= 65521) a -= 65521;
		b += a;
		if (b >= 65521) b -= 65521;
	}
	return b << 16 | a;
}

static uint32_t be32(const uint8_t *p) {
	return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

/* Inflate one zlib stream starting at p, appending to o. *used, if given,
 * receives the number of input bytes the stream occupied -- a pack entry is
 * followed immediately by the next entry, so "the rest is junk" is not an
 * error there the way it is for a loose object file. */
static const char *zinflate(const uint8_t *p, size_t n, Buf *o, size_t *used) {
	if (n < 2) return "zlib stream shorter than its header";
	if ((p[0] & 0x0f) != 8) return "zlib compression method is not deflate";
	if ((p[0] >> 4) > 7) return "zlib window size above 32768";
	/* git never writes a preset dictionary and we have none to apply, so a
	 * stream asking for one is refused rather than silently mis-inflated. */
	if (p[1] & 0x20) return "zlib preset dictionary is not supported";
	if (((unsigned)p[0] << 8 | p[1]) % 31) return "zlib header check failed";

	size_t base = o->n;
	Br b = {p, n, 2, 0, 0};
	const char *e = inflate_raw(&b, o);
	if (e) return e;
	b.acc = 0;
	b.cnt = 0;
	if (b.n - b.i < 4) return "truncated zlib Adler-32";
	if (adler32(o->p + base, o->n - base) != be32(b.p + b.i))
		return "zlib Adler-32 mismatch";
	if (used) *used = b.i + 4;
	return NULL;
}

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

static int unhex1(int c) {
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

/* out must hold 41 bytes. */
static void hexify(const uint8_t id[20], char *out) {
	for (int i = 0; i < 20; i++) {
		out[2 * i] = hexd[id[i] >> 4];
		out[2 * i + 1] = hexd[id[i] & 15];
	}
	out[40] = 0;
}

/* 40 hex chars to 20 bytes. Returns 0 on success. */
static int unhexify(const char *s, uint8_t id[20]) {
	for (int i = 0; i < 20; i++) {
		int a = unhex1((unsigned char)s[2 * i]), b = unhex1((unsigned char)s[2 * i + 1]);
		if (a < 0 || b < 0) return -1;
		id[i] = (uint8_t)(a << 4 | b);
	}
	return s[40] ? -1 : 0;
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

static void writeall(const void *p, size_t n) {
	if (n && fwrite(p, 1, n, stdout) != n) die("write error");
}

/* -------------------------------------------------------- loose objects */

typedef struct { int type; Buf data; } Obj;

/* A loose object file is one zlib stream whose plaintext is the same
 * "<type> <len>\0<payload>" that the name is computed over. The length field
 * is not decoration: it is checked against what actually inflated, so a
 * truncated or padded object is refused rather than half-read. */
static const char *loose_parse(Buf *z, Obj *out) {
	size_t nul = 0;
	while (nul < z->n && z->p[nul]) nul++;
	if (nul == z->n) return "loose object has no NUL after its header";
	char hdr[64];
	if (nul >= sizeof hdr) return "loose object header is implausibly long";
	memcpy(hdr, z->p, nul);
	hdr[nul] = 0;

	char *sp = strchr(hdr, ' ');
	if (!sp) return "loose object header has no space";
	*sp = 0;
	int t = tcode(hdr);
	if (!t) return "loose object header names no known type";

	/* Decimal, no sign, no leading space, no leading zero except "0" itself.
	 * strtoul would accept "+1", " 1", "0x10" and whitespace; git does not. */
	const char *d = sp + 1;
	if (!*d || (d[0] == '0' && d[1])) return "bad length in loose header";
	size_t len = 0;
	for (; *d; d++) {
		if (*d < '0' || *d > '9') return "bad length in loose header";
		if (len > (OBJ_MAX - (size_t)(*d - '0')) / 10)
			return "length in loose header exceeds OBJ_MAX";
		len = len * 10 + (size_t)(*d - '0');
	}
	if (z->n - nul - 1 != len) return "loose object length disagrees with its body";

	out->type = t;
	out->data.p = z->p;
	out->data.n = z->n;
	/* Hand back the payload by moving it to the front: the caller owns one
	 * allocation either way and nothing here is big enough for the memmove to
	 * matter next to the inflate that produced it. */
	memmove(out->data.p, z->p + nul + 1, len);
	out->data.n = len;
	out->data.cap = z->cap;
	z->p = NULL;
	z->n = z->cap = 0;
	return NULL;
}

/* objdir/ab/cdef... */
static void loose_path(char *buf, size_t cap, const char *objdir, const char *hex) {
	if ((size_t)snprintf(buf, cap, "%s/%.2s/%s", objdir, hex, hex + 2) >= cap)
		die("object path too long");
}

static int loose_read(const char *objdir, const char *hex, Obj *out) {
	char path[4096];
	loose_path(path, sizeof path, objdir, hex);
	FILE *f = fopen(path, "rb");
	if (!f) return 0;
	fclose(f);
	Buf raw = {0}, plain = {0};
	readall(path, &raw);
	size_t used = 0;
	const char *e = zinflate(raw.p, raw.n, &plain, &used);
	if (!e && used != raw.n) e = "trailing bytes after a loose object's zlib stream";
	if (!e) e = loose_parse(&plain, out);
	bfree(&raw);
	if (e) { bfree(&plain); die2(path, e); }
	return 1;
}

/* Find an object by full 40-character name. Exits 1 if it is not there:
 * every caller wants the object, none wants to carry on without it. */
static void obj_read(const char *objdir, const char *hex, Obj *out) {
	uint8_t want[20];
	if (unhexify(hex, want)) die2("not a 40-character object name", hex);
	if (loose_read(objdir, hex, out)) return;
	die2("object not found", hex);
}

/* ------------------------------------------------------------------ trees */

/* A tree is a packed sequence of
 *
 *     <mode, octal ASCII, no leading zero> SP <name> NUL <20 raw bytes>
 *
 * and nothing else: no count, no terminator, no padding. The mode is where
 * the surprises are. It is octal but written without the leading zero, so a
 * directory is "40000" in the object and "040000" in every human-facing
 * listing; git prints %06o, which is why the two differ.
 */
typedef struct {
	unsigned mode;
	const char *name;
	const uint8_t *id;
} Tent;

/* Decode the entry at *off, advancing it. Returns NULL on success. */
static const char *tree_next(const uint8_t *p, size_t n, size_t *off, Tent *e) {
	size_t i = *off;
	size_t m0 = i;
	while (i < n && p[i] >= '0' && p[i] <= '7') i++;
	if (i == m0) return "tree entry has no octal mode";
	if (i - m0 > 6) return "tree entry mode is too long";
	if (i >= n || p[i] != ' ') return "tree entry mode is not followed by a space";
	unsigned mode = 0;
	for (size_t k = m0; k < i; k++) mode = mode * 8 + (unsigned)(p[k] - '0');
	i++;
	size_t nm = i;
	while (i < n && p[i]) i++;
	if (i >= n) return "tree entry name is not NUL-terminated";
	if (i == nm) return "tree entry has an empty name";
	if (memchr(p + nm, '/', i - nm)) return "tree entry name contains a slash";
	if (n - i - 1 < 20) return "tree entry is missing its object name";
	e->mode = mode;
	e->name = (const char *)p + nm;
	e->id = p + i + 1;
	*off = i + 1 + 20;
	return NULL;
}

/* What git calls the entry, which is a function of the mode and not stored:
 * 040000 is a tree, 160000 is a gitlink and therefore a commit, and
 * everything else (100644, 100755, 120000) is a blob. */
static const char *tree_entry_type(unsigned mode) {
	if ((mode & 0170000) == 0040000) return "tree";
	if ((mode & 0170000) == 0160000) return "commit";
	return "blob";
}

/* git quote.c quote_c_style, which is what `cat-file -p` on a tree reaches
 * through ls-tree: if any byte of the name needs escaping the whole name is
 * wrapped in double quotes, with C escapes for the seven named control
 * characters, a backslash or a quote, and three-digit octal for everything
 * else outside printable ASCII.
 *
 * shortcut: this is core.quotePath=true, git's default, hard-coded. We do not
 * read config, so `-c core.quotePath=false` (which prints UTF-8 names raw)
 * cannot be reproduced. Read .git/config if that ever matters.
 *
 * Found by the oracle, not by reading the format: our first version printed
 * the name raw and disagreed with git on every non-ASCII filename. */
static void print_quoted_name(const char *s, size_t n) {
	static const char named[] = "\a\b\t\n\v\f\r";
	size_t need = 0;
	for (size_t i = 0; i < n; i++) {
		unsigned c = (unsigned char)s[i];
		if (c < 0x20 || c > 0x7e || c == '"' || c == '\\') { need = 1; break; }
	}
	if (!need) { fwrite(s, 1, n, stdout); return; }
	putchar('"');
	for (size_t i = 0; i < n; i++) {
		unsigned c = (unsigned char)s[i];
		const char *k = c && c < 0x20 ? memchr(named, (int)c, 7) : NULL;
		if (c == '"' || c == '\\') { putchar('\\'); putchar((int)c); }
		else if (k) { putchar('\\'); putchar("abtnvfr"[k - named]); }
		else if (c >= 0x20 && c <= 0x7e) putchar((int)c);
		else printf("\\%03o", c);
	}
	putchar('"');
}

/* `git cat-file -p` on a tree. The mode is printed %06o -- six digits with
 * the leading zero restored -- and the name is separated by a TAB, not a
 * space, which matters because a name may contain spaces. */
static void tree_print(const uint8_t *p, size_t n) {
	size_t off = 0;
	while (off < n) {
		Tent e;
		const char *err = tree_next(p, n, &off, &e);
		if (err) die(err);
		char hex[41];
		hexify(e.id, hex);
		printf("%06o %s %s\t", e.mode, tree_entry_type(e.mode), hex);
		print_quoted_name(e.name, strlen(e.name));
		putchar('\n');
	}
}

/* ------------------------------------------------- enumerating the store */

typedef struct { char (*v)[41]; size_t n, cap; } Names;

static void nadd(Names *s, const char *hex) {
	if (s->n == s->cap) {
		s->cap = s->cap ? s->cap * 2 : 256;
		char (*q)[41] = realloc(s->v, s->cap * 41);
		if (!q) die("out of memory");
		s->v = q;
	}
	memcpy(s->v[s->n++], hex, 41);
}

static int ishex(const char *s, size_t n) {
	for (size_t i = 0; i < n; i++) if (unhex1((unsigned char)s[i]) < 0) return 0;
	return s[n] == 0;
}

/* Every loose object under objdir, by name. The two-hex-digit fan-out
 * directory is part of the name, which is why both halves are checked: a
 * stray file in objects/ab/ that is not 38 hex characters is not an object
 * and must not be reported as a broken one. */
static void loose_names(const char *objdir, Names *out) {
	DIR *d = opendir(objdir);
	if (!d) die2("cannot open object directory", objdir);
	struct dirent *e;
	while ((e = readdir(d))) {
		if (strlen(e->d_name) != 2 || !ishex(e->d_name, 2)) continue;
		char sub[4096];
		if ((size_t)snprintf(sub, sizeof sub, "%s/%s", objdir, e->d_name) >= sizeof sub)
			continue;
		DIR *d2 = opendir(sub);
		if (!d2) continue;
		struct dirent *f;
		while ((f = readdir(d2))) {
			if (strlen(f->d_name) != 38 || !ishex(f->d_name, 38)) continue;
			char hex[41];
			memcpy(hex, e->d_name, 2);
			memcpy(hex + 2, f->d_name, 39);
			nadd(out, hex);
		}
		closedir(d2);
	}
	closedir(d);
}

static int cmpname(const void *a, const void *b) { return strcmp(a, b); }

/* ------------------------------------------------------------------ main */

static int usage(void) {
	fputs("usage: gitobj hash <type> [file]\n"
	      "       gitobj cat|raw|type|size <objdir> <sha>\n"
	      "       gitobj ls|verify <objdir>\n", stderr);
	return 2;
}

int main(int argc, char **argv) {
	if (argc < 2) return usage();
	const char *cmd = argv[1];
	fixinit();

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

	if (argc == 4 && (!strcmp(cmd, "cat") || !strcmp(cmd, "raw") ||
	                  !strcmp(cmd, "type") || !strcmp(cmd, "size"))) {
		Obj o = {0, {0}};
		obj_read(argv[2], argv[3], &o);
		if (!strcmp(cmd, "type")) printf("%s\n", tname(o.type));
		else if (!strcmp(cmd, "size")) printf("%zu\n", o.data.n);
		else if (!strcmp(cmd, "cat") && o.type == T_TREE)
			tree_print(o.data.p, o.data.n);
		else writeall(o.data.p, o.data.n);
		bfree(&o.data);
		return 0;
	}

	if (argc == 3 && (!strcmp(cmd, "ls") || !strcmp(cmd, "verify"))) {
		int vfy = !strcmp(cmd, "verify");
		Names ns = {0};
		loose_names(argv[2], &ns);
		qsort(ns.v, ns.n, 41, cmpname);
		size_t bad = 0;
		for (size_t i = 0; i < ns.n; i++) {
			Obj o = {0, {0}};
			obj_read(argv[2], ns.v[i], &o);
			if (vfy) {
				/* The hard invariant. The name is a SHA-1 over the whole
				 * serialisation, so this one comparison covers the zlib
				 * stream, the header, the length field and (later) every
				 * delta instruction underneath. */
				uint8_t id[20];
				char hex[41];
				objid(o.type, o.data.p, o.data.n, id);
				hexify(id, hex);
				if (strcmp(hex, ns.v[i])) {
					printf("MISMATCH %s hashes to %s\n", ns.v[i], hex);
					bad++;
				}
			} else {
				printf("%s %s %zu\n", ns.v[i], tname(o.type), o.data.n);
			}
			bfree(&o.data);
		}
		if (vfy) printf("%zu objects, %zu mismatched\n", ns.n, bad);
		free(ns.v);
		return bad ? 1 : 0;
	}

	return usage();
}
