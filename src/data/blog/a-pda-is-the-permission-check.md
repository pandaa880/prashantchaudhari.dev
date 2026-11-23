---
title: "A PDA is the permission check: how a Solana pool refuses someone else's income tier"
description: "What TEE Income Oracle keeps on Solana and how the lending pool uses it: an append-only registry, an attestation address derived from the borrower, a signed message that can't be replayed, and why the oracle's signer is a PDA with no private key."
pubDatetime: 2026-12-03T17:00:00+05:30
tags:
  - solana
  - anchor
  - pda
  - attestation
  - security
draft: true
---

> **TL;DR:** On chain, TIO keeps a registry of approved enclave builds and one attestation per borrower. The pool doesn't look a tier up by a name the borrower gives it. It derives the attestation address from the wallet that signed the borrow, so a borrower can only ever land on their own tier. The oracle's signer is a PDA, so there is no key to steal. I also explain why the signature check uses secp256k1, and what that costs.

**This is part 3 of 4 on how TEE Income Oracle works.**

1. [A bank statement goes in, a risk tier comes out: the trust model of an income oracle on Solana](/posts/trust-model-of-an-income-oracle/)
2. [My own server carries every byte and still can't read or forge one: six hops through an enclave](/posts/six-hops-through-an-enclave/)
3. **[A PDA is the permission check: how a Solana pool refuses someone else's income tier](/posts/a-pda-is-the-permission-check/)**
4. [The crypto held, the restarts didn't: what breaks first in an enclave oracle](/posts/the-crypto-held-the-restarts-didnt/)

[Part 2](/posts/six-hops-through-an-enclave/) ended with the last two hops: the enclave's signed result goes to Solana, and the borrower borrows against it. This post is about those two. It assumes you know what a PDA is (a Program Derived Address: an address derived from seeds that only the deriving program can sign for) and roughly how an Anchor program is laid out. The scope is the same as before: devnet, and a sandbox bank.

## What lives on chain

Four things on Solana carry the weight.

- **The registry** maps an image id to the attester key and its status. Ids are append-only and never reused, even after a revoke, so revoking one permanently invalidates its attestations. The id space is 255 for the life of a deployment.
- **The attestation address** is derived from the borrower's wallet. The pool derives it from the wallet that signs the borrow, so it can't be handed another wallet's tier. This is a PDA used as an authorization check.
- **The signed message** is domain-separated: it covers a tag, the program, the credential, the schema, the wallet, the payload and an expiry, so a signature can't be replayed in another context.
- **Refreshes** need a strictly newer `issued_at` per wallet, so an old signature can't replace a newer tier.

Nothing personal goes on chain. The attestation carries a tier, ids, hashes and timestamps, in an 83-byte payload.

## The PDA is the permission check

Most access control in a program is a check you write: `require!(caller == owner)`. Here the check is the address itself.

The tier is stored as a Solana Attestation Service (SAS) attestation, a standard credential any program can read. Its address is a PDA derived from the seeds `attestation`, the credential, the schema and a nonce, and the nonce is the borrower's wallet. When someone borrows, the pool doesn't accept an attestation account the caller points at. It derives the address from the wallet that signed the transaction and reads that account.

So the borrower can only reach their own tier. To use someone else's income, they would have to sign as that wallet. No comparison in my code can be forgotten, because there is nothing to compare: the wrong tier has no address the pool will ever derive.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 424 540" role="img" aria-labelledby="tio-d3-title tio-d3-desc" style="display:block;width:100%;max-width:440px;height:auto;margin:1.5rem auto" font-size="12" text-anchor="middle">
<title id="tio-d3-title">How the pool finds a borrower's tier</title>
<desc id="tio-d3-desc">The borrow transaction is signed by wallet W. The pool derives the attestation address from the seeds attestation, credential, schema and a nonce equal to W, then reads the account at that address. It checks the credential, the schema, that the signer is the oracle PDA, freshness, that the enclave build is approved and active, and the policy hash. A tier written for a different wallet V sits at a different address, which the pool never derives from W, so there is nothing for W to point at.</desc>
<defs>
<marker id="tio-d3-a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="currentColor"/></marker>
</defs>
<g fill="var(--muted)" stroke="currentColor" stroke-width="1">
<rect x="16" y="10" width="392" height="40" rx="4"/>
<rect x="16" y="76" width="392" height="62" rx="4"/>
<rect x="16" y="164" width="392" height="38" rx="4"/>
<rect x="16" y="228" width="392" height="158" rx="4"/>
</g>
<rect x="16" y="412" width="392" height="36" rx="4" fill="var(--muted)" stroke="var(--accent)" stroke-width="2"/>
<rect x="16" y="470" width="392" height="62" rx="4" fill="none" stroke="currentColor" stroke-width="1" stroke-dasharray="4 3" opacity="0.7"/>
<g fill="none" stroke="currentColor" stroke-width="1.5" marker-end="url(#tio-d3-a)">
<path d="M212,50 V76"/>
<path d="M212,138 V164"/>
<path d="M212,202 V228"/>
<path d="M212,386 V412"/>
</g>
<g fill="currentColor">
<text x="212" y="35">Borrow, signed by wallet W</text>
<text x="212" y="98" font-weight="bold">Pool derives the address from W</text>
<text x="212" y="116">seeds: attestation, credential,</text>
<text x="212" y="130">schema, nonce = W</text>
<text x="212" y="188">Pool reads the account at that address</text>
<text x="212" y="436">Tier accepted, borrow goes ahead</text>
</g>
<g fill="currentColor" text-anchor="start">
<text x="32" y="250" font-weight="bold">Pool checks what it read</text>
<text x="32" y="274">✓ credential is the pinned one</text>
<text x="32" y="294">✓ schema is the pinned one</text>
<text x="32" y="314">✓ signer is the oracle's PDA</text>
<text x="32" y="334">✓ fresh enough</text>
<text x="32" y="354">✓ enclave build approved, still active</text>
<text x="32" y="374">✓ policy hash matches</text>
<text x="44" y="490">Wallet V's tier sits at a different address</text>
<text x="44" y="507">(nonce = V). The pool never derives that</text>
<text x="44" y="524">from W, so W has nothing to point at.</text>
</g>
<text x="28" y="491" fill="currentColor" font-weight="bold" font-size="14" text-anchor="start">✕</text>
</svg>

The pool still checks what it reads. It pins the credential and schema through the address, and it requires the stored signer to be the oracle's own derived address, so a foreign credential can't pass. It also checks freshness, that the enclave build is approved and still active, and the policy hash. That is the G6 link from [part 1](/posts/trust-model-of-an-income-oracle/).

## The oracle's signer is a PDA too

The SAS credential has an authorized signer. In TIO that signer is a PDA of the oracle program, derived from the seed `sas_signer`. It has no private key.

That matters for two reasons. It can't be stolen, because there is nothing to steal. And only the oracle program's logic can sign with it, which means a tier can be written only after the program has checked the enclave's signature against the registry. The enclave never writes to chain itself. It signs a payload, and the program decides whether to turn that into an attestation.

## A signature that can't be replayed

The enclave signs a message, and what it signs is domain-separated. The signed bytes cover a tag, the program, the credential, the schema, the wallet, the payload and an expiry. Each part closes a replay:

- The **tag, program, credential and schema** stop a signature from one deployment or one schema being accepted by another.
- The **wallet** stops one borrower's signature being used for another.
- The **expiry** stops an old signature from living forever.

Replacing a tier follows one more rule: a refresh must carry a strictly newer `issued_at` for that wallet. Without it, someone could resubmit an older, better signature over a newer, worse tier. A refresh closes the old attestation and creates a new one, and `submit_attestation` does both itself. The relayer gets the old rent back and pays the new rent, so a refresh costs about nothing.

The SAS attestation expires 30 days after `issued_at`, and the pool adds its own limits on attestation age, statement age and statement length.

## Why SAS and not a custom program

**Pro.** A tier written as a standard credential is readable by any pool, not just mine. Any pool that reads SAS can read it.

**Con.** I depend on someone else's program. The rent for an attestation (about 0.002 SOL) stays locked until the same wallet refreshes, because I haven't built a close path for expired attestations.

## Why secp256k1, and what it costs

The enclave signs with a secp256k1 key because Oyster gives each enclave one at boot. So the oracle uses Solana's secp256k1 precompile rather than the native ed25519 one.

**Pro.** Solana verifies the signature in a built-in instruction, and the key type is platform-neutral, so changing the TEE never changes the on-chain check.

**Cost.** Every transaction carries an extra instruction and the bytes that go with it.

There is also a classic bug class here. The program never verifies the signature itself. The precompile does, one instruction earlier, and the program reads back what the precompile was given. The instruction-index fields in the precompile instruction must point at the precompile itself, or an attacker can make the check pass against other data. I test that case explicitly. If you copy this pattern, test it too. The five checks, and the attack each one stops, are in [Don't pass the signed bytes twice](/posts/dont-pass-the-signed-bytes-twice/).

How the attested key is tied to this exact code (G3 and G4) is covered in [Seven checks: verifying an AWS Nitro attestation in the browser](/posts/seven-checks-nitro-attestation/).

## What this doesn't cover

The registry is still the weak link, G5 from part 1. An admin registers the enclave key, and in the demo that same wallet is also the program upgrade authority. The PDA design protects borrowers from each other. It doesn't protect anyone from a stolen admin key. That, and what I'd change, is in [part 4](/posts/the-crypto-held-the-restarts-didnt/).

## Where to look yourself

- [`docs/ARCHITECTURE.md`](https://github.com/pandaa880/tee-income-oracle/blob/main/docs/ARCHITECTURE.md): the on-chain layout and the threat table
- [`docs/FORMATS.md`](https://github.com/pandaa880/tee-income-oracle/blob/main/docs/FORMATS.md): the 83-byte payload and the signed message, byte by byte
- The [verify page](https://tee-income-oracle-web.vercel.app/verify) reads Solana directly and checks a borrower's tier. As of 23 November 2026 it is up, on a paid enclave that runs to about 8 December. After that the hosted pages may go offline. The repo, the docs and the verifier stay.

**Previous:** [part 2](/posts/six-hops-through-an-enclave/), six hops through an enclave. **Next:** [part 4](/posts/the-crypto-held-the-restarts-didnt/) covers what breaks first.
