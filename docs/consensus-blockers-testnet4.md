# Testnet4 consensus blocker catalog

This catalog turns the Python and Java live-chain blocker trail into a shared
handoff queue for follower ports. Treat these facts as regression targets, not as
validation shortcuts. Every port must still independently verify the spend.

Status values:

- `cleared`: implementation validated past this height.
- `blocked`: current or historical honest stop.
- `not_reached`: port has not validated this height yet.
- `unknown`: no reliable status was found.

## Current scout / follower frontier

| Implementation | Last observed validated height | Notes |
|----------------|-------------------------------:|-------|
| Python | 50,000 | Scout path; cleared 46,779 and completed a bounded sync to 50,000. |
| Java | 52,045+ | Lead follower; cleared through 52,024 but was slow/hot near 52,045. |

## Blocker trail

| Height | Template / rule | Block hash | Txid | Input | Spent scriptPubKey | Failure seen | Python status | Java status | Follower notes |
|--------|-----------------|------------|------|-------|--------------------|--------------|---------------|-------------|----------------|
| 739 | P2WPKH / BIP143 | `000000004cfba4fe6174c546086df7fb52b3d65d44788c0ee8acf436dd28de32` | `475ff67b2f2631c6b443635951d81127dcf21898f697d5f7c31e88df836ee756` | 0 | `0014a54e2a1ec06389203887661535ed118b7d053889` | `script verification failed` / missing base interpreter | cleared | cleared | First real spend-path fixture used by C#, Elixir, and likely all followers. |
| 18,675 | P2SH redeem script | `0000000000003969823692a8e899365b91b6c98936feeaa195c22972d786ecd1` | `82be4b75b218e7a62e00b8ec064f159e04449c025d6b8aa5079a89a7bc80ca7c` | 0 | `a9144dae69b35b0f315f4823565a28b485d6a3609ad987` | unsupported `P2SH` | cleared | cleared | Implement P2SH redeem-script extraction before treating script failure as opcode failure. |
| 22,830 | P2TR script path / BIP342 | `00000000000002a436f697d3411d77b66609c47a398951acc82f8307c880116d` | `630725d944cb0ddba2e249f248b725d1f136fc3d698e8dc4f6be61e9103fa33c` | 0 | `5120f6b00789c732c14a921e61f2b1918a8a8db262d5b0aa2fb6e8229ce3870acda5` | unsupported P2TR script-path rule | cleared | cleared | Requires Taproot script-path control block, leaf hash, tapscript evaluation, and BIP342 sighash. |
| 25,207 | Bare `OP_1` | `00000000000000463dba9f98b495062219453ea8ee8e3a311ff7a8ad5e03da0b` | `23bf6f595cc12dde71239de913ea9a30fb60ef20a3a54246701a2dff16227f43` | 1 | `51` | unsupported bare template `unknown:51` | cleared | cleared | Bare script templates appear on spend path; do not assume every spend is standard. |
| 27,042 | Native P2WSH | `00000000000000048ae4dc427b255f06a0acd60eaa80bd8d9bdb223dfd9040b0` | `0864a600ee15635ebb60678c1f25ea043f8470a126b0fb0d7acd2e10afd1bf33` | 0 | `0020379e4b5ccd93422995b409b9c862c8bc7fd92999bb0e92dc9649c03e8ab9fb68` | unsupported `P2WSH` | cleared | cleared | Add witness script hash check before executing the witness script. |
| 27,251 | P2WSH conditional branch | `00000000e32a5d69a7e766fa4c386b239d10aabe0837ebfddb7fb6c5578b9c78` | `a66a655defd3f3abef44ea0ba71dd9939b4b81f894a04fc18160c9ca5e78b0a0` | 0 | `0020e51d37e194ce5fb07c41c7301cdcd6391713c93c276fe115384172e86c8ba660` | unsupported `P2WSH` / conditional op gap | cleared | cleared | Java cleared with `OP_IF`, `OP_ELSE`, and `OP_ENDIF`. |
| 27,807 | P2SH hashlock | `000000000024e0d475a335fe6bbf8032bd342337f98bb378423bc43fb5187ffc` | `d1a68c8f20cc0ce8297e4f4b5ec297af1c6f98630e8105fd9d63b39c004c4ff0` | 0 | `a914d569ebaca3b27115a284275caae03594e3e50db687` | script verification failed | cleared | cleared | Java cleared with `OP_SHA256` and `OP_SIZE` in legacy script. |
| 27,815 | P2SH numeric branch | `00000000f649f4308fe8859ba632114ae244632461293c031cd905794981b250` | `2a691884927c92649b0c8759f929b931ba21d75bb21bc21f4a3b5868be0bc4d7` | 0 | `a9149bd8827378f1a7dbd6f5ace4c90ab98b706fb86287` | script verification failed | cleared | cleared | Java cleared with `OP_SWAP`, `OP_SUB`, and `OP_GREATERTHAN`. |
| 27,840 | Bare 2-of-3 multisig-like script | `000000000000004ba29c976c33753742a34fb029eb261e146dfd31bccdadb9bc` | `f2b2a965cac99c85f71f8705454793183e93a47b558c485dec92c1101bdacf55` | 0 | long bare `52 41 ...` script | unsupported bare template | cleared | cleared | Do not reject all bare multisig/pubkey scripts as non-standard if they are consensus-valid spends. |
| 32,712 | Tapscript `OP_NUMEQUAL` | `0000000000000013db0b030faef1dd4e341e176036db9db4365f8430aadba6a3` | `6b586a4f831e267749a3c2e50b866fe5badb582d3d388ea636669cbdc13acd94` | 0 | `51203a6c36818562ca3aa86741eb70dda13da67a5977255fc8af67109c8dbdd9f3ca` | script verification failed | cleared | cleared | Tapscript numeric op semantics must match Bitcoin script numbers. |
| 32,868 | CLTV | `00000000000000609ae7ba69fd0f7b32ea44503ff9e2bebe70eb34dd13c35ac2` | `8add2663f689111add26c4bc52a2f6060d48e41750c143cdfa8564ac114d97dc` | 0 | `00201b3129860946f970569a12850caede1782d2c8163bb26e284bf3f4af1b4e5077` | unsupported `OP_CHECKLOCKTIMEVERIFY` | cleared | cleared | Implement BIP65 and BIP112 together; version/sequence edge cases matter later. |
| 33,500 | Nested P2SH to P2WSH | `0000000000000034e4c77a0972d1e032375271199ab86d3522c608fd36bf56c4` | `f89a4629debeee9b32a3aaed72a209877a79b070ddcd4b6358312d5724b60683` | 0 | `a91472c44f957fc011d97e3406667dca5b1c930c402687` | script verification failed | cleared | cleared | Java accepted nested P2SH to P2WSH with len-1 witness stack shape. |
| 38,010 | Legacy sighash sequence masking | `000000000000001287d6f4d832f330d1d9cddb3bb3741b25a4aeb8263a57a626` | `ba32ba8e2d812d93317a0503d37d505a826517343f7fec3b8c2e0c715f142eb6` | 0 | `76a9149ec1ccfb40904402ee1d0a1c332c503772f22b3188ac` | script verification failed | cleared | cleared | Java and Python fixes point at legacy `SIGHASH_SINGLE` / `SIGHASH_NONE` sequence masking. |
| 38,191 | CLTV nVersion behavior | `000000000000000c7f9078cb5991c06bc4d5698471920dee73aa93de7579c8f7` | `4e477ff4e1a12fd78e76fb7dec0d0fcd6fb0372f757fabceb83fdb041c6ee9b6` | 0 | `a914bbe352f1c5366dd92bcae64f4de33e6b56df7e3d87` | script verification failed | cleared | cleared | Java fix: CLTV no-op behavior on transaction `nVersion` below 2. |
| 41,700 | Bare `OP_1` plus data push | `000000000013ae973ef034970b5a6c234338d27a0f6ed573913a6de6c9dddbbd` | `4a89d5d1568b5cbcb4118559cb65d2357657d361a41cd96b14e74ed3d065975c` | 0 | `51024e73` | unsupported `unknown:51024e73` | cleared | cleared | Accept consensus-valid bare template instead of treating it as standardness failure. |
| 44,295 | Tapscript `OP_NIP` | `00000000cb1234452fea6487434e627a26825942af62111d9dba1978ae1e9d20` | `cb835ce1d726993515c27df94a358bf327b03323fb0e82c823c1faab31b28786` | 0 | `5120346d44aef23b267970d8c090d8fed28e2dcf772b609f566cdc56e108ff84118a` | script verification failed | cleared | cleared | Port `OP_NIP` stack deletion semantics in tapscript and legacy paths. |
| 46,599 | Taproot script-path terminal stack truthiness | `00000000000000193205628255bc2004082bc1a83ba337f79fe4f591f99fc7e8` | `d16704313ed3cd64f082c92b40d72ccf5ede213f739c3f217caf59f1ca6c962f` | 0 | `5120a23f913d1fc28f07abbcc72218ed00e0d149287b9e86187e54b0c6340ce584b3` | script verification failed | cleared | cleared | Port `castToBool`: only a final `0x80` in an otherwise-zero vector is false negative zero. |
| 46,779 | P2WSH `OP_CODESEPARATOR` / comparison | `0000000000000002ed00d479b1f8f4dc5bc1d033eb6d13c3b653010ef5bdba58` | `fb9b18c782c2b45ccb77b4e22cbdf8b8cb1b8bf603289937968da52475e28aa5` | 0 | `0020359eaf2fdfc8952db69827596cf6fe9093f203bdbbd83749a9953f58a3a93829` | script verification failed (`unsupported opcode 0xab` on replay) | cleared | cleared | Port legacy/SegWit v0 `OP_CODESEPARATOR` subscript semantics for ECDSA sighash; block 46,779 hashes only the subscript after the executed separator. |
| 51,340 | P2SH `OP_ADD` redeem script | `00000000008951628db430d112a92f8dd350a1eb3681410314c0ca9cf2ced81e` | `03911305033a5aa73d7d730f16ba63b53582c6a6570d8d9f86e2f2b76fa2cbc3` | 0 | `a914c464d0169c41085bcf10e3ab2cf83e74859d640b87` | script verification failed (`unsupported opcode 0x93` on redeem replay) | cleared | cleared | Port legacy `OP_ADD` ScriptNum arithmetic; Python fixture `test_real_testnet4_block51340_p2sh_op_add_accepted`, Java fixtures under `JavaNode/src/test/resources/fixtures/tx_p2sh_add_51340*`. |
| 52,024 | P2TR script-path `OP_SHA256` | `000000000004de650965892b4cc23811bfed92413f83e0c3acbe176e31846be6` | `d57def620b54b9f2f31ca5c4356be2e79c15be29233151186c6944b65bbd663d` | 0 | `51208633e66a528c86ba924ac2cbe60eb53e793fead9e0df3e10982c886f102d4b64` | script verification failed | unknown | cleared | Java cleared with tapscript `OP_SHA256`; Java later appeared CPU-bound near 52,045. |
| 52,497 | P2TR script-path tapscript `OP_SIZE` | `0000000000491575f9e5d7d809369231c77a968de544b22ecc15a7e9716d47c7` | `c62c3c4c40feb1850f17ccbd33693c26d3ce83910c5a3fe5c058f30ecec8c6e7` | 0 | `512031b46e4751f440b63193188b859158ab5560beac41d33a3251cbfa88a1192986` | script verification failed | unknown | cleared | Java cleared with tapscript `OP_SIZE` on dual SHA256 16-byte preimage + 2-of-2 Schnorr path; fixtures `tx_p2tr_tapscript_size_52497*`. |
| 54,287 | P2WSH witness `OP_2DROP` | `00000000000ad11895995f451dacfac802d36986ea2086d599b3afe4aefcb178` | `9281b53ec58f80387161566838fb7bf54c2412bb7b59e150ae78ff5f5a413d0c` | 0 | `002098836c6761bf75dcbf74729b4a245c61cce68e89039e38ce2a389d3f23656038` | script verification failed | unknown | cleared | Java cleared with legacy `OP_2DROP` in witness script `OP_2DROP OP_HASH160 … OP_EQUAL`; fixtures `tx_p2wsh_2drop_54287*`. |
| 54,297 | P2WSH witness `OP_IFDUP` + CSV branches | `0000000000e122e7b6e89ae00472ed875842fc7c32d7e7a34765f8e4dd28da63` | `00b7207d21c697a183da730622117a4091ccaea238976ef0341267579ac29b12` | 0 | `00202c832ce8af0a8020f3d06b18a5e2de71663c535870d99fd69a5c184d6245e441` | script verification failed | unknown | cleared | Java cleared with `OP_IFDUP` on 2-of-2 CHECKMULTISIG + IF/NOTIF/CSV witness script; fixtures `tx_p2wsh_ifdup_csv_54297*`. |

## Operational blockers that are not consensus gaps

| Height / range | Symptom | Cause | Recovery |
|----------------|---------|-------|----------|
| 4,947 to 5,324 (Java early run) | many missing UTXO and undo capture errors | corrupted/interleaved connect state during early development | rebuild/replay; do not port as consensus rules |
| 5,579 (TypeScript) | `missing UTXO 5d2f66d...:0` | overlapping sync writers on one datadir | exclusive sync lock plus connect-only rebuild |

## Fixture conventions

- Real failing block or transaction fixtures should live in each port's test tree.
- Name fixtures by height and rule where possible.
- Record the prevout scriptPubKey, txid, input index, and block hash beside the fixture.
- A follower may use another port's fixture bytes, but must run its own verifier.
