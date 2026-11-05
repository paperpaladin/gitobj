/* gitobj. git's object database: reads loose objects and pack indexes,
 * writes loose objects, in one C11 file.
 *
 * The four object types, a packfile's v2 index, and the objects behind it,
 * through delta chains of either encoding and any depth. NOT a pack over two
 * gigabytes, which `make test` cannot build and `make bigpack` can. See
 * README.md, which says what else does not work. Both halves of DEFLATE are
 * vendored from ../inflate, where their oracle lives. No libgit2, no zlib,
 * no shelling out to git: git is the authority this is measured against,
 * never a dependency.
 *
 * A git object's name IS the SHA-1 of "<type> <len>\0<payload>", so every
 * read is self-checking: if the bytes we reconstructed hash back to the name
 * we looked them up by, the whole decode path was right. That covers every
 * object in the store, loose or packed; an index entry on its own has no
 * payload to hash, so its own checks are the fanout against the name list and
 * the CRC against the pack. See README.md.
 */
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>

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
	/* memcpy(dst, NULL, 0) is undefined even though it copies nothing, and
	 * the empty tree is exactly that call: a zero-length payload whose
	 * buffer was never allocated. UBSan reports it as a null argument. */
	if (!n) return;
	bneed(b, n);
	memcpy(b->p + b->n, s, n);
	b->n += n;
}
static void bput(Buf *b, unsigned v) { bneed(b, 1); b->p[b->n++] = (uint8_t)v; }
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


#define WIN 32768        /* the sliding window RFC 1951 allows */

/* The three code-length symbols that carry extra bits, 16 to 18. */
static int clextra(int s) { return s == 16 ? 2 : s == 17 ? 3 : s == 18 ? 7 : 0; }

/* ============================================== DEFLATE, the other way ==
 *
 * Vendored from ../inflate, the same way its decoder was, and for the same
 * reason: that project measures this encoder against `gzip -6` over seven
 * corpora and owns the oracle for it. What travels is the tokeniser, the
 * Huffman tree builder and the cost-chosen block boundaries; what does not
 * is gzip framing, which zdeflate() below replaces with zlib's.
 *
 * It replaced an encoder here that emitted stored blocks only, which made a
 * loose object about 1.0003x its payload where git makes one about 0.3x. git
 * read those perfectly and `fsck --strict` was happy with them; nobody would
 * have written a real repository with one.
 */

#define HBITS 15
#define HSIZE (1u << HBITS)
#define NIL 0xffffffffu
#define MINM 3
#define MAXM 258
/*
 * None of these three is a block size: blocks end where the cost says they
 * should. A chunk is the unit a boundary can fall on, and a block is any run
 * of chunks the cost said belonged together, which on uniform input is the
 * whole buffer and at a change of distribution is one chunk.
 *
 * A chunk ends at CHUNK tokens or CHUNKIN input bytes, whichever comes first,
 * and the byte bound is not redundant. Tokens alone are the wrong unit when
 * matches are long: 4096 tokens of 258-byte matches cover a megabyte, and the
 * nearest boundary to a change of distribution is then half a megabyte away.
 * Dropping CHUNKIN costs 3.5% on 20 copies of this file. Both values were
 * swept, and the spread across 1024..32768 was under 0.5% on three corpora,
 * so neither is a tuned constant so much as a resolution.
 *
 * shortcut: MAXTOK bounds how far a block can grow, so a perfectly uniform
 * file pays a tree header every million tokens whether or not it is worth one.
 * The buffer is what forces it; streaming the encoder (item 24) is where that
 * gets revisited.
 */
#define CHUNK 4096
#define CHUNKIN 8192
#define MAXTOK (1u << 20)
#define STOREDMAX 65535 /* a stored block's LEN field is 16 bits */
/*
 * Two knobs, measured in ../inflate rather than guessed, and fixed here
 * because gitobj takes no compression level. `chain_limit` is how far back
 * the hash chain is walked before giving up and `lazy_match` is whether a
 * match is checked against the one starting a byte later. These are the
 * values that project calls level 6, which is gzip's default.
 */
#define chain_limit 128u
#define lazy_match 1

typedef struct { Buf *o; uint32_t acc; int nbits; size_t total; } Bw;

static void wbits(Bw *w, uint32_t v, int n) {
	w->acc |= (v & ((1u << n) - 1)) << w->nbits;
	w->nbits += n;
	w->total += (size_t)n; /* what the cost model is checked against */
	while (w->nbits >= 8) {
		bput(w->o, w->acc & 0xff);
		w->acc >>= 8;
		w->nbits -= 8;
	}
}
static void walign(Bw *w) {
	if (w->nbits) { bput(w->o, w->acc & 0xff); w->acc = 0; w->nbits = 0; }
}
/* Huffman codes are defined MSB-first but the stream is LSB-first, so every
 * code goes out reversed. Extra bits are not codes and go out as-is. */
static void wcode(Bw *w, uint32_t code, int n) {
	uint32_t r = 0;
	for (int i = 0; i < n; i++) { r = (r << 1) | (code & 1); code >>= 1; }
	wbits(w, r, n);
}

/* RFC 1951 3.2.6 fixed literal/length code. */
static void wfix(Bw *w, int sym) {
	if (sym < 144) wcode(w, 0x30u + (uint32_t)sym, 8);
	else if (sym < 256) wcode(w, 0x190u + (uint32_t)sym - 144, 9);
	else if (sym < 280) wcode(w, (uint32_t)sym - 256, 7);
	else wcode(w, 0xC0u + (uint32_t)sym - 280, 8);
}
static int fixbits(int sym) {
	return sym < 144 ? 8 : sym < 256 ? 9 : sym < 280 ? 7 : 8;
}
static int lcode(unsigned len) { int i = 28; while (lbase[i] > len) i--; return i; }
static int dcode(unsigned d) { int i = 29; while (dbase[i] > d) i--; return i; }

typedef struct { uint16_t v, dist; } Tok; /* dist==0 => v is a literal byte */

/* ------------------------------------------- encoder-side Huffman trees */

#define NLIT 286 /* literal/length symbols we can emit: 0..285 */
#define NDIST 30
#define NCL 19
#define MAXSYM 288

/* One Huffman build: merge the two lightest live nodes until one is left, then
 * read each leaf's depth off the parent chain. Returns the longest length, so
 * the caller can tell whether the result is legal.
 *
 * shortcut: linear scan for the two lightest rather than a heap. n is 286 at
 * worst, and the boundary search runs it three times -- literal/length,
 * distance, code-length -- for each of the two or three candidate blocks it
 * prices per chunk, plus once more per halving. That is the hot path now, and
 * it still does not reach a profile: 4% more encode time than the fixed 32KB
 * boundary it replaced. Swap in a heap if the chunk ever gets smaller. */
static int huf1(const uint32_t *freq, int n, uint8_t *len) {
	uint32_t w[2 * MAXSYM];
	int dad[2 * MAXSYM], live[MAXSYM], nlive = 0, next = n;

	for (int i = 0; i < n; i++) {
		len[i] = 0;
		dad[i] = -2; /* -2: unused symbol, not a leaf of this tree at all */
		if (freq[i]) { w[i] = freq[i]; dad[i] = -1; live[nlive++] = i; }
	}
	/* RFC 1951 has no zero-bit code, so an alphabet used once or not at all
	 * still needs two leaves to make a complete tree. A block of pure literals
	 * reaches here: it carries a distance tree it never consults. */
	for (int i = 0; i < n && nlive < 2; i++)
		if (dad[i] == -2) { w[i] = 1; dad[i] = -1; live[nlive++] = i; }

	while (nlive > 1) {
		int a = 0, b = 1;
		if (w[live[1]] < w[live[0]]) { a = 1; b = 0; }
		for (int i = 2; i < nlive; i++) {
			if (w[live[i]] < w[live[a]]) { b = a; a = i; }
			else if (w[live[i]] < w[live[b]]) b = i;
		}
		int x = live[a], y = live[b];
		w[next] = w[x] + w[y];
		dad[x] = dad[y] = next;
		dad[next] = -1; /* overwritten unless this turns out to be the root */
		live[a] = next++;
		live[b] = live[--nlive];
	}

	int longest = 0;
	for (int i = 0; i < n; i++) {
		if (dad[i] == -2) continue;
		int d = 0;
		for (int p = dad[i]; p >= 0; p = dad[p]) d++;
		len[i] = (uint8_t)d;
		if (d > longest) longest = d;
	}
	return longest;
}

/* Code lengths for freq[0..n), none longer than maxlen bits.
 *
 * shortcut: over-long codes are corrected by halving every frequency and
 * rebuilding, not by package-merge. Halving strictly shrinks every weight above
 * 1, so the loop ends at worst with a flat distribution, and 288 equally likely
 * symbols is a 9-bit tree -- comfortably inside 15. The cost is a slightly
 * suboptimal code on the rare block whose natural tree is deeper than the
 * format allows. Package-merge is the upgrade if that ever shows up in a ratio
 * measurement rather than in theory. */
static void huflen(const uint32_t *freq, int n, int maxlen, uint8_t *len) {
	uint32_t f[MAXSYM];
	memcpy(f, freq, (size_t)n * sizeof *f);
	while (huf1(f, n, len) > maxlen)
		for (int i = 0; i < n; i++) f[i] = (f[i] + 1) / 2; /* 0 stays 0, 1 stays 1 */
}

/* Canonical codes from lengths, RFC 1951 3.2.2: shorter codes numerically
 * first, and within one length, lower symbol numbers first. */
static void hufcode(const uint8_t *len, int n, uint16_t *code) {
	uint16_t cnt[16] = {0}, next[16];
	for (int i = 0; i < n; i++) cnt[len[i]]++;
	cnt[0] = 0; /* unused symbols get no code and must not shift the others */
	uint16_t c = 0;
	for (int l = 1; l < 16; l++) next[l] = c = (uint16_t)((c + cnt[l - 1]) << 1);
	for (int i = 0; i < n; i++) if (len[i]) code[i] = next[len[i]]++;
}

/* Run-length codes the concatenated literal/length and distance lengths into
 * the 19-symbol code-length alphabet (RFC 1951 3.2.7), writing one symbol per
 * slot of sym[] with its extra-bit payload in extra[]. Returns how many.
 *
 * Repeats are allowed to cross from the last literal/length code into the first
 * distance code; the RFC says so explicitly, and the decoder above reads both
 * halves out of one array for exactly that reason. */
static int clpack(const uint8_t *len, int n, uint8_t *sym, uint8_t *extra) {
	int m = 0;
	for (int i = 0; i < n; ) {
		int v = len[i], run = 1;
		while (i + run < n && len[i + run] == v) run++;
		i += run;
		if (v == 0) {
			while (run >= 11) {
				int r = run > 138 ? 138 : run;
				sym[m] = 18; extra[m++] = (uint8_t)(r - 11); run -= r;
			}
			if (run >= 3) { sym[m] = 17; extra[m++] = (uint8_t)(run - 3); run = 0; }
		} else {
			/* Symbol 16 repeats the previous length, so the first one is
			 * always spelled out. */
			sym[m] = (uint8_t)v; extra[m++] = 0;
			run--;
			while (run >= 3) {
				int r = run > 6 ? 6 : run;
				sym[m] = 16; extra[m++] = (uint8_t)(r - 3); run -= r;
			}
		}
		while (run-- > 0) { sym[m] = (uint8_t)v; extra[m++] = 0; }
	}
	return m;
}

static uint32_t hash3(const uint8_t *p) {
	uint32_t k = (uint32_t)p[0] << 16 | (uint32_t)p[1] << 8 | p[2];
	return (k * 2654435761u) >> (32 - HBITS);
}

/* Longest match for the bytes at `pos`, searching the hash chain back at most
 * CHAIN links and WIN bytes. Returns 0 if nothing reaches MINM, otherwise the
 * length, with the distance in *distp.
 *
 * It reads head[] and never writes it, which is what lets the caller run it at
 * pos and again at pos+1 without touching the chains in between. Inserting a
 * position before searching it would find the position itself at distance 0,
 * and inserting one twice leaves prev[p] == p, which is a chain that never
 * ends. */
static unsigned match_at(const uint8_t *in, size_t n, size_t pos,
                         const uint32_t *head, const uint32_t *prev,
                         size_t *distp)
{
	unsigned best = 0;
	size_t bestd = 0;

	if (n - pos >= MINM) {
		size_t max = n - pos < MAXM ? n - pos : MAXM;
		uint32_t c = head[hash3(in + pos)];
		for (unsigned tries = chain_limit; c != NIL && tries; tries--) {
			if (pos - c > WIN) break;
			if (in[c + best] == in[pos + best]) { /* cheap reject */
				unsigned k = 0;
				while (k < max && in[c + k] == in[pos + k]) k++;
				if (k > best) {
					best = k;
					bestd = pos - c;
					if (best == max) break;
				}
			}
			c = prev[c];
		}
	}
	*distp = bestd;
	return best < MINM ? 0 : best;
}

/* ---------------------------------------- cost-chosen block boundaries */

/*
 * Symbol counts for a span of tokens, plus what that span covers. A block's
 * cost depends only on these counts, never on the tokens themselves, which is
 * what makes a boundary search affordable: merging a candidate chunk into the
 * running block is 316 additions rather than a second pass over a million
 * tokens.
 */
typedef struct {
	uint32_t l[NLIT], d[NDIST];
	size_t bytes, ntok;
} Fr;

static void fr_zero(Fr *f) { memset(f, 0, sizeof *f); }

static void fr_add(Fr *a, const Fr *b) {
	for (int i = 0; i < NLIT; i++) a->l[i] += b->l[i];
	for (int i = 0; i < NDIST; i++) a->d[i] += b->d[i];
	a->bytes += b->bytes;
	a->ntok += b->ntok;
}

static void fr_tok(Fr *f, Tok t) {
	if (!t.dist) {
		f->l[t.v]++;
		f->bytes += 1;
	} else {
		f->l[257 + lcode(t.v)]++;
		f->d[dcode(t.dist)]++;
		f->bytes += t.v;
	}
	f->ntok++;
}

/* Everything the dynamic branch puts on the wire, and which block type won. */
typedef struct {
	uint8_t llen[NLIT], dlen[NDIST], cllen[NCL];
	uint16_t lcod[NLIT], dcod[NDIST], clcod[NCL];
	uint8_t cls[NLIT + NDIST], clx[NLIT + NDIST];
	int ncls, nlit, ndist, hclen;
	int type; /* 0 stored, 1 fixed, 2 dynamic */
} Trees;

/* Trees fitted to these counts, plus the exact bit cost of the dynamic block
 * that would carry them, header included. The fixed codes are a guess, made
 * once in RFC 1951, about what a block looks like; on this project's own
 * source they cost 35% over gzip -6 and no amount of better matching recovers
 * it, because the frequencies never reach a tree at all.
 *
 * The cost is summed per symbol rather than per token, which is the same
 * number and is what lets a candidate boundary be priced without walking the
 * tokens again. */
static long dyn_trees(const Fr *f, Trees *t) {
	uint32_t lfreq[NLIT];
	memcpy(lfreq, f->l, sizeof lfreq);
	lfreq[256] = 1; /* end of block, emitted exactly once */

	huflen(lfreq, NLIT, 15, t->llen);
	huflen(f->d, NDIST, 15, t->dlen);
	hufcode(t->llen, NLIT, t->lcod);
	hufcode(t->dlen, NDIST, t->dcod);

	/* Trailing unused lengths are not sent; RFC 1951 floors the counts at
	 * 257 literal/length codes and 1 distance code. */
	t->nlit = NLIT;
	while (t->nlit > 257 && !t->llen[t->nlit - 1]) t->nlit--;
	t->ndist = NDIST;
	while (t->ndist > 1 && !t->dlen[t->ndist - 1]) t->ndist--;

	uint8_t both[NLIT + NDIST];
	memcpy(both, t->llen, (size_t)t->nlit);
	memcpy(both + t->nlit, t->dlen, (size_t)t->ndist);
	t->ncls = clpack(both, t->nlit + t->ndist, t->cls, t->clx);

	uint32_t cfreq[NCL] = {0};
	for (int i = 0; i < t->ncls; i++) cfreq[t->cls[i]]++;
	huflen(cfreq, NCL, 7, t->cllen); /* 3 bits each on the wire, so 7 is the cap */
	hufcode(t->cllen, NCL, t->clcod);
	t->hclen = NCL;
	while (t->hclen > 4 && !t->cllen[clord[t->hclen - 1]]) t->hclen--;

	long bits = 3 + 5 + 5 + 4 + 3 * (long)t->hclen;
	for (int i = 0; i < t->ncls; i++)
		bits += t->cllen[t->cls[i]] + clextra(t->cls[i]);
	for (int s = 0; s < NLIT; s++) bits += (long)lfreq[s] * t->llen[s];
	for (int lc = 0; lc < 29; lc++) bits += (long)lfreq[257 + lc] * lext[lc];
	for (int dc = 0; dc < NDIST; dc++)
		bits += (long)f->d[dc] * (t->dlen[dc] + dext[dc]);
	return bits;
}

static long fixed_cost(const Fr *f) {
	long bits = 3 + 7; /* block header, plus the 7-bit fixed code for EOB */
	for (int s = 0; s < 256; s++) bits += (long)f->l[s] * fixbits(s);
	for (int lc = 0; lc < 29; lc++)
		bits += (long)f->l[257 + lc] * (fixbits(257 + lc) + lext[lc]);
	for (int dc = 0; dc < NDIST; dc++)
		bits += (long)f->d[dc] * (5 + dext[dc]);
	return bits;
}

/* A stored block's LEN is 16 bits, so a long one goes out in pieces and each
 * piece pays its own header, byte alignment and LEN/NLEN pair. Before blocks
 * could outgrow 32KB this could not happen. */
static long stored_cost(size_t bytes) {
	size_t parts = bytes ? (bytes + STOREDMAX - 1) / STOREDMAX : 1;
	return (long)parts * (3 + 7 + 32) + 8 * (long)bytes; /* 7 = worst-case padding */
}

/* What this span would actually cost, by the cheapest of the three block
 * types, with the dynamic trees built as a side effect. */
static long block_cost(const Fr *f, Trees *t) {
	long best = dyn_trees(f, t), fix = fixed_cost(f), st = stored_cost(f->bytes);
	t->type = 2;
	if (fix < best) { best = fix; t->type = 1; }
	if (st < best) { best = st; t->type = 0; }
	return best;
}

static void emit_block(Bw *w, const uint8_t *in, size_t bstart, const Fr *f,
                       const Tok *tok, size_t lo, size_t hi, int final)
{
	Trees t;
	long cost = block_cost(f, &t);
	size_t before = w->total;

	if (t.type == 2) {
		wbits(w, (uint32_t)final, 1);
		wbits(w, 2, 2); /* BTYPE 10: dynamic Huffman */
		wbits(w, (uint32_t)(t.nlit - 257), 5);
		wbits(w, (uint32_t)(t.ndist - 1), 5);
		wbits(w, (uint32_t)(t.hclen - 4), 4);
		for (int i = 0; i < t.hclen; i++) wbits(w, t.cllen[clord[i]], 3);
		for (int i = 0; i < t.ncls; i++) {
			wcode(w, t.clcod[t.cls[i]], t.cllen[t.cls[i]]);
			wbits(w, t.clx[i], clextra(t.cls[i]));
		}
		for (size_t i = lo; i < hi; i++) {
			if (!tok[i].dist) {
				wcode(w, t.lcod[tok[i].v], t.llen[tok[i].v]);
				continue;
			}
			int lc = lcode(tok[i].v), dc = dcode(tok[i].dist);
			wcode(w, t.lcod[257 + lc], t.llen[257 + lc]);
			wbits(w, (uint32_t)(tok[i].v - lbase[lc]), lext[lc]);
			wcode(w, t.dcod[dc], t.dlen[dc]);
			wbits(w, (uint32_t)(tok[i].dist - dbase[dc]), dext[dc]);
		}
		wcode(w, t.lcod[256], t.llen[256]);
	} else if (t.type == 1) {
		wbits(w, (uint32_t)final, 1);
		wbits(w, 1, 2); /* BTYPE 01: fixed Huffman */
		for (size_t i = lo; i < hi; i++) {
			if (!tok[i].dist) { wfix(w, tok[i].v); continue; }
			int lc = lcode(tok[i].v), dc = dcode(tok[i].dist);
			wfix(w, 257 + lc);
			wbits(w, (uint32_t)(tok[i].v - lbase[lc]), lext[lc]);
			wcode(w, (uint32_t)dc, 5);
			wbits(w, (uint32_t)(tok[i].dist - dbase[dc]), dext[dc]);
		}
		wfix(w, 256);
	} else {
		/* Incompressible run: a stored block is 5 bytes of overhead instead
		 * of the ~5% a Huffman pass costs on random data. */
		size_t left = f->bytes, off = bstart;
		do {
			unsigned L = left > STOREDMAX ? STOREDMAX : (unsigned)left;
			wbits(w, (uint32_t)(final && left == L), 1);
			wbits(w, 0, 2);
			walign(w);
			unsigned N = ~L & 0xffffu;
			bput(w->o, L & 0xff);
			bput(w->o, L >> 8);
			bput(w->o, N & 0xff);
			bput(w->o, N >> 8);
			bwrite(w->o, in + off, L);
			off += L;
			left -= L;
		} while (left);
	}

	/*
	 * The boundary chooser spent its whole run comparing predicted costs, so
	 * a prediction that does not match what the writer emitted means every
	 * boundary in the file was picked on a fiction. Checked for the two coded
	 * types, which are accounted bit for bit; a stored block's byte alignment
	 * is a worst case, not a count.
	 */
	if (t.type && w->total - before != (size_t)cost)
		die("internal: block cost mispredicted");
}

/* The same encoder behind zlib framing instead of gzip's: two header bytes
 * and a big-endian Adler-32, where ../inflate writes ten and a little-endian
 * CRC-32 with the input size after it. 0x78 0x9c is deflate, a 32KiB window,
 * no preset dictionary, and (0x78 << 8 | 0x9c) % 31 == 0, which is the check
 * zinflate() enforces above. */
static void zdeflate(const uint8_t *in, size_t n, Buf *o) {
	static const uint8_t hdr[2] = {0x78, 0x9c};
	bwrite(o, hdr, 2);

	uint32_t *head = malloc(HSIZE * sizeof *head);
	/* shortcut: prev[] is one slot per input byte rather than one per window
	 * slot, so peak memory is 4n. Switch to a 32K ring and stream the input
	 * when a file stops fitting in RAM. */
	uint32_t *prev = malloc((n ? n : 1) * sizeof *prev);
	/* One token per input byte is the worst case, so a small input never
	 * pays for the whole buffer. */
	size_t cap = n + 1 < MAXTOK ? n + 1 : MAXTOK;
	Tok *tok = malloc(cap * sizeof *tok);
	if (!head || !prev || !tok) die("out of memory");
	for (uint32_t i = 0; i < HSIZE; i++) head[i] = NIL;

	Bw w = {o, 0, 0, 0};
	size_t pos = 0;    /* next input byte to tokenize */
	size_t ntok = 0;   /* tokens buffered in this span */
	size_t btok = 0;   /* first token of the block being accumulated */
	size_t bstart = 0; /* input offset of that block */
	Fr a, c, b;        /* block so far, candidate chunk, the two merged */
	long ca = 0;       /* cost of `a` as its own block */
	fr_zero(&a);

	for (;;) { /* one pass per chunk, so a zero-byte input still emits a block */
		size_t cstart = ntok;
		fr_zero(&c);

		while (pos < n && ntok - cstart < CHUNK && c.bytes < CHUNKIN && ntok < cap) {
			size_t bestd;
			unsigned best = match_at(in, n, pos, head, prev, &bestd);

			/*
			 * Lazy evaluation. A greedy matcher takes this match; starting
			 * one byte later can give a longer one, and when it does, the
			 * byte at pos is cheaper spent as a literal. Only a strictly
			 * longer match justifies it -- equal length would cost the
			 * literal for nothing.
			 *
			 * Nothing is inserted into the chains before the lookahead, so
			 * the search at pos+1 cannot see pos itself. The only match that
			 * loses is a distance-1 run, which the search at pos has already
			 * found and which therefore wins the comparison anyway.
			 */
			if (lazy_match && best && best < MAXM && pos + 1 < n) {
				size_t nextd;
				unsigned next = match_at(in, n, pos + 1, head, prev, &nextd);
				if (next > best) {
					tok[ntok].v = in[pos];
					tok[ntok].dist = 0;
					fr_tok(&c, tok[ntok]);
					ntok++;
					if (n - pos >= MINM) {
						uint32_t h = hash3(in + pos);
						prev[pos] = head[h];
						head[h] = (uint32_t)pos;
					}
					pos++;
					continue;
				}
			}

			unsigned adv = best ? best : 1;
			if (best) {
				tok[ntok].v = (uint16_t)best;
				tok[ntok].dist = (uint16_t)bestd;
			} else {
				tok[ntok].v = in[pos];
				tok[ntok].dist = 0;
			}
			fr_tok(&c, tok[ntok]);
			ntok++;

			/* Insert every covered position, not just block starts: a match
			 * that skips bytes still has to leave them findable. */
			for (unsigned k = 0; k < adv; k++) {
				size_t p = pos + k;
				if (n - p < MINM) break;
				uint32_t h = hash3(in + p);
				prev[p] = head[h];
				head[h] = (uint32_t)p;
			}
			pos += adv;
		}

		int at_end = pos >= n, full = ntok >= cap;

		/*
		 * The boundary decision, and the whole point of this shape. A block
		 * ends where the symbol distribution changes, not on a round number:
		 * if this chunk is cheaper carrying its own tree than folded into the
		 * block in progress, the block ends here. On uniform input the merged
		 * cost always wins, because one header is cheaper than two, and the
		 * block grows until the buffer forces a boundary.
		 */
		if (c.ntok) {
			Trees t;
			if (!a.ntok) {
				a = c;
				ca = block_cost(&a, &t);
			} else {
				long cc = block_cost(&c, &t);
				b = a;
				fr_add(&b, &c);
				long cb = block_cost(&b, &t);
				if (ca + cc < cb) {
					emit_block(&w, in, bstart, &a, tok, btok, cstart, 0);
					bstart += a.bytes;
					btok = cstart;
					a = c;
					ca = cc;
				} else {
					a = b;
					ca = cb;
				}
			}
		}

		if (at_end || full) {
			emit_block(&w, in, bstart, &a, tok, btok, ntok, at_end);
			if (at_end) break;
			/* Buffer full: the span restarts, which forces a boundary here. */
			bstart = pos;
			btok = ntok = 0;
			fr_zero(&a);
			ca = 0;
		}
	}

	walign(&w);
	/* Adler-32, big-endian, over the plaintext: RFC 1950's whole trailer. */
	uint32_t ad = adler32(in, n);
	for (int i = 3; i >= 0; i--) bput(o, (ad >> (8 * i)) & 0xff);

	free(head);
	free(prev);
	free(tok);
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
/* "<type> <len>", with the NUL counted in the returned length. One function
 * because the writer must emit exactly the bytes the name is hashed over: two
 * copies of this would be two chances to disagree, and the disagreement would
 * be an object whose name is not its own hash. */
static size_t objhdr(char buf[64], int type, size_t n) {
	int k = snprintf(buf, 64, "%s %zu", tname(type), n);
	return (size_t)k + 1;
}

static void objid(int type, const uint8_t *p, size_t n, uint8_t id[20]) {
	char hdr[64];
	size_t k = objhdr(hdr, type, n);
	Sha1 s;
	sha1_init(&s);
	sha1_update(&s, hdr, k);
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

/* Is there a loose file for this name? Asked for the census only: the
 * reader does not care which half of the store an object came from. */
static int loose_exists(const char *objdir, const char *hex) {
	char path[4096];
	loose_path(path, sizeof path, objdir, hex);
	return access(path, R_OK) == 0;
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

/* Store an object as a loose file, the way git does: the bytes go to a
 * temporary name in the fan-out directory and are renamed into place, so no
 * reader ever opens a half-written file under a name that promises a
 * particular hash. An object already present is left alone, which is what
 * makes a second write of the same content a no-op rather than a rewrite.
 *
 * shortcut: the temporary name carries only the pid, so two writers in one
 * process writing concurrently would collide. gitobj is single-threaded and
 * writes one object per run; mkstemp if that ever stops being true. */
static void loose_write(const char *objdir, const char *hex, int type,
                        const uint8_t *p, size_t n) {
	char dir[4096], path[4096], tmp[4096];
	if ((size_t)snprintf(dir, sizeof dir, "%s/%.2s", objdir, hex) >= sizeof dir)
		die("object path too long");
	loose_path(path, sizeof path, objdir, hex);
	if ((size_t)snprintf(tmp, sizeof tmp, "%s/tmp_gitobj_%ld", dir,
	                     (long)getpid()) >= sizeof tmp)
		die("object path too long");
	if (mkdir(dir, 0777) && errno != EEXIST) die2("cannot create", dir);

	FILE *have = fopen(path, "rb");
	if (have) { fclose(have); return; }

	Buf plain = {0}, z = {0};
	char hdr[64];
	bwrite(&plain, hdr, objhdr(hdr, type, n));
	bwrite(&plain, p, n);
	zdeflate(plain.p, plain.n, &z);
	bfree(&plain);

	FILE *f = fopen(tmp, "wb");
	if (!f) die2("cannot create", tmp);
	int bad = z.n && fwrite(z.p, 1, z.n, f) != z.n;
	if (fclose(f) || bad) { remove(tmp); die2("write error", tmp); }
	bfree(&z);
	/* rename, not link: a file that appeared under this name while we were
	 * compressing holds the same content by definition, so replacing it is
	 * harmless and losing the race is not worth a branch. */
	if (rename(tmp, path)) { remove(tmp); die2("cannot store", path); }
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

/* ------------------------------------------------------ building trees */

/* `git mktree` format, one entry per line:
 *
 *     <mode> SP <type> SP <40 hex> TAB <name>
 *
 * which is exactly what `git ls-tree` and our own `cat` of a tree print, so
 * a tree can be read out of one repository and rebuilt in another. The name
 * is C-quoted when it needs to be, so this needs the inverse of
 * print_quoted_name as well as the sort rule.
 */
typedef struct { unsigned mode; uint8_t id[20]; char *name; size_t nlen; } Ment;

/* git's base_name_compare. Entries are sorted as if every directory name
 * carried a trailing slash, so "a/" falls between "a.c" and "a0" rather than
 * sorting with the plain names: '.' is 0x2e, '/' is 0x2f and '0' is 0x30.
 * Getting this wrong produces a tree whose bytes git refuses -- `fsck` calls
 * it treeNotSorted -- so it is not a cosmetic ordering.
 *
 * name is NUL-terminated, which is why reading name[m] is in bounds when m
 * is the shorter length: the terminator is the byte compared against the
 * longer name, and the slash is substituted for it only for a directory. */
static int mentcmp(const void *va, const void *vb) {
	const Ment *a = va, *b = vb;
	size_t m = a->nlen < b->nlen ? a->nlen : b->nlen;
	int c = memcmp(a->name, b->name, m);
	if (c) return c;
	unsigned char c1 = (unsigned char)a->name[m], c2 = (unsigned char)b->name[m];
	if (!c1 && (a->mode & 0170000) == 0040000) c1 = '/';
	if (!c2 && (b->mode & 0170000) == 0040000) c2 = '/';
	return c1 < c2 ? -1 : c1 > c2;
}

/* The inverse of print_quoted_name: git quote.c unquote_c_style. A name is
 * quoted only if it needs to be, so an unquoted line is taken verbatim --
 * including any backslash in it, which is why the leading quote decides and
 * not the presence of an escape. Returns a NUL-terminated buffer the caller
 * owns, or NULL if the quoting is malformed. */
static char *unquote_name(const char *s, size_t n, size_t *outn) {
	char *o = malloc(n + 1);
	if (!o) die("out of memory");
	size_t k = 0;
	if (!n || s[0] != '"') {
		memcpy(o, s, n);
		o[n] = 0;
		*outn = n;
		return o;
	}
	size_t i = 1;
	for (;;) {
		if (i >= n) { free(o); return NULL; }   /* no closing quote */
		char c = s[i++];
		if (c == '"') break;
		if (c != '\\') { o[k++] = c; continue; }
		if (i >= n) { free(o); return NULL; }
		char e = s[i++];
		switch (e) {
		case 'a': o[k++] = '\a'; break;
		case 'b': o[k++] = '\b'; break;
		case 't': o[k++] = '\t'; break;
		case 'n': o[k++] = '\n'; break;
		case 'v': o[k++] = '\v'; break;
		case 'f': o[k++] = '\f'; break;
		case 'r': o[k++] = '\r'; break;
		case '"': case '\\': o[k++] = e; break;
		default:
			if (e < '0' || e > '7') { free(o); return NULL; }
			{
				unsigned v = (unsigned)(e - '0');
				for (int d = 0; d < 2 && i < n && s[i] >= '0' && s[i] <= '7'; d++)
					v = v * 8 + (unsigned)(s[i++] - '0');
				if (v > 255) { free(o); return NULL; }
				o[k++] = (char)v;
			}
		}
	}
	if (i != n) { free(o); return NULL; }       /* trailing junk after the quote */
	o[k] = 0;
	*outn = k;
	return o;
}

/* One line into one entry. Returns NULL on success.
 *
 * shortcut: the declared type is checked against the mode and nothing else.
 * git mktree additionally looks the object up and refuses an entry whose
 * stored type disagrees, while still allowing an object that is absent (that
 * is how a gitlink to a commit in another repository is written at all). We
 * have the object directory here and could do the same for the present ones;
 * until then `fsck` is what catches a tree pointing at the wrong thing. */
static const char *parse_mkline(const char *p, size_t n, Ment *e) {
	size_t i = 0, d0 = 0;
	unsigned mode = 0;
	while (i < n && p[i] >= '0' && p[i] <= '7') {
		mode = mode * 8 + (unsigned)(p[i] - '0');
		i++;
	}
	if (i == d0 || i - d0 > 6) return "mktree input: entry has no octal mode";
	if (mode != 0100644 && mode != 0100755 && mode != 0120000 &&
	    mode != 0040000 && mode != 0160000)
		return "mktree input: mode is not one git uses";
	if (i >= n || p[i] != ' ') return "mktree input: mode is not followed by a space";
	i++;
	size_t t0 = i;
	while (i < n && p[i] != ' ') i++;
	if (i >= n) return "mktree input: type is not followed by a space";
	const char *want = tree_entry_type(mode);
	if (i - t0 != strlen(want) || memcmp(p + t0, want, i - t0))
		return "mktree input: type does not match the mode";
	i++;
	if (n - i < 41 || p[i + 40] != '\t')
		return "mktree input: object name is not 40 characters followed by a tab";
	char hex[41];
	memcpy(hex, p + i, 40);
	hex[40] = 0;
	if (unhexify(hex, e->id)) return "mktree input: object name is not hex";
	i += 41;
	e->name = unquote_name(p + i, n - i, &e->nlen);
	if (!e->name) return "mktree input: name is not validly quoted";
	if (!e->nlen) return "mktree input: entry has an empty name";
	if (memchr(e->name, '/', e->nlen)) return "mktree input: name contains a slash";
	if (memchr(e->name, 0, e->nlen)) return "mktree input: name contains a NUL";
	e->mode = mode;
	return NULL;
}

/* Build the tree object. The mode goes out as %o, so 040000 in the input is
 * 40000 in the object: the leading zero exists only in the printed form. */
static void tree_build(Ment *v, size_t n, Buf *out) {
	/* qsort(NULL, 0, ...) is undefined, and the empty tree is exactly that
	 * call. UBSan caught it: the released build happily produced
	 * 4b825dc... while the sanitiser build refused to run at all. */
	if (n) qsort(v, n, sizeof *v, mentcmp);
	for (size_t i = 0; i < n; i++) {
		char m[16];
		int k = snprintf(m, sizeof m, "%o ", v[i].mode);
		bwrite(out, m, (size_t)k);
		bwrite(out, v[i].name, v[i].nlen + 1);  /* the NUL is part of the entry */
		bwrite(out, v[i].id, 20);
	}
}

/* ----------------------------------------------------- commits and tags */

/* Commits and tags share one shape: a block of "<key> SP <value> LF" header
 * lines, a single empty line, then the message verbatim to the end of the
 * object. Two details are where implementations part company.
 *
 * Folding. A header value may continue onto following lines, each of which
 * begins with one space that is NOT part of the value. This is how "gpgsig"
 * carries a whole PGP armor block, and it is why the blank line inside that
 * armor is stored as a line containing exactly one space -- so the "LF LF"
 * that ends the header block is still unambiguous. A parser that splits on
 * the first blank line without understanding folding gets the right answer
 * only because git was careful here.
 *
 * The message. It is bytes, not text: CRLF line endings and trailing
 * whitespace are part of the object and part of its name, so nothing here
 * trims, re-encodes or normalises anything. The "encoding" header says what
 * those bytes mean; it does not change them.
 */

/* Offset of the message, i.e. one past the empty line. Returns n if the
 * object is all headers and has no message at all. */
static size_t msg_start(const uint8_t *p, size_t n) {
	size_t i = 0;
	while (i < n) {
		const uint8_t *eol = memchr(p + i, '\n', n - i);
		if (!eol) die("commit/tag header line is not LF-terminated");
		if (eol == p + i) return i + 1;
		i = (size_t)(eol - p) + 1;
	}
	return n;
}

/* Print every value of one header, unfolded, one per line. Returns how many
 * were found: "parent" legitimately appears zero times (a root commit) or
 * many (a merge), so the count is the answer and not an error. */
static int hdr_print(const uint8_t *p, size_t n, const char *key) {
	size_t klen = strlen(key), i = 0, end = msg_start(p, n);
	int found = 0;
	while (i < end) {
		const uint8_t *eol = memchr(p + i, '\n', end - i);
		if (!eol) break;
		size_t len = (size_t)(eol - (p + i));
		if (!len) break;
		const uint8_t *sp = memchr(p + i, ' ', len);
		if (!sp) die("commit/tag header line has no space after its key");
		size_t thisk = (size_t)(sp - (p + i));
		int match = thisk == klen && !memcmp(p + i, key, klen);
		size_t vs = (size_t)(sp - p) + 1, ve = (size_t)(eol - p);
		i = ve + 1;
		if (match) { found++; writeall(p + vs, ve - vs); }
		/* Continuation lines: one leading space, stripped. */
		while (i < end && p[i] == ' ') {
			const uint8_t *e2 = memchr(p + i, '\n', end - i);
			if (!e2) die("folded header line is not LF-terminated");
			if (match) {
				putchar('\n');
				writeall(p + i + 1, (size_t)(e2 - p) - i - 1);
			}
			i = (size_t)(e2 - p) + 1;
		}
		if (match) putchar('\n');
	}
	return found;
}

/* ===================================================== the pack v2 index ==
 *
 * A .idx is a lookup table over the .pack beside it, and nothing in it is
 * self-describing: the object count comes from the last fanout entry and the
 * length of the 64-bit offset table is whatever is left over once everything
 * else has been accounted for. So the size arithmetic is the first check, not
 * a sanity check, and every field read below happens after it.
 *
 *     "\377tOc"              magic, chosen to be impossible in a v1 index
 *     uint32 2               version
 *     uint32 fanout[256]     CUMULATIVE: fanout[i] is how many names have a
 *                            first byte <= i, so fanout[255] is the count
 *     uint8  name[n][20]     sorted ascending
 *     uint32 crc[n]          CRC-32 of the object's bytes AS PACKED
 *     uint32 off[n]          pack offset, or, with the top bit set, an index
 *                            into the table below
 *     uint64 off64[m]        offsets at or above 2^31
 *     uint8  packsum[20]     the .pack's own trailing checksum
 *     uint8  idxsum[20]      SHA-1 of everything above
 *
 * Three of those are cross-checks rather than data, and they are the reason
 * the format is worth reading carefully: the fanout has to agree with the
 * name list it indexes, the CRC has to agree with the pack, and the declared
 * count has to agree with the file's own size.
 */

#define IDX_HDR 1032             /* magic, version, 256 fanout entries */
#define IDX_TRAIL 40             /* the two checksums */
#define IDX_ENT 28               /* name + crc + 32-bit offset, per object */

typedef struct {
	Buf raw;
	size_t n, nbig;
	const uint8_t *fan, *names, *crcs, *off32, *off64;
	size_t via32, via64;         /* which offset path each object took */
} Idx;

static uint64_t be64(const uint8_t *p) {
	return (uint64_t)be32(p) << 32 | be32(p + 4);
}

/* A refusal has to say where. "corrupt index" sends a reader back to a
 * megabyte of binary with nothing to look at; an entry number or a byte
 * offset is the whole difference between a message and a diagnosis.
 *
 * Two shapes, kept apart because they are not the same claim: dieat() gives a
 * position to look at, dieval() gives the value the file declared. Reporting
 * a count as though it were an offset is how a diagnosis starts being wrong. */
static void dieat(const char *m, size_t at) {
	fprintf(stderr, "gitobj: %s at %zu\n", m, at);
	exit(1);
}
static void dieval(const char *m, size_t v) {
	fprintf(stderr, "gitobj: %s: %zu\n", m, v);
	exit(1);
}

/* Shrink an allocation to exactly what was read. readall() doubles, so a
 * 4MB pack sits in an 8MB block and a read one byte past the end lands
 * megabytes inside a live allocation, where ASan cannot see it. Every length
 * in an index is a number somebody else wrote, so this is the difference
 * between a sanitizer run that covers this parser and one that looks as
 * though it does. */
static void bexact(Buf *b) {
	uint8_t *q = realloc(b->p, b->n ? b->n : 1);
	if (q) { b->p = q; b->cap = b->n; }
}

static void idx_open(const char *path, Idx *x) {
	memset(x, 0, sizeof *x);
	readall(path, &x->raw);
	bexact(&x->raw);
	const uint8_t *p = x->raw.p;
	size_t n = x->raw.n;
	if (n < IDX_HDR + IDX_TRAIL) dieval("pack index shorter than its header", n);
	/* A v1 index has no magic: it begins with fanout[0], whose top byte is
	 * zero for any pack of fewer than 16 million objects. 0xff was picked
	 * for the first byte of the v2 magic so the two cannot be confused. */
	if (memcmp(p, "\377tOc", 4))
		die("not a v2 pack index: bad magic (v1 indexes are not supported)");
	uint32_t ver = be32(p + 4);
	if (ver != 2) dieval("unsupported pack index version", ver);

	x->fan = p + 8;
	for (size_t i = 1; i < 256; i++)
		if (be32(x->fan + 4 * i) < be32(x->fan + 4 * (i - 1)))
			dieat("fanout entry goes backwards", i);
	x->n = be32(x->fan + 4 * 255);

	/* Division, not multiplication: n is a 32-bit field and n * IDX_ENT
	 * would be the overflow this check exists to catch. */
	size_t body = n - IDX_HDR - IDX_TRAIL;
	if (x->n > body / IDX_ENT)
		dieval("pack index too small for the object count it declares", x->n);
	size_t rest = body - x->n * IDX_ENT;
	if (rest % 8)
		dieat("pack index ends in a partial 64-bit offset", n - IDX_TRAIL - rest % 8);
	x->nbig = rest / 8;
	/* git's own size check allows at most n-1 large offsets, because the
	 * first object in a pack sits at offset 12 and can never need one. An
	 * index with more is one `git verify-pack` calls "wrong index v2 file
	 * size", and that is where this rule came from: an all-indirect fixture
	 * was built here, git refused it, and the limit was news. */
	if (x->nbig && x->nbig >= x->n)
		dieval("more 64-bit offsets than objects that could need one", x->nbig);

	x->names = p + IDX_HDR;
	x->crcs = x->names + 20 * x->n;
	x->off32 = x->crcs + 4 * x->n;
	x->off64 = x->off32 + 4 * x->n;

	uint8_t sum[20];
	Sha1 s;
	sha1_init(&s);
	sha1_update(&s, p, n - 20);
	sha1_final(&s, sum);
	if (memcmp(sum, p + n - 20, 20)) dieat("pack index checksum mismatch", n - 20);

	for (size_t i = 1; i < x->n; i++)
		if (memcmp(x->names + 20 * i, x->names + 20 * (i - 1), 20) <= 0)
			dieat("object names are not in increasing order", i);
	/* The fanout is checked against the names rather than merely for being
	 * monotonic: an index whose fanout is internally tidy and disagrees
	 * with its name list is the one git's binary search silently fails to
	 * find objects in. */
	size_t at = 0;
	for (size_t b = 0; b < 256; b++) {
		size_t end = be32(x->fan + 4 * b);
		for (; at < end; at++)
			if (x->names[20 * at] != (uint8_t)b)
				dieat("fanout bucket disagrees with the name it indexes", at);
	}
}

/* The escape: an offset at or above 2^31 does not fit in the 32-bit entry, so
 * the entry holds the top bit plus an index into the 64-bit table. A pack
 * needing it is over two gigabytes, which is why this path is the one readers
 * get wrong -- it is never reached by accident. */
static uint64_t idx_offset(Idx *x, size_t i) {
	uint32_t v = be32(x->off32 + 4 * i);
	if (!(v & 0x80000000u)) { x->via32++; return v; }
	size_t k = v & 0x7fffffffu;
	if (k >= x->nbig) dieat("64-bit offset index past the end of the table", i);
	x->via64++;
	return be64(x->off64 + 8 * k);
}

/* CRC-32 as zlib and git compute it: reflected, polynomial 0xedb88320, both
 * ends inverted. Bit at a time, because the whole corpus is a few megabytes
 * and a 1KB table would be the only lookup table in the file. */
static uint32_t crc32z(const uint8_t *p, size_t n) {
	uint32_t c = 0xffffffffu;
	for (size_t i = 0; i < n; i++) {
		c ^= p[i];
		for (int k = 0; k < 8; k++)
			c = (c >> 1) ^ ((c & 1) ? 0xedb88320u : 0);
	}
	return ~c;
}

/* An object's packed bytes run from its own offset to the next offset in PACK
 * order, and the index is sorted by NAME, so the extents only exist once the
 * offsets have been sorted. That is what makes every CRC in the index
 * checkable without parsing a single pack entry. */
typedef struct { uint64_t off; uint32_t i; } Pofs;

static int pofscmp(const void *a, const void *b) {
	uint64_t x = ((const Pofs *)a)->off, y = ((const Pofs *)b)->off;
	return x < y ? -1 : x > y ? 1 : 0;
}

/* ------------------------------------------------------------ the packfile
 *
 * "PACK", a version, an object count, then one entry per object, then a
 * SHA-1 over everything before it. An entry is a type/size varint followed
 * by a zlib stream, and for the two delta types the varint is followed by
 * the base's identity.
 *
 * Nothing in the pack records where an entry ENDS. The index's offsets,
 * sorted, are the only record of the extents, which is why this reader
 * wants both files even though inflating any one entry needs only the pack.
 */

#define PACK_HDR 12

/* A delta chain cannot loop through OFS_DELTA, whose base is strictly
 * earlier in the pack, so this ceiling is not cycle detection: it is a bound
 * on how much stack a pack somebody else wrote can ask for, one frame per
 * link. git's own `pack.depth` default is 50 and the deepest chain in any
 * corpus here is 29.
 *
 * shortcut: recursion, so the ceiling and the stack are the same thing. An
 * explicit stack of offsets would lift it, and nothing needs that yet. */
#define DELTA_MAX_DEPTH 256

/* What an entry says about itself, as opposed to what it decodes to.
 * `git verify-pack -v` prints a mixture of the two and the mixture is not
 * arbitrary: the type is the one at the END of the chain, because a delta
 * entry has none of its own, while the size is the one THIS entry declares,
 * which for a delta is the length of the delta data and not of the object it
 * produces. Printing the resolved size there is a disagreement with git on
 * every delta in the pack, which is how this was found. */
typedef struct {
	int type;            /* at the end of the chain */
	size_t declared;     /* what this entry's own varint says */
	unsigned chain;      /* links to an entry stored whole; 0 if it is one */
	uint64_t base;       /* the immediate base's offset, when chain > 0 */
} Ent;

/* A cache of resolved objects, keyed on pack offset, so that a base shared
 * by several deltas is inflated once rather than once per delta on it.
 * Without it a chain of depth N costs N inflations for every object on it
 * and walking a pack is O(objects * chain depth): 1923 inflations for cc's
 * 538 objects, where git does 538.
 *
 * It holds BASES only. A cache consulted for the object actually asked for
 * would make a walk over a whole pack answer out of itself after the first
 * pass, and `packverify` would then be hashing the cache rather than the
 * pack.
 *
 * PLAN.md asked for four entries, on the reasoning that git's delta window
 * keeps a base within a few entries of the deltas on it. Four does almost
 * nothing: measured over cc's 538 objects, 1771 inflations against 1856
 * without any cache at all. The reasoning was about the pack LAYOUT and the
 * cost is in the chain DEPTH, which reaches 29 there, so a four-entry cache
 * is flushed by every object it resolves. 16 entries gives 1033 inflations,
 * 64 gives 729, and 256 gives 719, so 64 is where it stops paying.
 *
 * shortcut: a linear scan over the slots, and whichever was used longest ago
 * goes. 64 slots is 64 comparisons per lookup, which is nothing beside an
 * inflate, and a heap would be the wrong trade until the cache is much
 * bigger. The byte budget is not a shortcut: one entry can be an OBJ_MAX
 * object and the sizes are chosen by whoever wrote the pack. */
#define DBASE_N 64
#define DBASE_MAX ((size_t)16 << 20)

typedef struct {
	uint64_t off;       /* 0 for an empty slot; a real offset is never 0 */
	Ent ent;
	Buf data;
	unsigned long used;
} Dbase;

typedef struct {
	Idx x;
	Buf pk;
	Pofs *ord;          /* every offset, in pack order, with its index entry */
	Dbase cache[DBASE_N];
	size_t cbytes;
	unsigned long clock;
	size_t ninflate, nhit;
	/* The census, counted for the object asked for rather than for the
	 * bases underneath it: a delta test over a pack with no deltas in it
	 * passes while reading nothing, and so does one over a pack whose
	 * chains are all of length 1. */
	size_t nbase, ndelta, maxdepth;
	/* Links rather than objects: one per delta applied, at every level of
	 * every chain. The two encodings are counted apart because nothing in
	 * git's output tells them apart, so this is the only thing that can say
	 * a REF_DELTA fixture really holds REF_DELTAs. */
	size_t nofs, nref;
} Pack;

/* Open an index and the pack beside it, and check the two against each
 * other: the object count in the pack header, the pack's own trailing
 * checksum (of which the index carries a copy), and that every offset the
 * index gives lands inside the pack and is claimed by only one object.
 *
 * Every offset is validated before any extent is derived from one. Checking
 * them as each is used is not the same thing: an object's length comes from
 * the NEXT offset, so one bogus entry makes its predecessor's extent run off
 * the end of the pack while the predecessor's own offset is perfectly valid.
 * That version segfaulted on the first fixture that pointed an offset past
 * the pack. */
static void pack_open(const char *idxpath, Pack *p) {
	memset(p, 0, sizeof *p);
	size_t pl = strlen(idxpath);
	if (pl < 4 || strcmp(idxpath + pl - 4, ".idx"))
		die2("not a .idx path", idxpath);
	idx_open(idxpath, &p->x);
	char pp[4096];
	if ((size_t)snprintf(pp, sizeof pp, "%.*s.pack", (int)(pl - 4), idxpath)
	    >= sizeof pp)
		die("pack path too long");
	readall(pp, &p->pk);
	bexact(&p->pk);
	/* 12 bytes of header, 20 of trailing checksum, and at least one byte
	 * between them for the smallest possible object. */
	if (p->pk.n < PACK_HDR + 21)
		dieval("pack shorter than a header and a trailer", p->pk.n);
	if (memcmp(p->pk.p, "PACK", 4)) die2("not a packfile", pp);
	if (be32(p->pk.p + 4) != 2)
		dieval("unsupported pack version", be32(p->pk.p + 4));
	if (be32(p->pk.p + 8) != p->x.n)
		dieval("pack object count disagrees with the index", be32(p->pk.p + 8));
	if (memcmp(p->x.raw.p + p->x.raw.n - 40, p->pk.p + p->pk.n - 20, 20))
		dieat("the pack checksum in the index is not the trailer the pack carries",
		      p->x.raw.n - 40);

	p->ord = malloc(p->x.n ? p->x.n * sizeof *p->ord : 1);
	if (!p->ord) die("out of memory");
	for (size_t i = 0; i < p->x.n; i++) {
		p->ord[i].off = idx_offset(&p->x, i);
		p->ord[i].i = (uint32_t)i;
	}
	if (p->x.n) qsort(p->ord, p->x.n, sizeof *p->ord, pofscmp);
	for (size_t k = 0; k < p->x.n; k++) {
		if (p->ord[k].off < PACK_HDR || p->ord[k].off >= p->pk.n - 20)
			dieat("index offset is outside the pack", p->ord[k].i);
		if (k && p->ord[k].off == p->ord[k - 1].off)
			dieat("two objects share a pack offset", p->ord[k].i);
	}
}

static void pack_close(Pack *p) {
	for (int i = 0; i < DBASE_N; i++) bfree(&p->cache[i].data);
	p->cbytes = 0;
	free(p->ord);
	bfree(&p->pk);
	bfree(&p->x.raw);
}

/* Where an entry sits in pack order. Binary search rather than a reverse
 * table: an OFS_DELTA names its base by offset and `verify-pack -v` prints
 * that base's NAME, which is the one place the mapping is wanted. */
static size_t pack_ord(const Pack *p, uint64_t off) {
	size_t lo = 0, hi = p->x.n;
	while (lo < hi) {
		size_t mid = lo + (hi - lo) / 2;
		if (p->ord[mid].off < off) lo = mid + 1;
		else if (p->ord[mid].off > off) hi = mid;
		else return mid;
	}
	dieval("no object in the index is at this pack offset", (size_t)off);
	return 0;
}

/* The bytes an entry occupies: from its own offset to the next offset in
 * pack order, or to the start of the trailer for the last one. This is
 * `verify-pack -v`'s size-in-pack column. */
static uint64_t pack_extent(const Pack *p, size_t k) {
	uint64_t beg = p->ord[k].off;
	uint64_t end = k + 1 < p->x.n ? p->ord[k + 1].off : p->pk.n - 20;
	return end - beg;
}

/* An entry's header is a varint whose FIRST byte is split three ways: the
 * top bit continues, the next three are the type, and the low four are the
 * bottom four bits of the size. Later bytes carry seven bits each, low
 * group first. It is not the encoding any other length in the format uses,
 * which is the reason it gets its own function.
 *
 * For a delta entry the size is the length of the DELTA data, not of the
 * object the delta produces. */
static const char *pack_entry_hdr(const uint8_t *p, size_t n, size_t *at,
                                  int *type, size_t *size) {
	size_t i = *at;
	if (i >= n) return "pack entry begins past the end of the pack";
	uint8_t c = p[i++];
	int t = (c >> 4) & 7;
	size_t v = c & 15;
	int sh = 4;
	while (c & 0x80) {
		if (i >= n) return "pack entry size varint runs past the end of the pack";
		if (sh > 56) return "pack entry size varint is too long";
		c = p[i++];
		v |= (size_t)(c & 0x7f) << sh;
		sh += 7;
		/* Inside the loop, because bits only ever accumulate upward: a
		 * varint asking for 2^60 is refused on the byte that says so
		 * rather than after sixty bits of it have been shifted in. */
		if (v > OBJ_MAX) return "pack entry declares a size above OBJ_MAX";
	}
	*at = i;
	*type = t;
	*size = v;
	return NULL;
}

/* How many objects took each path, and how deep the deepest chain walked
 * was. On stderr, so stdout stays byte-comparable with git's output. */
static void pack_census(const Pack *p) {
	fprintf(stderr, "%zu objects, %zu read whole, %zu through a delta chain, "
	        "deepest chain %zu, %zu ofs-delta and %zu ref-delta links, "
	        "%zu inflations and %zu base-cache hits\n",
	        p->x.n, p->nbase, p->ndelta, p->maxdepth, p->nofs, p->nref,
	        p->ninflate, p->nhit);
}

/* A hit hands back a COPY, because the caller owns and frees what it gets,
 * and it hands back the ENTRY FACTS too. Those are not re-derivable from the
 * bytes: a cached object has no entry to read a declared size or a chain
 * length out of, so a cache that returned only the data left the type at 0
 * and every chain length at 1. That was 85 of cc's 538 objects hashing to
 * nothing, which is how this was found. */
static int dbase_get(Pack *p, uint64_t off, Obj *out, Ent *ent) {
	for (int i = 0; i < DBASE_N; i++) {
		if (p->cache[i].off != off) continue;
		p->cache[i].used = ++p->clock;
		p->nhit++;
		*ent = p->cache[i].ent;
		out->type = p->cache[i].ent.type;
		out->data.p = NULL;
		out->data.n = out->data.cap = 0;
		bwrite(&out->data, p->cache[i].data.p, p->cache[i].data.n);
		return 1;
	}
	return 0;
}

static void dbase_evict(Pack *p) {
	int v = -1;
	for (int i = 0; i < DBASE_N; i++)
		if (p->cache[i].off && (v < 0 || p->cache[i].used < p->cache[v].used))
			v = i;
	if (v < 0) return;
	p->cbytes -= p->cache[v].data.n;
	bfree(&p->cache[v].data);
	p->cache[v].off = 0;
}

static void dbase_put(Pack *p, uint64_t off, const Obj *o, const Ent *ent) {
	if (o->data.n > DBASE_MAX) return;
	int v;
	for (;;) {
		v = -1;
		for (int i = 0; i < DBASE_N; i++)
			if (!p->cache[i].off) { v = i; break; }
		if (v >= 0 && p->cbytes + o->data.n <= DBASE_MAX) break;
		dbase_evict(p);
	}
	p->cache[v].off = off;
	p->cache[v].ent = *ent;
	p->cache[v].used = ++p->clock;
	bwrite(&p->cache[v].data, o->data.p, o->data.n);
	p->cbytes += o->data.n;
}

/* Find a name in the index. The fanout gives the half-open range of entries
 * whose first byte matches, so the search starts inside one bucket of 256
 * rather than over the whole list. A REF_DELTA names its base by hash and
 * this is the lookup an OFS_DELTA does not need. */
static int idx_find(const Idx *x, const uint8_t id[20], size_t *out) {
	size_t lo = id[0] ? be32(x->fan + 4 * (id[0] - 1)) : 0;
	size_t hi = be32(x->fan + 4 * id[0]);
	while (lo < hi) {
		size_t mid = lo + (hi - lo) / 2;
		int c = memcmp(x->names + 20 * mid, id, 20);
		if (c < 0) lo = mid + 1;
		else if (c > 0) hi = mid;
		else { *out = mid; return 1; }
	}
	return 0;
}

/* OFS_DELTA gives its base as a distance BACKWARDS from the delta entry's
 * own offset, in a third varint that is neither of the other two: every
 * continuation byte adds one before shifting, so the encoding has exactly
 * one representation of each value and the shortest form is the only form.
 * `(v + 1) << 7`, not a plain shift, is the thing readers get wrong, and
 * getting it wrong is silent until the distance exceeds 127. */
static const char *pack_ofs_delta(const uint8_t *p, size_t n, size_t *at,
                                  uint64_t *dist) {
	size_t i = *at;
	if (i >= n) return "OFS_DELTA base offset runs past the end of the pack";
	uint8_t c = p[i++];
	uint64_t v = c & 0x7f;
	int k = 0;
	while (c & 0x80) {
		if (i >= n) return "OFS_DELTA base offset runs past the end of the pack";
		if (++k > 8) return "OFS_DELTA base offset varint is too long";
		c = p[i++];
		v = ((v + 1) << 7) | (c & 0x7f);
	}
	*at = i;
	*dist = v;
	return NULL;
}

/* The plain 7-bit little-endian varint, which is what the delta header uses
 * for the base size and the result size. A pack holds three different
 * varints and this is the ordinary one. */
static const char *delta_size(const uint8_t *d, size_t n, size_t *at, size_t *out) {
	size_t i = *at, v = 0;
	int sh = 0;
	uint8_t c;
	do {
		if (i >= n) return "delta header size varint is truncated";
		if (sh > 56) return "delta header size varint is too long";
		c = d[i++];
		v |= (size_t)(c & 0x7f) << sh;
		sh += 7;
		if (v > OBJ_MAX) return "delta header declares a size above OBJ_MAX";
	} while (c & 0x80);
	*at = i;
	*out = v;
	return NULL;
}

/* Apply a delta: two sizes, then a stream of copy and insert instructions.
 *
 * A copy instruction has the top bit set, and the rest of the byte is a
 * bitmap of which of seven following bytes are present: four for the offset
 * into the base, three for the length, each little-endian. An absent byte
 * is zero, EXCEPT that a length of zero means 0x10000, which is the one
 * default that is not the identity and the second classic bug here. An
 * instruction byte with the top bit clear is an insert of that many literal
 * bytes; zero is not an instruction at all.
 *
 * Both sizes are checked rather than trusted. The base size is what says
 * this delta belongs to this base, and the result size bounds the output, so
 * neither a copy nor an insert can grow the result past what the header
 * declared. `out` must be empty: the bounds below are on the whole buffer. */
static const char *delta_apply(const uint8_t *d, size_t dn,
                               const uint8_t *b, size_t bn, Buf *out) {
	size_t at = 0, want_base = 0, want_res = 0;
	const char *e = delta_size(d, dn, &at, &want_base);
	if (e) return e;
	if ((e = delta_size(d, dn, &at, &want_res))) return e;
	if (want_base != bn) return "delta base size disagrees with the base object";
	while (at < dn) {
		uint8_t c = d[at++];
		if (c & 0x80) {
			uint64_t off = 0, len = 0;
			for (int k = 0; k < 4; k++)
				if (c & (1 << k)) {
					if (at >= dn) return "delta copy instruction is truncated";
					off |= (uint64_t)d[at++] << (8 * k);
				}
			for (int k = 0; k < 3; k++)
				if (c & (0x10 << k)) {
					if (at >= dn) return "delta copy instruction is truncated";
					len |= (uint64_t)d[at++] << (8 * k);
				}
			if (!len) len = 0x10000;
			if (off > bn || len > bn - off)
				return "delta copies from outside the base object";
			if (len > want_res - out->n)
				return "delta writes past the result size it declares";
			bwrite(out, b + off, (size_t)len);
		} else if (c) {
			if (c > dn - at) return "delta insert instruction is truncated";
			if (c > want_res - out->n)
				return "delta writes past the result size it declares";
			bwrite(out, d + at, c);
			at += c;
		} else {
			return "delta instruction 0 is not an instruction";
		}
	}
	if (out->n != want_res)
		return "delta result is not the size the delta declares";
	return NULL;
}

/* Read the object at a pack offset, resolving a delta by reading its base
 * the same way. The type comes back from the end of the chain: a delta entry
 * does not carry one.
 *
 * The census is kept here rather than in pack_resolve below, so that it
 * counts the object asked for and not the bases underneath it. */
static const char *pack_resolve(Pack *p, uint64_t off, Obj *out, Ent *me,
                                unsigned depth);

static const char *pack_at(Pack *p, uint64_t off, Obj *out, Ent *ent,
                           unsigned depth) {
	Ent me = {0, 0, 0, 0};
	const char *e = pack_resolve(p, off, out, &me, depth);
	if (e) return e;
	if (!depth) {
		/* The chain length as the entry reports it, not the recursion
		 * depth: with the base cache a chain can be resolved without the
		 * recursion ever reaching its far end. */
		if (me.chain > p->maxdepth) p->maxdepth = me.chain;
		if (me.chain) p->ndelta++;
		else p->nbase++;
	}
	if (ent) *ent = me;
	return NULL;
}

static const char *pack_resolve(Pack *p, uint64_t off, Obj *out, Ent *me,
                                unsigned depth) {
	const uint8_t *q = p->pk.p;
	/* The trailer is not entry data, so it is not part of what a varint or
	 * a zlib stream is allowed to read into. */
	size_t n = p->pk.n - 20;
	if (depth > DELTA_MAX_DEPTH)
		return "delta chain is deeper than gitobj will follow";
	if (off < PACK_HDR || off >= n) return "pack offset is outside the pack";
	/* Bases only, which is what `depth` says: the object the caller asked
	 * for is always read out of the pack. */
	if (depth && dbase_get(p, off, out, me)) return NULL;
	size_t at = (size_t)off;
	int t;
	size_t sz;
	const char *e = pack_entry_hdr(q, n, &at, &t, &sz);
	if (e) return e;
	uint64_t boff = 0;
	int isdelta = 1;
	if (t == T_OFS_DELTA) {
		uint64_t dist;
		if ((e = pack_ofs_delta(q, n, &at, &dist))) return e;
		/* Zero would name the delta entry itself and anything larger than
		 * the offset would name a byte before the pack header. */
		if (!dist || dist > off - PACK_HDR)
			return "OFS_DELTA base offset is outside the pack";
		boff = off - dist;
		p->nofs++;
	} else if (t == T_REF_DELTA) {
		/* The base by name, which can sit anywhere in the pack, before
		 * this entry or after it. A base that is not in this pack at all
		 * is a thin pack, which git only ever sends down a wire and never
		 * stores, so it is refused rather than searched for elsewhere. */
		if (n - at < 20)
			return "REF_DELTA base name runs past the end of the pack";
		size_t bi;
		if (!idx_find(&p->x, q + at, &bi))
			return "REF_DELTA base is not an object this pack holds";
		boff = idx_offset(&p->x, bi);
		at += 20;
		p->nref++;
	} else if (t < T_COMMIT || t > T_TAG) {
		return "pack entry has a type number git does not use";
	} else {
		isdelta = 0;
	}

	Buf z = {0};
	size_t used = 0;
	p->ninflate++;
	if ((e = zinflate(q + at, n - at, &z, &used))) { bfree(&z); return e; }
	/* The declared size is checked against what inflated. git stores both,
	 * and a reader that trusts the varint reports a length the data does
	 * not have. For a delta entry this is the size of the delta data, not
	 * of the object it produces: that one is in the delta's own header. */
	if (z.n != sz) {
		bfree(&z);
		return "pack entry inflated to a size other than the one it declares";
	}
	if (!isdelta) {
		me->type = t;
		me->declared = sz;
		out->type = t;
		out->data = z;
		if (depth) dbase_put(p, off, out, me);
		return NULL;
	}

	Obj base = {0, {0}};
	Ent bent = {0, 0, 0, 0};
	if ((e = pack_at(p, boff, &base, &bent, depth + 1))) { bfree(&z); return e; }
	Buf res = {0};
	e = delta_apply(z.p, z.n, base.data.p, base.data.n, &res);
	bfree(&z);
	bfree(&base.data);
	if (e) { bfree(&res); return e; }
	me->type = bent.type;
	me->declared = sz;
	me->chain = bent.chain + 1;
	me->base = boff;
	out->type = bent.type;
	out->data = res;
	if (depth) dbase_put(p, off, out, me);
	return NULL;
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

/* Every pack in an object store. A missing or unreadable objects/pack is not
 * an error: a repository with no pack is the normal case for a fresh one,
 * and `git init --bare` leaves the directory there and empty. */
typedef struct { Pack *v; size_t n, cap; } Packs;

static void packs_open(const char *objdir, Packs *ps) {
	char dir[4096];
	if ((size_t)snprintf(dir, sizeof dir, "%s/pack", objdir) >= sizeof dir)
		die("object path too long");
	DIR *d = opendir(dir);
	if (!d) return;
	struct dirent *e;
	while ((e = readdir(d))) {
		size_t l = strlen(e->d_name);
		if (l < 5 || strcmp(e->d_name + l - 4, ".idx")) continue;
		char path[4096];
		if ((size_t)snprintf(path, sizeof path, "%s/%s", dir, e->d_name) >= sizeof path)
			continue;
		if (ps->n == ps->cap) {
			ps->cap = ps->cap ? ps->cap * 2 : 4;
			Pack *q = realloc(ps->v, ps->cap * sizeof *q);
			if (!q) die("out of memory");
			ps->v = q;
		}
		pack_open(path, &ps->v[ps->n++]);
	}
	closedir(d);
}

static void packs_close(Packs *ps) {
	for (size_t i = 0; i < ps->n; i++) pack_close(&ps->v[i]);
	free(ps->v);
	ps->v = NULL;
	ps->n = ps->cap = 0;
}

/* ------------------------------------------------- the object store, and
 *                                                    the ones it borrows
 *
 * `objects/info/alternates` is a list of other object directories to look
 * in, one per line, which is what `git clone -s` writes and what most CI
 * caches look like. An object in an alternate is in the repository as far as
 * every git command is concerned, `cat-file --batch-all-objects` included,
 * so a reader that ignores the file reports "object not found" for a
 * repository git reads perfectly.
 *
 * A relative path is relative to the objects directory holding the file,
 * not to the current directory. An alternate may have alternates of its
 * own, and git follows those too.
 *
 * shortcut: no C-quoted paths. git accepts a line beginning with a double
 * quote as a quoted path, which nothing writes in practice; such a line is
 * taken literally here and the directory is then simply not there. */
#define ALT_MAX 5         /* git's own default depth for nested alternates */

typedef struct { char (*v)[4096]; size_t n, cap; } Dirs;

/* 0 if this directory is already in the list, which is how a cycle ends. */
static int dirs_add(Dirs *d, const char *path) {
	for (size_t i = 0; i < d->n; i++)
		if (!strcmp(d->v[i], path)) return 0;
	if (d->n == d->cap) {
		d->cap = d->cap ? d->cap * 2 : 4;
		char (*q)[4096] = realloc(d->v, d->cap * 4096);
		if (!q) die("out of memory");
		d->v = q;
	}
	snprintf(d->v[d->n++], 4096, "%s", path);
	return 1;
}

/* The directory, then everything its alternates file points at, in the
 * order git searches. An alternate that is not there is skipped rather than
 * refused, which is what git does: the file is a hint about where objects
 * MIGHT be. The primary directory is added whether it exists or not, so a
 * wrong objdir still fails loudly.
 *
 * Two guards, and they catch different things. A directory already in the
 * list is not searched again, which ends a cycle spelled the same way round
 * both times; without it the recursion runs until the stack does, and a
 * de-duplicated LIST is not the same thing as a terminating walk. The depth
 * limit is what ends a cycle spelled two ways, which relative paths make
 * easy: each hop appends to the path, so no two strings are ever equal. */
static void alt_scan(Dirs *d, const char *objdir, int depth) {
	if (!dirs_add(d, objdir)) return;
	if (depth >= ALT_MAX) return;
	char path[4096];
	if ((size_t)snprintf(path, sizeof path, "%s/info/alternates", objdir)
	    >= sizeof path)
		return;
	FILE *f = fopen(path, "r");
	if (!f) return;
	char line[4096];
	while (fgets(line, sizeof line, f)) {
		size_t k = strlen(line);
		while (k && (line[k - 1] == '\n' || line[k - 1] == '\r')) line[--k] = 0;
		if (!k || line[0] == '#') continue;
		char sub[4096];
		if (line[0] == '/')
			snprintf(sub, sizeof sub, "%s", line);
		else
			snprintf(sub, sizeof sub, "%s/%s", objdir, line);
		DIR *t = opendir(sub);
		if (!t) continue;
		closedir(t);
		alt_scan(d, sub, depth + 1);
	}
	fclose(f);
}

typedef struct { Dirs dirs; Packs packs; } Odb;

static void odb_open(const char *objdir, Odb *o) {
	memset(o, 0, sizeof *o);
	alt_scan(&o->dirs, objdir, 0);
	for (size_t i = 0; i < o->dirs.n; i++) packs_open(o->dirs.v[i], &o->packs);
}

static void odb_close(Odb *o) {
	packs_close(&o->packs);
	free(o->dirs.v);
	o->dirs.v = NULL;
	o->dirs.n = o->dirs.cap = 0;
}

/* One object, by name, from a loose file or from whichever pack holds it.
 * Loose first, which is the order git looks in, and it matters: an object
 * can be both, and a repack leaves the loose copy behind until it is
 * pruned. The two copies are the same bytes or one of them is corrupt, and
 * `verify` is what says which. */
static int obj_get(Odb *o, const char *hex, Obj *out) {
	uint8_t want[20];
	if (unhexify(hex, want)) die2("not a 40-character object name", hex);
	for (size_t i = 0; i < o->dirs.n; i++)
		if (loose_read(o->dirs.v[i], hex, out)) return 1;
	for (size_t i = 0; i < o->packs.n; i++) {
		size_t k;
		if (!idx_find(&o->packs.v[i].x, want, &k)) continue;
		const char *e = pack_at(&o->packs.v[i],
		                        idx_offset(&o->packs.v[i].x, k), out, NULL, 0);
		if (e) die2(hex, e);
		return 1;
	}
	return 0;
}

/* Every object in the store, loose and packed, borrowed and its own, by name
 * and without duplicates: an object can be loose AND in a pack, or in two
 * packs, or in this store and an alternate, and `git cat-file
 * --batch-all-objects` lists it once. */
static void odb_names(Odb *o, Names *out) {
	/* Every directory in the list exists: alt_scan only adds an alternate
	 * it could open, and the primary is the caller's own argument. */
	for (size_t i = 0; i < o->dirs.n; i++) loose_names(o->dirs.v[i], out);
	char hex[41];
	for (size_t i = 0; i < o->packs.n; i++)
		for (size_t k = 0; k < o->packs.v[i].x.n; k++) {
			hexify(o->packs.v[i].x.names + 20 * k, hex);
			nadd(out, hex);
		}
	if (!out->n) return;
	qsort(out->v, out->n, 41, cmpname);
	size_t w = 1;
	for (size_t i = 1; i < out->n; i++)
		if (strcmp(out->v[i], out->v[w - 1]))
			memcpy(out->v[w++], out->v[i], 41);
	out->n = w;
}

/* Resolve an abbreviated name the way git's short-object-ID lookup does:
 * find every object whose name begins with it and give an answer only if
 * there is exactly one. Returns the number of matches, capped at 2, since a
 * caller only needs to know none, one, or more than one.
 *
 * Four hex characters is git's own minimum and the caller enforces it. An
 * odd number of them is fine: this is a prefix of the NAME, not of the
 * bytes.
 *
 * shortcut: a linear scan over every name in the store, which odb_names()
 * has collected anyway. The fanout would turn it into a binary search per
 * pack, and the cost here is not the scan: a command that wants one object
 * already opens every index and every pack in the store to find it. */
static int odb_resolve(Odb *o, const char *pre, char full[41]) {
	size_t pn = strlen(pre);
	Names ns = {0};
	odb_names(o, &ns);
	int n = 0;
	for (size_t i = 0; i < ns.n && n < 2; i++)
		if (!strncmp(ns.v[i], pre, pn)) {
			memcpy(full, ns.v[i], 41);
			n++;
		}
	free(ns.v);
	return n;
}

/* The one place a name or a prefix is checked for being one. Four hex
 * characters is git's own minimum, and an odd number of them is fine. */
static void name_check(const char *hex) {
	size_t n = strlen(hex);
	if (n == 40) {
		uint8_t id[20];
		if (unhexify(hex, id)) die2("not an object name", hex);
		return;
	}
	if (n < 4 || n > 40 || !ishex(hex, n))
		die2("not an object name, nor 4 or more hex characters of one", hex);
}

/* Resolve, and die rather than return a second answer. */
static void name_resolve(Odb *o, const char *hex, char full[41]) {
	int k = odb_resolve(o, hex, full);
	if (!k) die2("object not found", hex);
	if (k > 1) die2("short object name is ambiguous", hex);
}

/* The full name of whatever the caller named, which may be a prefix. A
 * 40-character name is taken as itself, because the exact lookup is a
 * binary search where resolving a prefix is a walk over the store. */
static void obj_full(Odb *o, const char *hex, char full[41]) {
	name_check(hex);
	if (strlen(hex) == 40) {
		memcpy(full, hex, 41);
		return;
	}
	name_resolve(o, hex, full);
}

/* The same for a caller that wants one object and nothing else. The store is
 * opened and closed around it; an Obj holds its own buffer, so it outlives
 * both. */
static void obj_read(const char *objdir, const char *hex, Obj *out) {
	Odb o;
	odb_open(objdir, &o);
	char full[41];
	obj_full(&o, hex, full);
	int got = obj_get(&o, full, out);
	odb_close(&o);
	if (!got) die2("object not found", hex);
}


/* ------------------------------------------------------------------ main */

static int usage(void) {
	fputs("usage: gitobj hash <type> [file]\n"
	      "       gitobj write <objdir> <type> [file]\n"
	      "       gitobj mktree <objdir>\n"
	      "       gitobj cat|raw|type|size <objdir> <sha>\n"
	      "       gitobj ls|verify <objdir>\n"
	      "       gitobj name <objdir> <sha or 4+ hex characters of one>\n"
	      "       gitobj idx <pack.idx>\n"
	      "       gitobj idxcrc <pack.idx>\n"
	      "       gitobj packls <pack.idx>\n"
	      "       gitobj packverify <pack.idx>\n"
	      "       gitobj unpack <pack.idx> <objdir>\n"
	      "       gitobj hdr <objdir> <sha> <key>\n"
	      "       gitobj msg <objdir> <sha>\n", stderr);
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

	if (!strcmp(cmd, "write") && (argc == 4 || argc == 5)) {
		int t = tcode(argv[3]);
		if (!t) die2("unknown object type", argv[3]);
		Buf in = {0};
		readall(argc == 5 ? argv[4] : NULL, &in);
		uint8_t id[20];
		char hex[41];
		objid(t, in.p, in.n, id);
		hexify(id, hex);
		loose_write(argv[2], hex, t, in.p, in.n);
		printf("%s\n", hex);
		bfree(&in);
		return 0;
	}

	if (!strcmp(cmd, "mktree") && argc == 3) {
		Buf in = {0};
		readall(NULL, &in);
		Ment *v = NULL;
		size_t nv = 0, cap = 0;
		size_t at = 0;
		while (at < in.n) {
			const char *nl = memchr(in.p + at, '\n', in.n - at);
			size_t len = nl ? (size_t)((const uint8_t *)nl - in.p) - at : in.n - at;
			/* A blank line is skipped, not an error: that is what a
			 * trailing newline on the last entry leaves behind. */
			if (len) {
				if (nv == cap) {
					cap = cap ? cap * 2 : 16;
					Ment *q = realloc(v, cap * sizeof *v);
					if (!q) die("out of memory");
					v = q;
				}
				const char *e = parse_mkline((const char *)in.p + at, len, &v[nv]);
				if (e) die(e);
				nv++;
			}
			at += len + (nl ? 1 : 0);
		}
		Buf tree = {0};
		tree_build(v, nv, &tree);
		uint8_t id[20];
		char hex[41];
		objid(T_TREE, tree.p, tree.n, id);
		hexify(id, hex);
		loose_write(argv[2], hex, T_TREE, tree.p, tree.n);
		printf("%s\n", hex);
		for (size_t i = 0; i < nv; i++) free(v[i].name);
		free(v);
		bfree(&tree);
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

	/* `git rev-parse <prefix>` with nothing else in it: no refs, no
	 * revision syntax, just the abbreviated-name lookup. */
	if (!strcmp(cmd, "name") && argc == 4) {
		name_check(argv[3]);
		Odb o;
		odb_open(argv[2], &o);
		char full[41];
		/* Not the fast path even for a full name: `name` is asked whether
		 * the object is THERE, and a 40-character name that is not in the
		 * store has to be refused rather than echoed back. */
		name_resolve(&o, argv[3], full);
		odb_close(&o);
		printf("%s\n", full);
		return 0;
	}

	if (!strcmp(cmd, "msg") && argc == 4) {
		Obj o = {0, {0}};
		obj_read(argv[2], argv[3], &o);
		if (o.type != T_COMMIT && o.type != T_TAG)
			die2("not a commit or tag", argv[3]);
		size_t m = msg_start(o.data.p, o.data.n);
		writeall(o.data.p + m, o.data.n - m);
		bfree(&o.data);
		return 0;
	}

	if (!strcmp(cmd, "hdr") && argc == 5) {
		Obj o = {0, {0}};
		obj_read(argv[2], argv[3], &o);
		if (o.type != T_COMMIT && o.type != T_TAG)
			die2("not a commit or tag", argv[3]);
		int found = hdr_print(o.data.p, o.data.n, argv[4]);
		bfree(&o.data);
		return found ? 0 : 1;
	}

	/* `git show-index` prints exactly these three fields in exactly this
	 * format, so stdout here is comparable with it line for line. The
	 * census goes to stderr: a 64-bit offset test over a corpus with no
	 * large offsets passes while that code never runs, so the number of
	 * objects that took each path is part of the output rather than
	 * something to be assumed. */
	if (!strcmp(cmd, "idx") && argc == 3) {
		Idx x;
		idx_open(argv[2], &x);
		char hex[41];
		for (size_t i = 0; i < x.n; i++) {
			uint64_t off = idx_offset(&x, i);
			hexify(x.names + 20 * i, hex);
			printf("%llu %s (%08x)\n", (unsigned long long)off, hex,
			       (unsigned)be32(x.crcs + 4 * i));
		}
		fprintf(stderr, "%zu objects, %zu direct, %zu via the 64-bit table of %zu\n",
		        x.n, x.via32, x.via64, x.nbig);
		bfree(&x.raw);
		return 0;
	}

	if (!strcmp(cmd, "idxcrc") && argc == 3) {
		Pack p;
		pack_open(argv[2], &p);
		size_t bad = 0;
		char hex[41];
		for (size_t k = 0; k < p.x.n; k++) {
			uint64_t beg = p.ord[k].off;
			uint32_t got = crc32z(p.pk.p + beg, (size_t)pack_extent(&p, k));
			uint32_t want = be32(p.x.crcs + 4 * p.ord[k].i);
			if (got != want) {
				hexify(p.x.names + 20 * p.ord[k].i, hex);
				printf("CRC MISMATCH %s at %llu: %08x, index says %08x\n",
				       hex, (unsigned long long)beg, (unsigned)got,
				       (unsigned)want);
				bad++;
			}
		}
		printf("%zu objects, %zu bad crcs\n", p.x.n, bad);
		fprintf(stderr, "%zu objects, %zu direct, %zu via the 64-bit table of %zu\n",
		        p.x.n, p.x.via32, p.x.via64, p.x.nbig);
		pack_close(&p);
		return bad ? 1 : 0;
	}

	/* `git verify-pack -v` prints exactly these columns in exactly this
	 * format, padding the type to six characters, so stdout here is
	 * comparable with it line for line. Pack order, which is what git
	 * walks: it sorts the index's offsets for the same reason this does.
	 *
	 * The census on stderr is the vacuity guard. A delta test over a pack
	 * with no deltas in it passes while reading nothing, and which entries
	 * are deltas is decided by whoever wrote the pack, so the count of
	 * each kind is output rather than an assumption. */
	if (!strcmp(cmd, "packls") && argc == 3) {
		Pack p;
		pack_open(argv[2], &p);
		char hex[41], bhex[41];
		for (size_t k = 0; k < p.x.n; k++) {
			Obj o = {0, {0}};
			Ent ent = {0, 0, 0, 0};
			const char *e = pack_at(&p, p.ord[k].off, &o, &ent, 0);
			if (e) dieat(e, (size_t)p.ord[k].off);
			hexify(p.x.names + 20 * p.ord[k].i, hex);
			printf("%s %-6s %zu %llu %llu", hex, tname(ent.type), ent.declared,
			       (unsigned long long)pack_extent(&p, k),
			       (unsigned long long)p.ord[k].off);
			if (ent.chain) {
				hexify(p.x.names + 20 * p.ord[pack_ord(&p, ent.base)].i, bhex);
				printf(" %u %s", ent.chain, bhex);
			}
			putchar('\n');
			bfree(&o.data);
		}
		pack_census(&p);
		pack_close(&p);
		return 0;
	}

	/* `git unpack-objects` without the pack having to arrive on stdin: every
	 * object of a pack, written out as a loose one. It is the two halves of
	 * this program meeting, so the name is recomputed from what came out of
	 * the pack rather than copied from the index: a writer handed the name
	 * it is meant to produce cannot be caught producing another. An object
	 * whose name does not check out is reported and NOT written, because
	 * the one thing worse than refusing to unpack a pack is filing an
	 * object under a name that is not its hash. */
	if (!strcmp(cmd, "unpack") && argc == 4) {
		Pack p;
		pack_open(argv[2], &p);
		size_t bad = 0, n = 0;
		char hex[41], want[41];
		for (size_t k = 0; k < p.x.n; k++) {
			Obj o = {0, {0}};
			const char *e = pack_at(&p, p.ord[k].off, &o, NULL, 0);
			if (e) dieat(e, (size_t)p.ord[k].off);
			uint8_t id[20];
			objid(o.type, o.data.p, o.data.n, id);
			hexify(id, hex);
			hexify(p.x.names + 20 * p.ord[k].i, want);
			if (strcmp(hex, want)) {
				printf("MISMATCH %s hashes to %s\n", want, hex);
				bad++;
			} else {
				loose_write(argv[3], hex, o.type, o.data.p, o.data.n);
				n++;
			}
			bfree(&o.data);
		}
		printf("%zu objects written, %zu mismatched\n", n, bad);
		pack_census(&p);
		pack_close(&p);
		return bad ? 1 : 0;
	}

	/* The hard invariant, over packed objects: the name git filed an object
	 * under has to be the SHA-1 of what came out of the pack. Nothing of
	 * ours is on the other side of that comparison. */
	if (!strcmp(cmd, "packverify") && argc == 3) {
		Pack p;
		pack_open(argv[2], &p);
		size_t bad = 0;
		char hex[41], want[41];
		for (size_t k = 0; k < p.x.n; k++) {
			Obj o = {0, {0}};
			const char *e = pack_at(&p, p.ord[k].off, &o, NULL, 0);
			if (e) dieat(e, (size_t)p.ord[k].off);
			uint8_t id[20];
			objid(o.type, o.data.p, o.data.n, id);
			hexify(id, hex);
			hexify(p.x.names + 20 * p.ord[k].i, want);
			if (strcmp(hex, want)) {
				printf("MISMATCH %s hashes to %s\n", want, hex);
				bad++;
			}
			bfree(&o.data);
		}
		printf("%zu objects, %zu mismatched\n", p.x.n, bad);
		pack_census(&p);
		pack_close(&p);
		return bad ? 1 : 0;
	}

	if (argc == 3 && (!strcmp(cmd, "ls") || !strcmp(cmd, "verify"))) {
		int vfy = !strcmp(cmd, "verify");
		Names ns = {0};
		Odb db;
		odb_open(argv[2], &db);
		odb_names(&db, &ns);
		size_t bad = 0, nloose = 0;
		for (size_t i = 0; i < ns.n; i++) {
			Obj o = {0, {0}};
			if (!obj_get(&db, ns.v[i], &o))
				die2("object not found", ns.v[i]);
			for (size_t k = 0; k < db.dirs.n; k++)
				if (loose_exists(db.dirs.v[k], ns.v[i])) { nloose++; break; }
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
		/* Which of them came out of a pack, because a store whose packs
		 * were never opened reports zero mismatches just as happily. */
		fprintf(stderr, "%zu objects, %zu loose, %zu from %zu pack%s, "
		        "%zu object director%s\n", ns.n, nloose, ns.n - nloose,
		        db.packs.n, db.packs.n == 1 ? "" : "s", db.dirs.n,
		        db.dirs.n == 1 ? "y" : "ies");
		odb_close(&db);
		free(ns.v);
		return bad ? 1 : 0;
	}

	return usage();
}
