---
title: "Seven checks: verifying an AWS Nitro attestation in the browser"
description: "What it takes to check, in TypeScript and without trusting my server, that a signed credit tier came from an AWS Nitro enclave running published code."
pubDatetime: 2026-11-07T15:30:00+05:30
tags:
  - aws-nitro
  - attestation
  - typescript
  - cryptography
  - solana
draft: true
---

I'm building [TEE Income Oracle](https://github.com/pandaa880/tee-income-oracle), a service that reads a borrower's bank statement inside an AWS Nitro enclave and signs a credit tier. A lending pool on Solana reads that tier on chain.

Anyone funding those loans should ask: why believe the tier? "My enclave said so" is still my word. An enclave can do better. It can produce an **attestation document**, a blob signed by AWS's hardware that says what code booted and which key the enclave holds. That only helps if someone outside my servers checks it.

So I wrote `@tio/verifier`: a TypeScript library and CLI that also runs in the browser, on the app's verify page. Paste a wallet and the page reads Solana directly, then runs seven checks. Nothing goes through my gateway.

This post covers those checks, and the places where the obvious implementation would have been wrong.

## Table of contents

## What's in the document

AWS [describes the format](https://docs.aws.amazon.com/enclaves/latest/user/verify-root.html): a CBOR map, signed with COSE_Sign1 using ECDSA P-384 (ES384). The fields that matter here:

| Field                     | What it is                                                          |
| :------------------------ | :------------------------------------------------------------------ |
| `pcrs`                    | Measurements of what booted: 48-byte SHA-384 values, indexed 0–31   |
| `certificate`, `cabundle` | The signing certificate and its chain, root first                   |
| `timestamp`               | When the document was made, in milliseconds                         |
| `public_key`              | A key the enclave generated at boot; my enclave signs tiers with it |

My enclave runs on [Marlin Oyster](https://docs.marlin.org/oyster/), which boots a fixed base image inside Nitro and then starts a `docker-compose.yml`. PCR0–2 measure the base image. PCR16 commits to the compose file. Hash those four together and you get an **image id**, which is the identity of one build.

On chain, an oracle registry keeps one entry per enclave build: its image id, its signing key, the SHA-256 of its attestation document, and whether it has been retired. So a wallet's tier leads back to hardware in four hops:

wallet → tier attestation on chain → registry entry → attestation document

## The seven checks

| #   | Check                                         | Compares                           | Against                                             |
| :-- | :-------------------------------------------- | :--------------------------------- | :-------------------------------------------------- |
| 1   | Signed by AWS Nitro hardware                  | COSE signature + certificate chain | AWS root certificate compiled into the verifier     |
| 2   | Marlin's published base image, not debug mode | PCR0–2                             | Pinned values for the base image                    |
| 3   | Runs our published code                       | PCR16                              | Recomputed from the compose file at the release tag |
| 4   | Image id matches the registry                 | Image id from the PCRs             | Registry entry's `measurement`                      |
| 5   | Enclave key = on-chain attester               | `public_key`                       | Registry entry's `attester`                         |
| 6   | Same document the registry recorded           | SHA-256 of the document            | Registry entry's document hash                      |
| 7   | Entry is active                               | Registry entry                     | Not revoked; kind matches the attestation           |

Every check runs; none short-circuits. A bad document shows everything wrong with it at once, and a failing check is a `FAIL` line, not an exception.

The root certificate is compiled in, never fetched. A verifier that downloads its root trusts whoever answers the download. A test asserts its SHA-256 equals the fingerprint AWS publishes, so a swapped root can't slip through.

## Never re-encode what was signed

A signature covers bytes, not values. Nitro's payload is a CBOR map in **indefinite-length** form: it starts with `0xbf` ("map, length to follow") rather than a byte that states the size. A CBOR library decodes that fine. Encode it back and you get the canonical form instead. I tried it on one of my archived documents: 4,478 bytes became 4,477, the first byte became `0xa9`, and the signature no longer matched.

So the verifier decodes the payload to read fields, but signs over the bytes exactly as received. COSE builds the signed message, the `Sig_structure`, by wrapping the raw payload:

```ts
/** RFC 9052 §4.4: `["Signature1", protected, external_aad = h'', payload]`, the bytes that were signed. */
export function sigStructure(cose: CoseSign1): Uint8Array {
  return encode([
    SIGNATURE1_CONTEXT,
    cose.protectedHeader,
    new Uint8Array(0),
    cose.payload,
  ]);
}
```

The same rule applies one layer down, in the certificates. An X.509 signature covers the certificate's `TBSCertificate` bytes. The verifier hashes `tbsCertificateRaw`, the bytes as they appear in the certificate, never `serialize(parse(tbs))`.

Here the tests nearly fooled me. AWS's certificates are canonical DER, so both approaches pass on real data. My AI code reviewer asked for the test that tells them apart. It rewrites the leaf certificate's length in a non-minimal long form (`30 82 LL LL` → `30 83 00 LL LL`). That's a different encoding of the same certificate, and it isn't what AWS signed. A verifier that re-encodes turns it back into the canonical form and accepts it. One that hashes the raw bytes rejects it.

One more format detail: AWS's docs show the envelope wrapped in CBOR tag 18, but the documents I received start with `0x84`, a bare four-element array. The verifier accepts both and rejects any other tag.

## A valid AWS signature my library rejected

ECDSA has a quirk: if `(r, s)` is a valid signature, so is `(r, n − s)`. Some systems accept only the "low-S" form, so one signature can't be rewritten into a second valid one. [noble-curves](https://github.com/paulmillr/noble-curves) enforces that by default.

Nitro's signer doesn't normalize `s`. One of my three archived documents is high-S. With noble's default options its genuine AWS signature fails; with `lowS: false` it passes. I checked both on the real document.

```ts
return p384.verify(cose.signature, sha384(sigStructure(cose)), publicKeyPoint, {
  lowS: false,
  prehash: false,
});
```

Turning that off is safe here. The low-S rule protects systems where a signature's exact bytes identify something, like a transaction id. Here a signature is evidence about a document whose hash is already on chain. A second valid encoding of it proves nothing new.

## Check the chain at the document's time, not now

AWS's guide says to check that the current date falls within every certificate's validity period. That's right for live attestation, where you just asked an enclave to prove itself.

My verifier checks archived documents. The leaf certificate lives about three hours. When I ran the chain check against today's date, all three archived documents failed. The oldest is from 2026-10-08, and some intermediate certificates had already expired. Checked "now", every verification would fail within hours.

So the verifier checks validity at the document's own `timestamp`:

```ts
const leaf = verifyChain({
  leaf: document.certificate,
  cabundle: document.cabundle,
  pinnedRoot: AWS_NITRO_ROOT_DER,
  atMs: document.timestampMs,
});
```

This trades away freshness, so freshness has to come from somewhere else. Here it comes from the chain. The document's hash was pinned in the registry when the build was registered, after a live check (check 6). The entry must still be active (check 7). An enclave restart generates a new key, so the old build's entry is retired, and tiers it signed stop passing.

## PCR16 is a hash of text, comments included

Check 3 is what ties the running enclave to code anyone can read. Oyster extends PCR16 with the compose file it booted from:

```ts
export function pcr16FromCompose(compose: Uint8Array): Uint8Array {
  const path = new TextEncoder().encode(COMPOSE_INIT_PARAM_PATH);
  const params = sha256(
    sha256(concat([u64le(path.length), path, u64le(compose.length), compose]))
  );
  return sha384(concat([new Uint8Array(PCR_LEN), params]));
}
```

Every byte counts, including comments and trailing newlines. So the compose file pins the enclave's container image by digest, and the verifier fetches it at the build's **release tag**, not from `main`. Fix a typo in a comment on `main` and the hash no longer matches the running enclave. The deployment record carries the tag for exactly this reason.

## Seven passes weren't the verdict

The first version printed `VERDICT PASS` when all seven checks passed. The same AI reviewer found the gap, and it wasn't in the cryptography.

The seven checks prove the _registry entry_ is genuine. They don't prove the _tier_ went through it. Only the oracle program verifies the enclave's signature before writing a tier, and it writes through one signer: an address derived from the oracle's program id. A tier written by any other signer never passed that check, however good its registry entry looks.

The first version showed "UNEXPECTED signer" as a fact and still printed PASS. Now the signer is part of the verdict:

```ts
export function verdictOf(
  checks: Check[],
  attestation: Pick<AttestationFacts, "signerOk">
): Verdict {
  return attestation.signerOk && checks.every(c => c.status === "pass")
    ? "PASS"
    : "FAIL";
}
```

The same review left a rule I now apply everywhere: never trust a value you can derive. The verifier re-derives the signer address from the program id instead of reading it from a file, and it checks that the deployment file's program ids equal the constants compiled into the client.

## Why the browser checks a copy

The live enclave serves its attestation over plain HTTP. An HTTPS page can't fetch that: browsers block it as mixed content.

So the verify page ships each archived document as a lazily loaded chunk of the same build. That sounds like "trust my copy", but it isn't. AWS signed the document, and its SHA-256 is pinned on chain. A wrong copy fails check 6. It doesn't matter who carries the bytes.

I also dropped a planned `--live` option. Oyster's attestation server signs a fresh document for every request, so a live document's hash can never equal the archived one on chain. A live document can cross-check the key and image id; it can't replace the archive.

## What a PASS doesn't prove

- **That the code is correct.** Attestation proves _which_ code ran. Nothing has been audited yet.
- **That registration was honest.** An admin key registers each build after checking it off-chain. Every registration is public, but a compromised admin could register a key whose document would still pass. Beyond the demo that should be a multisig, and later the chain itself should verify the document.
- **That a lender should accept the tier today.** PASS is about where the tier came from. Expiry and each pool's own rules are separate.
- **That the bank data was real.** The demo bank is a sandbox that speaks the real protocol with demo keys.

## If you verify Nitro attestations yourself

- **Hash the bytes you received.** Decode to read; never re-encode to verify. Write a negative test with a non-canonical encoding, because real data won't tell the two apart.
- **Expect high-S signatures** if your ECDSA library enforces low-S by default.
- **Decide what time you check the chain at.** Now, for live attestation. The document's timestamp, for archived evidence, and then get freshness from somewhere else.
- **Pin the root in code.** Don't fetch it.
- **Fetch measured files at the release tag.** A PCR over a text file changes with every byte.
- **Check who wrote the claim, not just what it points to.** Seven green checks on the wrong signer is still a FAIL.

The verifier is about 1,600 lines of TypeScript, with no WebCrypto, so the same code runs in Node and the browser: [`verifier/`](https://github.com/pandaa880/tee-income-oracle/tree/v0.5.5/verifier). The [verify page](https://tee-income-oracle-web.vercel.app/verify) runs it in your browser.
