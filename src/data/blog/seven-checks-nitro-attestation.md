---
title: "Seven checks: verifying an AWS Nitro attestation in the browser"
description: "My server says an enclave scored this borrower. The verify page checks that claim itself, against AWS's signature and Solana, without asking my server. Seven checks, and where the obvious code would have been wrong."
pubDatetime: 2026-11-07T15:30:00+05:30
tags:
  - aws-nitro
  - attestation
  - typescript
  - cryptography
  - solana
draft: true
---

I'm building [TEE Income Oracle](https://github.com/pandaa880/tee-income-oracle). It reads a borrower's bank statement inside a sealed-off part of an AWS server, works out a credit tier (A, B or C), signs it, and writes it to Solana. A lending pool reads the tier there before it lends.

That sealed-off part is an AWS Nitro **enclave**: an isolated machine that nobody, including me as the operator, can log into or look inside while it runs. That's the point of using one. The bank statement goes in; only the tier comes out.

But a lender has no reason to take my word that the tier came from an enclave, or that the enclave runs the code I published. So the enclave can produce proof, called an **attestation document**. AWS's hardware signs it, and it says two things: which code booted, and which signing key the enclave created for itself. If the document checks out, a tier signed with that key came from that code.

The proof only helps if someone other than me checks it. So I wrote a verifier, a TypeScript library that also runs in the browser, on the app's [verify page](https://tee-income-oracle-web.vercel.app/verify). You give it a borrower's wallet, it reads Solana directly, and it runs seven checks on that borrower's tier. Nothing goes through my server.

This post is for developers who have heard of enclaves or "verifiable compute" and want to see what checking one actually involves. You don't need to know AWS Nitro, or any cryptography beyond "a signature proves who signed some bytes". I'll explain the rest as it comes up.

**What this post covers:**

- What's inside an attestation document, and how a tier on Solana leads back to one.
- The seven checks, in plain words.
- Four places where the obvious code would have been wrong: checking a re-packed copy instead of the signed bytes, rejecting a genuine AWS signature, failing every document a few hours after it was made, and a code fingerprint that changes when you edit a comment.
- The gap my AI code reviewer found, which had nothing to do with cryptography.
- Why the browser checks a copy of the document, and why that's still safe.
- What a pass doesn't prove, and a checklist if you verify attestations yourself.

## Table of contents

## What's inside the document

The document is a small binary file. Inside is a set of named fields, stored in CBOR, a compact binary format that does for binary data what JSON does for text. AWS signs that data and wraps it, with the signature, in a standard envelope called COSE_Sign1 ([AWS describes the format here](https://docs.aws.amazon.com/enclaves/latest/user/verify-root.html)). Four fields matter for this post:

| Field                     | What it means                                                                                                 |
| :------------------------ | :------------------------------------------------------------------------------------------------------------ |
| `pcrs`                    | Fingerprints of what booted. Each PCR (platform configuration register) is a hash of one part of the software |
| `certificate`, `cabundle` | The certificate whose key signed the document, and the chain of certificates that links it back to AWS        |
| `timestamp`               | When the document was made                                                                                    |
| `public_key`              | A key the enclave generated when it started. My enclave signs tiers with it                                   |

My enclave runs on [Marlin Oyster](https://docs.marlin.org/oyster/), a service that rents out Nitro enclaves. Oyster boots its own fixed base system, then starts my app from a `docker-compose.yml` file. PCR0, PCR1 and PCR2 fingerprint the base system. PCR16 fingerprints my compose file. Hashed together, those four give an **image id**: one value that names one exact build of the enclave.

On Solana, a registry keeps one entry per enclave build: its image id, its signing key, a hash of its attestation document, and whether it has been retired. So from a borrower's wallet, the verifier can follow four links back to AWS's hardware:

wallet → the tier on Solana → the registry entry for the build that signed it → that build's attestation document

## The seven checks

| #   | Check                                         | What it asks                                                                    |
| :-- | :-------------------------------------------- | :------------------------------------------------------------------------------ |
| 1   | Signed by AWS Nitro hardware                  | Is the signature valid, and does its certificate chain end at AWS's root?       |
| 2   | Marlin's published base image, not debug mode | Do PCR0–2 match Marlin's published values? (Debug mode zeroes them.)            |
| 3   | Runs our published code                       | Does PCR16 match the compose file at the release tag?                           |
| 4   | Image id matches the registry                 | Do the four PCRs give the image id the registry recorded?                       |
| 5   | Enclave key = on-chain attester               | Is the document's key the one the registry says signs tiers?                    |
| 6   | Same document the registry recorded           | Does this document's hash match the one stored on Solana?                       |
| 7   | Entry is active                               | Is the registry entry still active, and for the same type of proof as the tier? |

The verifier runs all seven even after one fails, so a bad document shows everything wrong with it at once.

AWS's root certificate, where every chain must end, is built into the verifier. It's never downloaded, because a verifier that downloads its root trusts whoever answers the download. A test checks the built-in copy against the fingerprint AWS publishes.

## 1. Check the bytes that were signed, not a re-packed copy

A signature covers exact bytes. Two files can hold the same data and still differ byte for byte, and then the signature fits only one of them.

That's the trap here. CBOR can store a set of fields in two ways: with the number of fields written at the start, or with an "end" marker after the last one. Nitro uses the second way. A CBOR library reads it fine, but when it packs the data back up, it uses the first. I tried it on one of my archived documents: 4,478 bytes became 4,477, and AWS's signature no longer matched.

So the verifier decodes the data only to read its fields. It checks the signature over the bytes exactly as they arrived.

The same rule applies to the certificates. A certificate's signature covers one section of the certificate, and the verifier checks that section exactly as it appears in the file, never a version it decoded and packed again.

My tests nearly missed this. AWS's real certificates are packed in the standard way, so re-packing gives back the same bytes and both approaches pass. My AI code reviewer asked for a test that tells them apart. It takes a real certificate and writes one length field the long way round: the same certificate, but different bytes, and not the bytes AWS signed. A verifier that re-packs turns it back into the signed bytes and accepts it. One that checks the bytes as received rejects it, as it should.

## 2. A genuine AWS signature my library rejected

The signature scheme here, ECDSA, has a quirk: every valid signature has a twin. From one valid signature, anyone can compute a second, different one that's also valid. To stop that, many systems accept only one of the two, called the "low-S" form. The library I use, [noble-curves](https://github.com/paulmillr/noble-curves), does that by default.

AWS's Nitro signer doesn't always produce the low-S form. One of my three archived documents has the other one, so with noble's default settings, a genuine AWS signature failed. With `lowS: false`, it passes. I checked both on the real document.

```ts
// sigStructure wraps the payload bytes exactly as they arrived.
const valid = p384.verify(
  cose.signature,
  sha384(sigStructure(cose)),
  publicKeyPoint,
  { lowS: false, prehash: false },
);
```

Turning that rule off is safe here. The rule matters where a signature works as an id, like a transaction id, so a twin could pass as a different transaction. Here, a signature is evidence about a document whose hash is already on Solana. Its twin proves nothing new.

## 3. Check the certificates as of the document's date, not today's

Certificates expire. AWS's guide says to check that today's date falls inside every certificate's validity period. That's right when you've just asked a running enclave to prove itself.

My verifier checks archived documents, and the certificate that signs each one is valid for only about three hours. When I checked against today's date, all three archived documents failed. The oldest is from 2026-10-08, and some certificates in its chain had already expired. Checked against today, every verification would fail a few hours after the document was made.

So the verifier checks the certificates as of the document's own timestamp:

```ts
const leaf = verifyChain({
  leaf: document.certificate,
  cabundle: document.cabundle,
  pinnedRoot: AWS_NITRO_ROOT_DER,
  atMs: document.timestampMs,
});
```

That gives something up: the check no longer shows the document is recent. So that has to come from Solana instead. The document's hash was stored in the registry when the build was registered, right after a live check (check 6), and the entry must still be active (check 7). When the enclave restarts, it creates a new key, so the old build's entry is retired, and tiers it signed stop passing.

## 4. A code fingerprint that changes when you edit a comment

Check 3 is what ties the running enclave to code anyone can read. Oyster computes PCR16 from the full text of the compose file it started from ([the recipe](https://github.com/pandaa880/tee-income-oracle/blob/v0.5.5/verifier/src/nitro/image-id.ts) is a few lines of hashing). Every byte counts, including comments and the newline at the end. Fix a typo in a comment, and the fingerprint no longer matches the running enclave.

Two things follow. The compose file names my app's container image by its digest, a hash of the image itself, so the text points at exact code rather than a tag that can be moved. And the verifier reads the compose file from the build's **release tag**, not from the `main` branch, because `main` keeps changing. The deployment record stores the tag for exactly this reason.

## 5. Seven passes weren't the verdict

My first version printed PASS when all seven checks passed. My AI code reviewer found the gap, and it had nothing to do with cryptography.

The seven checks prove that the registry entry is genuine. They don't prove that the tier went through it. Other accounts can write records that look like tiers. What makes a tier trustworthy is who wrote it. The oracle program checks the enclave's signature before it writes a tier, and it always writes from one fixed address that only the program controls. A tier written from any other address never went through that check, however genuine the registry entry it points to.

The first version even showed "UNEXPECTED signer" on screen, and still printed PASS. Now the writer is part of the verdict:

```ts
export function verdictOf(
  checks: Check[],
  attestation: Pick<AttestationFacts, "signerOk">,
): Verdict {
  const allChecksPass = checks.every((check) => check.status === "pass");
  return attestation.signerOk && allChecksPass ? "PASS" : "FAIL";
}
```

The same review gave me a rule I now follow everywhere: never trust a value you can work out yourself. The verifier computes the program's fixed address from the program's id instead of reading it from a config file, and it checks that the program ids in the deployment file match the ones built into the app.

## 6. Why the browser checks a copy

The enclave serves its attestation over plain HTTP. A page loaded over HTTPS can't fetch from plain HTTP: browsers block it as "mixed content".

So the verify page ships the archived documents as part of the site, loaded only when needed. That sounds like "trust my copy", but it isn't. AWS signed the document, and its hash is stored on Solana. A changed copy fails check 6. It doesn't matter who delivers the bytes.

I also dropped a planned option to fetch the document live from the enclave. Oyster's attestation server signs a fresh document for every request, so a live document never has the same hash as the archived one on Solana. A live document can confirm the key and the image id, but it can't replace the archive.

## What a PASS doesn't prove

- **That the code is correct.** A pass proves which code ran, not that the code is right. Nothing has been audited yet.
- **That registration was honest.** An admin key registers each build after checking its document off chain. Every registration is public, but someone holding a stolen admin key could register a key whose document would still pass. Beyond the demo, that should be a multisig, and later Solana itself should check the document.
- **That a lender should accept the tier today.** A pass says where the tier came from. Whether it has expired, and whether it meets a pool's rules, are separate checks.
- **That the bank data was real.** The demo bank is a sandbox: it speaks the real protocol, with demo keys.

## If you verify attestations yourself

- **Check the signature over the bytes you received.** Decode only to read fields; never re-pack before verifying. Write a test with an unusual but valid encoding, because real data won't catch the mistake.
- **Expect signatures in the "high-S" form** if your ECDSA library rejects them by default.
- **Decide which date you check certificates against.** Today, for a live attestation. The document's own date, for an archived one, and then show it's still current some other way.
- **Build the root certificate into your code.** Don't download it.
- **Read measured files from the release tag.** A fingerprint of a text file changes with every byte.
- **Check who wrote the claim, not just what it points to.** Seven green checks on the wrong writer is still a fail.

The verifier is about 1,600 lines of TypeScript. It doesn't use the browser's built-in crypto API, so the same code runs in Node and in the browser: [`verifier/`](https://github.com/pandaa880/tee-income-oracle/tree/v0.5.5/verifier). The [verify page](https://tee-income-oracle-web.vercel.app/verify) runs it in your browser.
