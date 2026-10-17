# Security policy

Zigibit is a testnet4 node under development. There is no production, custody,
or release-support guarantee. Security review currently targets the default
branch; releases need an explicit support policy before publication.

While source is owned by RosettaBitcoin, use its
[security policy](https://github.com/donavonguyot/rosetta-bitcoin/blob/main/SECURITY.md).
Use GitHub's private vulnerability reporting when the repository offers it.
If no private reporting channel is available, ask the maintainer to establish
one without posting exploit details. A future standalone repository must
configure and verify its reporting channel before public release.

Include the source revision, selected storage and crypto backends, reproduction,
expected versus observed behavior, and minimized fixture or sanitized logs.
Treat consensus bypasses, denial of service, corrupted chainstate, and dependency
vulnerabilities as security-sensitive. Never include credentials or private keys.
A comparison with another implementation is diagnostic evidence, not proof that
Zigibit's validation is correct.
