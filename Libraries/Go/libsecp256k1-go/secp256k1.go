// Package secp256k1 provides experimental public-input secp256k1 verification.
// It uses math/big, is variable-time, and must not be used for secret operations.
package secp256k1

import (
	"crypto/sha256"
	"errors"
	"math/big"
)

var (
	ErrMalformed     = errors.New("secp256k1: malformed input")
	ErrInvalidScalar = errors.New("secp256k1: invalid scalar")
	ErrInfinity      = errors.New("secp256k1: point at infinity")
	field            = integer("fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f")
	order            = integer("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")
	generator        = point{integer("79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"), integer("483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8"), big.NewInt(1)}
)

func integer(s string) *big.Int          { n, _ := new(big.Int).SetString(s, 16); return n }
func bytesInt(b []byte) *big.Int         { return new(big.Int).SetBytes(b) }
func add(a, b *big.Int) *big.Int         { return new(big.Int).Mod(new(big.Int).Add(a, b), field) }
func sub(a, b *big.Int) *big.Int         { return new(big.Int).Mod(new(big.Int).Sub(a, b), field) }
func mul(a, b *big.Int) *big.Int         { return new(big.Int).Mod(new(big.Int).Mul(a, b), field) }
func scale(a *big.Int, b int64) *big.Int { return mul(a, big.NewInt(b)) }

type point struct{ x, y, z *big.Int }

func infinity() point { return point{new(big.Int), big.NewInt(1), new(big.Int)} }
func (p point) double() point {
	if p.z.Sign() == 0 || p.y.Sign() == 0 {
		return infinity()
	}
	a := mul(p.x, p.x)
	b := mul(p.y, p.y)
	c := mul(b, b)
	d := scale(sub(sub(mul(add(p.x, b), add(p.x, b)), a), c), 2)
	e := scale(a, 3)
	f := mul(e, e)
	x := sub(f, scale(d, 2))
	return point{x, sub(mul(e, sub(d, x)), scale(c, 8)), scale(mul(p.y, p.z), 2)}
}
func (p point) plus(q point) point {
	if p.z.Sign() == 0 {
		return q
	}
	if q.z.Sign() == 0 {
		return p
	}
	z1 := mul(p.z, p.z)
	z2 := mul(q.z, q.z)
	u1 := mul(p.x, z2)
	u2 := mul(q.x, z1)
	s1 := mul(p.y, mul(q.z, z2))
	s2 := mul(q.y, mul(p.z, z1))
	if u1.Cmp(u2) == 0 {
		if s1.Cmp(s2) == 0 {
			return p.double()
		}
		return infinity()
	}
	h := sub(u2, u1)
	i := mul(scale(h, 2), scale(h, 2))
	j := mul(h, i)
	r := scale(sub(s2, s1), 2)
	v := mul(u1, i)
	x := sub(sub(mul(r, r), j), scale(v, 2))
	y := sub(mul(r, sub(v, x)), scale(mul(s1, j), 2))
	z := mul(sub(sub(mul(add(p.z, q.z), add(p.z, q.z)), z1), z2), h)
	return point{x, y, z}
}
func (p point) times(k *big.Int) point {
	r := infinity()
	for i := k.BitLen() - 1; i >= 0; i-- {
		r = r.double()
		if k.Bit(i) != 0 {
			r = r.plus(p)
		}
	}
	return r
}
func (p point) affine() (point, bool) {
	if p.z.Sign() == 0 {
		return point{}, false
	}
	zi := new(big.Int).ModInverse(p.z, field)
	z2 := mul(zi, zi)
	return point{mul(p.x, z2), mul(p.y, mul(z2, zi)), big.NewInt(1)}, true
}
func lift(x *big.Int, odd uint) (point, error) {
	if x.Cmp(field) >= 0 {
		return point{}, ErrMalformed
	}
	rhs := add(mul(mul(x, x), x), big.NewInt(7))
	exponent := new(big.Int).Rsh(new(big.Int).Add(field, big.NewInt(1)), 2)
	y := new(big.Int).Exp(rhs, exponent, field)
	if mul(y, y).Cmp(rhs) != 0 {
		return point{}, ErrMalformed
	}
	if y.Bit(0) != odd {
		y = new(big.Int).Sub(field, y)
	}
	return point{x, y, big.NewInt(1)}, nil
}

// PublicKey is a validated public point. Its zero value is invalid.
type PublicKey struct{ p point }

// ParsePublicKey accepts compressed, uncompressed and parity-consistent hybrid SEC1.
func ParsePublicKey(b []byte) (PublicKey, error) {
	if len(b) == 33 && (b[0] == 2 || b[0] == 3) {
		p, e := lift(bytesInt(b[1:]), uint(b[0]&1))
		return PublicKey{p}, e
	}
	if len(b) != 65 || (b[0] != 4 && b[0] != 6 && b[0] != 7) {
		return PublicKey{}, ErrMalformed
	}
	x, y := bytesInt(b[1:33]), bytesInt(b[33:])
	if x.Cmp(field) >= 0 || y.Cmp(field) >= 0 || mul(y, y).Cmp(add(mul(mul(x, x), x), big.NewInt(7))) != 0 {
		return PublicKey{}, ErrMalformed
	}
	if b[0] != 4 && y.Bit(0) != uint(b[0]&1) {
		return PublicKey{}, ErrMalformed
	}
	return PublicKey{point{x, y, big.NewInt(1)}}, nil
}

// ParseXOnly lifts exactly 32 bytes to the even-y point.
func ParseXOnly(b []byte) (PublicKey, error) {
	if len(b) != 32 {
		return PublicKey{}, ErrMalformed
	}
	p, e := lift(bytesInt(b), 0)
	return PublicKey{p}, e
}

// Compressed returns SEC1 bytes, or an error for an invalid zero-value key.
func (p PublicKey) Compressed() ([33]byte, error) {
	var out [33]byte
	if p.p.z == nil {
		return out, ErrMalformed
	}
	out[0] = 2 + byte(p.p.y.Bit(0))
	p.p.x.FillBytes(out[1:])
	return out, nil
}
func parseDER(b []byte) (*big.Int, *big.Int, error) {
	if len(b) < 8 || len(b) > 72 || b[0] != 0x30 || int(b[1]) != len(b)-2 {
		return nil, nil, ErrMalformed
	}
	pos := 2
	read := func() (*big.Int, error) {
		if pos+2 > len(b) || b[pos] != 2 {
			return nil, ErrMalformed
		}
		n := int(b[pos+1])
		pos += 2
		if n == 0 || pos+n > len(b) {
			return nil, ErrMalformed
		}
		v := b[pos : pos+n]
		pos += n
		if n > 1 && ((v[0] == 0 && v[1]&128 == 0) || (v[0] == 255 && v[1]&128 != 0)) {
			return nil, ErrMalformed
		}
		x := bytesInt(v)
		if v[0]&128 != 0 {
			x.Sub(x, new(big.Int).Lsh(big.NewInt(1), uint(n*8)))
		}
		return x, nil
	}
	r, e := read()
	if e != nil {
		return nil, nil, e
	}
	s, e := read()
	if e != nil || pos != len(b) {
		return nil, nil, ErrMalformed
	}
	return r, s, nil
}
func validScalar(n *big.Int) bool { return n.Sign() > 0 && n.Cmp(order) < 0 }

// VerifyECDSA verifies a digest and bare DER signature. High-S is accepted.
func VerifyECDSA(pubkey, digest, der []byte) (bool, error) {
	if len(digest) != 32 {
		return false, ErrMalformed
	}
	p, e := ParsePublicKey(pubkey)
	if e != nil {
		return false, e
	}
	r, s, e := parseDER(der)
	if e != nil {
		return false, e
	}
	if !validScalar(r) || !validScalar(s) {
		return false, nil
	}
	w := new(big.Int).ModInverse(s, order)
	u := new(big.Int).Mod(new(big.Int).Mul(bytesInt(digest), w), order)
	v := new(big.Int).Mod(new(big.Int).Mul(r, w), order)
	q, ok := generator.times(u).plus(p.p.times(v)).affine()
	if !ok {
		return false, nil
	}
	return new(big.Int).Mod(q.x, order).Cmp(r) == 0, nil
}

// NormalizeLowS returns canonical DER, rejecting out-of-range scalars.
func NormalizeLowS(der []byte) ([]byte, error) {
	r, s, e := parseDER(der)
	if e != nil {
		return nil, e
	}
	if !validScalar(r) || !validScalar(s) {
		return nil, ErrInvalidScalar
	}
	if s.Cmp(new(big.Int).Rsh(new(big.Int).Set(order), 1)) > 0 {
		s = new(big.Int).Sub(order, s)
	}
	encode := func(n *big.Int) []byte {
		b := n.Bytes()
		if b[0]&128 != 0 {
			b = append([]byte{0}, b...)
		}
		return append([]byte{2, byte(len(b))}, b...)
	}
	b := append(encode(r), encode(s)...)
	return append([]byte{0x30, byte(len(b))}, b...), nil
}

// VerifySchnorr implements BIP340 for arbitrary-length messages.
func VerifySchnorr(key, message, signature []byte) (bool, error) {
	if len(signature) != 64 {
		return false, ErrMalformed
	}
	p, e := ParseXOnly(key)
	if e != nil {
		return false, e
	}
	r, s := bytesInt(signature[:32]), bytesInt(signature[32:])
	if r.Cmp(field) >= 0 || s.Cmp(order) >= 0 {
		return false, nil
	}
	tag := sha256.Sum256([]byte("BIP0340/challenge"))
	h := sha256.New()
	h.Write(tag[:])
	h.Write(tag[:])
	h.Write(signature[:32])
	h.Write(key)
	h.Write(message)
	challenge := new(big.Int).Mod(bytesInt(h.Sum(nil)), order)
	neg := new(big.Int).Mod(new(big.Int).Neg(challenge), order)
	q, ok := generator.times(s).plus(p.p.times(neg)).affine()
	return ok && q.y.Bit(0) == 0 && q.x.Cmp(r) == 0, nil
}

// TweakResult contains the tweaked x-only point and its full-point parity.
type TweakResult struct {
	XOnly  [32]byte
	Parity byte
}

// AddXOnlyTweak computes lift_x(key)+tweak*G; zero is an allowed tweak.
func AddXOnlyTweak(key, tweak []byte) (TweakResult, error) {
	var out TweakResult
	if len(tweak) != 32 {
		return out, ErrMalformed
	}
	p, e := ParseXOnly(key)
	if e != nil {
		return out, e
	}
	t := bytesInt(tweak)
	if t.Cmp(order) >= 0 {
		return out, ErrInvalidScalar
	}
	q, ok := p.p.plus(generator.times(t)).affine()
	if !ok {
		return out, ErrInfinity
	}
	q.x.FillBytes(out.XOnly[:])
	out.Parity = byte(q.y.Bit(0))
	return out, nil
}

// CheckXOnlyTweak verifies the output coordinate and parity without truncation.
func CheckXOnlyTweak(key, tweak, output []byte, parity byte) (bool, error) {
	if len(output) != 32 || parity > 1 {
		return false, ErrMalformed
	}
	r, e := AddXOnlyTweak(key, tweak)
	if e != nil {
		return false, e
	}
	return r.XOnly == [32]byte(output) && r.Parity == parity, nil
}
