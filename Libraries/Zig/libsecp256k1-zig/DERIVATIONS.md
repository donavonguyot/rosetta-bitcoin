# Verification arithmetic derivations

This package independently implements public-input mathematics. No C code,
recoding control flow, generator tables, or generated implementation material
is copied or translated. The upstream C executable is a test-only oracle.

Mathematical references:

- Hankerson, Menezes, Vanstone, *Guide to Elliptic Curve Cryptography*, chapter 3:
  [book resources](https://cacr.uwaterloo.ca/ecc/). Signed width-w representations
  and simultaneous multiplication motivate the separate-base signed-window design.
- [EFD Jacobian coordinates with a=0](https://www.hyperelliptic.org/EFD/g1p/auto-shortw-jacobian-0.html):
  x=X/Z², y=Y/Z³. Mixed addition assumes the second point has Z=1;
  infinity and H=0 are handled before the ordinary addition equation.

## Field identities

Multiplication by small constants is repeated modular addition. The general
addition Z expression ((Z1+Z2)²-Z1²-Z2²)H equals 2Z1Z2H. In mixed addition,
H=x2 Z1²-X1 and D=y2 Z1³-Y1. The output is
X3=D²-H³-2X1H², Y3=D(X1H²-X3)-Y1H³, Z3=Z1H.
H=D=0 doubles the point; H=0,D!=0 yields infinity. Equality is checked in a
common coordinate scale. No raw affine/Jacobian limb comparison is used.

## Public-input inversion and bounds

Binary extended GCD maintains u = input*x (mod m) and v = input*y (mod m),
starting with (u,x)=(input,1), (v,y)=(m,0). Even u or v is halved with its
coefficient; an odd coefficient is replaced by (coefficient+m)/2. Subtraction
preserves the congruence. At u=1 or v=1 the matching coefficient is the inverse.
Coefficients stay in [0,m). Their sum with m is below 2m<2²⁵⁷, so u257 holds
it and the halved value fits u256. Zero/out-of-range inputs are rejected.
The algorithm is variable-time. It is not suitable as a secret-key primitive.
For odd x,m, (x+m)/2 = (x>>1)+(m>>1)+1. Because x<m, the result
is below m and every positive partial sum fits u256. No custom limb arithmetic
is used in the retained field implementation.

## ECDSA x comparison

For finite points 0<=x<p<2n, x mod n=r means x=r or x=r+n.
Multiplying by Z² removes the field inverse. The sum r+n is formed in u257
and tested against p before narrowing; it must not be reduced modulo p.
Synthetic comparison tests need not be curve points: they test this algebraic
helper, while public verification tests enforce valid points separately.

## Independently generated decompression and scalar reduction

The square-root exponent is (p+1)/4 = 2^254 - 2^30 - 244. The development
generator constructs powers a^(2^k-1) by concatenating runs of one bits:
M(2k)=M(k)^(2^k) M(k), and M(k+1)=M(k)^2 a. It symbolically tracks each
exponent and reconstructs the exact target before emitting the schedule.
Verification still checks y^2=rhs and selects the requested parity.

For scalar products write n=2^256-c, with c computed from n rather than
transcribed. Replacing a high half H by Hc preserves the residue. Three folds
of any 512-bit input yield less than 2n; the third result may still have 257
bits. Conditional subtraction precedes narrowing. A 256-bit digest requires
only one conditional subtraction. Public scalar acceptance remains x<n.

## GLV lattice and signed multiplication

The mathematical source is Gallant, Lambert, Vanstone,
[Faster Point Multiplication on Elliptic Curves with Efficient Endomorphisms](https://www.iacr.org/archive/crypto2001/21390189.pdf),
especially its prime-field cube-root endomorphism and lattice decomposition.
HMV supplies the signed-digit and simultaneous-multiplication background;
EFD supplies the coordinate equations. No C implementation material is used.

`tools/derive_constants.py` enumerates small integer bases to obtain nontrivial
cube roots modulo p and n. It pairs them by checking phi(G)=lambda G using
independent affine equations. Exact Gauss reduction starts at (n,0),(-lambda,1),
with nearest-integer ties away from zero. The basis determinant is n and each
basis vector lies in the kernel x+lambda y=0 mod n.

For basis vectors a,b, round the coordinates of (k,0) in that basis and subtract
the resulting lattice vector. Each rounding error has magnitude at most 1/2,
so each residual coordinate is bounded by (abs(a_i)+abs(b_i))/2. The generator
checks these exact bounds are below 2^129; sampled splits are additional tests,
not the bound proof. Signed intermediates fit i512 and residuals fit i256.

Four separate streams represent G,phi(G),P,phi(P). The variable table is built
on one common scale without inversion, then transformed by x -> beta*x.
Packed generator tables are generated with package-owned arithmetic. Streams use 131 digit slots to
cover the proven signed bound and carry. Every nonzero width-w digit is odd
and lies between -(2^(w-1)-1) and +(2^(w-1)-1). Each simultaneous nonzero digit
performs its own mixed addition; there is no joint matrix. Coordinate scales are handled as described below.

Tweaks multiply the generator with its two GLV streams and mixed-add the affine
key exactly once. Zero tweaks and infinity preserve their documented behavior.
Old binary/Fermat and first-campaign routines live in test comparators, with no
runtime dispatch or fallback. Runtime safety remains enabled throughout.

## Common-Z variable tables and packed generator tables

For Jacobian entries (X_i,Y_i,Z_i), form T as the product of nonzero Z_i.
Prefix/suffix products compute T/Z_i without division. The coordinates
(X_i*(T/Z_i)^2,Y_i*(T/Z_i)^3) lie on the common isomorphic curve with
coefficient 7*T^6. Scale generator lookup coordinates by T^2,T^3, perform
addition/doubling on that curve, and multiply the result's Z by T to return to
the original curve. Infinity is excluded from the product and preserved.
The a=0 formulas remain valid; this does not assume that raw coordinates on
different scales are equal. The cube-root endomorphism commutes with scaling.


Generator tables store canonical affine x/y coordinates as big-endian bytes. `tools/generate_tables.py` reproduces every entry by the package-owned affine recurrence; it verifies curve membership and independent scalar spot checks. `tools/tables.json` records the selected widths and byte identities. Ordinary builds require neither Python nor repository files. Signed width-16 recoding uses i16 digits and i32 residues to retain the carry without overflow.
