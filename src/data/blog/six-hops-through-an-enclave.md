---
title: "My own server carries every byte and still can't read or forge one: from borrower to Solana pool in six hops"
description: "Follow one session from the borrower through my gateway, the enclave and the bank to the Solana lending pool. What my own server sees and can do at each of six hops, why the enclave's clock is not trusted, and how a PDA turns the last hop into a permission check."
pubDatetime: 2026-11-24T18:00:00+05:30
tags:
  - solana
  - aws-nitro
  - architecture
  - security
  - anchor
draft: false
---

> **TL;DR:** In TEE Income Oracle my gateway touches every message and still can't read the statement or change the tier, because each hop is signed, encrypted or bound to a one-time value. What a carrier can still do is stop the bytes, so availability isn't protected. The enclave doesn't trust its own clock either. On Solana the last hop works because the pool derives the attestation address from the wallet that signed the borrow, so a borrower can only ever reach their own tier. If you came for the Solana part, jump to [the PDA section](#the-borrow-hop-on-solana-a-pda-is-the-permission-check).

**This is part 2 of 3 on how TEE Income Oracle works.**

1. [A bank statement goes in, a risk tier comes out: the trust model of an income oracle on Solana](/posts/trust-model-of-an-income-oracle/)
2. **[My own server carries every byte and still can't read or forge one: from borrower to Solana pool in six hops](/posts/six-hops-through-an-enclave/)**
3. [The crypto held, the restarts didn't: what breaks first in an enclave oracle](/posts/the-crypto-held-the-restarts-didnt/)

[Part 1](/posts/trust-model-of-an-income-oracle/) set up the trust model: an enclave scores a bank statement, and everything outside it, including my own gateway, is treated as hostile. This post walks one session through to show what that means in practice, from the borrower's first click to the Solana pool that lends against the result. The scope is the same: Solana devnet and a sandbox bank I wrote.

If you want the other end of this, the browser page that refuses to show a tier until Solana agrees, read [The browser doesn't trust the server](/posts/the-browser-doesnt-trust-the-server/). It is the same idea from the frontend side.

## One session, end to end

Here is the happy path, trimmed to the steps that matter. The full sequence is in the repo's architecture doc.

<svg class="ss" viewBox="0 0 440 440" role="img" aria-labelledby="ss-title ss-desc" xmlns="http://www.w3.org/2000/svg">
  <title id="ss-title">One TIO session, step by step</title>
  <desc id="ss-desc">Eleven numbered steps between the borrower, the gateway, the enclave, the bank and Solana. The borrower starts a session. The bank returns an AA-signed consent. The gateway asks the enclave for a new session, and the enclave returns a signed data request. The borrower signs the intent with their wallet. The gateway carries the signed request to the bank, which returns the encrypted statement. The gateway sends the raw bytes to the enclave, which verifies, decrypts, scores and wipes, then returns the tier and a signature. The gateway submits the result to Solana. The borrower borrows against the attestation.</desc>
  <style>
    svg.ss { display: block; width: 100%; height: auto; max-width: 440px; margin-inline: auto; font-family: inherit; }
    svg.ss .lane { fill: none; stroke: var(--foreground); stroke-opacity: 0.4; stroke-width: 1; stroke-dasharray: 3 4; }
    svg.ss .head { fill: var(--muted); fill-opacity: 0.35; stroke: var(--foreground); stroke-width: 1.25; }
    svg.ss .head-enclave { stroke: var(--accent); stroke-width: 2.5; }
    svg.ss .note { fill: var(--background); stroke: var(--accent); stroke-width: 2.5; }
    svg.ss .t { fill: var(--foreground); font-size: 14px; text-anchor: middle; }
    svg.ss .t-note { font-size: 12px; }
    svg.ss .edge { fill: none; stroke: var(--foreground); stroke-width: 1.5; marker-end: url(#ss-arrow); }
    svg.ss .edge-label { fill: var(--foreground); font-size: 12px; text-anchor: middle; paint-order: stroke; stroke: var(--background); stroke-width: 4; stroke-linejoin: round; }
    svg.ss .arrow-head { fill: var(--foreground); }
  </style>
  <defs>
    <marker id="ss-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path class="arrow-head" d="M0 0 L10 5 L0 10 z" />
    </marker>
  </defs>
  <path class="lane" d="M44 40 V434" />
  <path class="lane" d="M134 40 V434" />
  <path class="lane" d="M224 40 V434" />
  <path class="lane" d="M314 40 V434" />
  <path class="lane" d="M398 40 V434" />
  <rect class="head" x="6" y="6" width="76" height="32" rx="6" />
  <text class="t" x="44" y="27">Borrower</text>
  <rect class="head" x="96" y="6" width="76" height="32" rx="6" />
  <text class="t" x="134" y="27">Gateway</text>
  <rect class="head head-enclave" x="186" y="6" width="76" height="32" rx="6" />
  <text class="t" x="224" y="27">Enclave</text>
  <rect class="head" x="276" y="6" width="76" height="32" rx="6" />
  <text class="t" x="314" y="27">Bank</text>
  <rect class="head" x="366" y="6" width="64" height="32" rx="6" />
  <text class="t" x="398" y="27">Solana</text>
  <path class="edge" d="M44 72 H134" />
  <path class="edge" d="M314 102 H134" />
  <path class="edge" d="M134 132 H224" />
  <path class="edge" d="M224 162 H134" />
  <path class="edge" d="M44 192 H134" />
  <path class="edge" d="M134 222 H314" />
  <path class="edge" d="M314 252 H134" />
  <path class="edge" d="M134 282 H224" />
  <rect class="note" x="236" y="292" width="124" height="40" rx="6" />
  <text class="t t-note" x="298" y="308">verify, decrypt,</text>
  <text class="t t-note" x="298" y="323">score, wipe</text>
  <path class="edge" d="M224 352 H134" />
  <path class="edge" d="M134 382 H398" />
  <path class="edge" d="M44 412 H398" />
  <text class="edge-label" x="89" y="66">1 start</text>
  <text class="edge-label" x="224" y="96">2 AA-signed consent</text>
  <text class="edge-label" x="179" y="126">3 session</text>
  <text class="edge-label" x="179" y="156">4 request</text>
  <text class="edge-label" x="89" y="186">5 wallet sig</text>
  <text class="edge-label" x="224" y="216">6 signed request</text>
  <text class="edge-label" x="224" y="246">7 encrypted data</text>
  <text class="edge-label" x="179" y="276">8 raw bytes</text>
  <text class="edge-label" x="179" y="346">9 tier + sig</text>
  <text class="edge-label" x="266" y="376">10 submit</text>
  <text class="edge-label" x="221" y="406">11 borrow</text>
</svg>

1. The borrower starts a session with the gateway, giving a wallet and a test borrower profile (a persona).
2. The gateway asks the sandbox bank for consent, and gets back a consent signed by the AA.
3. The gateway asks the enclave to create a session, passing the policy, the wallet and the consent.
4. The enclave returns a signed data request. The new session key was created inside it.
5. The borrower signs the session intent with their wallet.
6. The gateway carries the signed request to the bank, unchanged.
7. The bank returns an encrypted statement with signatures.
8. The gateway hands the raw bytes to the enclave. The enclave verifies, decrypts, scores and wipes.
9. The enclave returns an 83-byte payload and a signature.
10. The gateway submits it to Solana, where a secp256k1 check runs and a SAS attestation is created.
11. The borrower borrows against the attestation.

Notice who does what. The gateway (my server) is in the middle of nearly every step. The enclave is in steps 3, 4, 8 and 9. The gateway never holds a key that matters.

## What the gateway can and can't do

The gateway touches every message and can still do very little. This table shows what it sees at each hop and what it can't do:

| Hop            | The gateway/host sees                      | It can           | It cannot                                                                                                        |
| -------------- | ------------------------------------------ | ---------------- | ---------------------------------------------------------------------------------------------------------------- |
| Session create | Public key material and the signed request | Read public keys | Change the key (the signature covers it) or swap the enclave's request key (the bank checks a binding signature) |
| Bind wallet    | The intent and the wallet signature        | Drop it          | Bind a wallet it doesn't control                                                                                 |
| Fetch          | Ciphertext and signed envelopes            | Store it         | Decrypt it or alter it (the AES-GCM tag and signatures break)                                                    |
| Evaluate       | Raw bytes in, signed payload out           | Replay old bytes | Get them accepted (one-time session nonce)                                                                       |
| Submit         | The Solana transaction                     | Censor it        | Change the tier (the signature breaks)                                                                           |
| Borrow         | Nothing relevant                           | Nothing          | Use another wallet's attestation, a stale one, or one from a build the pool hasn't approved                      |

Read the "cannot" column as a list of the reasons each hop holds:

- **Session create** holds because the enclave signs the request that carries its keys. If the gateway changed a key, the signature would no longer match.
- **Bind wallet** holds because the borrower signs the intent with their own wallet. The gateway has no way to produce that signature.
- **Fetch** holds because the statement is encrypted to a key that only exists inside the enclave, and the bank's signatures cover what's sent. A changed byte breaks the AES-GCM tag.
- **Evaluate** holds because each session has a one-time nonce. Replaying old bytes gets nothing accepted.
- **Submit** holds because the signature covers the tier. A relayer that edits it invalidates it.
- **Borrow** holds because of how the pool finds the tier, which is the last section of this post.

One more rule sits under all of this: verify before parse. The enclave checks signatures with pinned keys before it parses anything, so hostile bytes never reach the parser. The keys are compiled into the image. That is the cost: rotating one means shipping a new build. I accept it, because it is the point of the second move in [part 1](/posts/trust-model-of-an-income-oracle/): a key compiled into the measured image can't be swapped by the host.

## Why plain HTTP is fine

The enclave talks plain HTTP to the gateway. That sounds wrong, and it's fine for a specific reason: every byte that matters is signed or encrypted end to end. The enclave produces signed requests and consumes signed responses. Whoever carries them can't change them.

That covers integrity. It does not cover availability. The enclave's port is public, so anyone who can get consents can fill its 256 open-session slots and lock other borrowers out. The gateway rate-limits session creation, and I accept this as a liveness risk. The host and gateway can already deny service anyway, so availability was never something this design could promise. The last column of the table says "censor it" for a reason.

## The enclave's clock is not trusted

There is one more thing a carrier controls: time. The host runs the enclave's clock, so the enclave can't be asked what day it is.

So the scoring window doesn't come from the clock. It comes from the statement's own dates, which must sit inside the range the enclave requested and inside the signed consent. Freshness is checked on chain, against the Solana clock. The check allows five minutes of skew, and a signature is usable for ten minutes after it is issued.

The cost is that the limits are fixed. A submission that arrives after the ten-minute window is rejected.

## The Borrow hop on Solana: a PDA is the permission check

The last two hops are the ones on Solana: the gateway submits the enclave's signed result, and the borrower borrows against it. This section assumes you know what a PDA is (a Program Derived Address, an address derived from seeds that only the deriving program can sign for) and roughly how an Anchor program is laid out.

### What lives on chain

Four things on Solana carry the weight.

- **The registry** maps an image id to the attester key and its status. Ids are append-only and never reused, even after a revoke, so revoking one permanently invalidates its attestations. The id space is 255 for the life of a deployment.
- **The attestation address** is derived from the borrower's wallet. The pool derives it from the wallet that signs the borrow, so it can't be handed another wallet's tier.
- **The signed message** is domain-separated, so a signature can't be replayed in another context.
- **Refreshes** need a strictly newer `issued_at` per wallet, so an old signature can't replace a newer tier.

Nothing personal goes on chain. The attestation carries a tier, ids, hashes and timestamps, in an 83-byte payload.

### The address is the permission check

Most access control in a program is a check you write: `require!(caller == owner)`. Here the check is the address itself.

The tier is stored as a Solana Attestation Service (SAS) attestation, a standard credential any program can read. Its address is a PDA derived from the seeds `attestation`, the credential, the schema and a nonce, and the nonce is the borrower's wallet. In the pool's `borrow` instruction the `borrower` account must sign, and the attestation account's seeds use that key. The credential and schema come from the pool's own config. The pool doesn't accept an attestation account the caller points at. It derives the address from the signer and reads that account.

So the borrower can only reach their own tier. To use someone else's income, they would have to sign as that wallet. No comparison in my code can be forgotten, because there is nothing to compare: the wrong tier has no address the pool will ever derive. The payer can be a different account, such as a relayer, but only the borrower's own key decides which attestation is read.

<svg class="pd" viewBox="0 0 440 590" role="img" aria-labelledby="pd-title pd-desc" xmlns="http://www.w3.org/2000/svg">
  <title id="pd-title">How the pool finds a borrower's tier</title>
  <desc id="pd-desc">The borrow transaction is signed by wallet W. The pool derives the attestation address from the seeds attestation, credential, schema and a nonce equal to W, then reads the account at that address. It checks that the credential and schema are the pinned ones, that the signer is the oracle's PDA, that the attestation is fresh, that the enclave build is approved and active, and that the policy hash matches. Then the borrow is allowed. A tier written for a different wallet sits at a different address, which the pool never derives from W, so W cannot point at it.</desc>
  <style>
    svg.pd { display: block; width: 100%; height: auto; max-width: 440px; margin-inline: auto; font-family: inherit; }
    svg.pd .box { fill: var(--muted); fill-opacity: 0.35; stroke: var(--foreground); stroke-width: 1.25; }
    svg.pd .box-ok { fill: var(--accent); fill-opacity: 0.12; stroke: var(--accent); stroke-width: 2.5; }
    svg.pd .box-side { fill: none; stroke: var(--foreground); stroke-opacity: 0.6; stroke-width: 1.25; stroke-dasharray: 5 4; }
    svg.pd .t { fill: var(--foreground); font-size: 14px; text-anchor: middle; }
    svg.pd .t-strong { font-weight: 700; }
    svg.pd .t-sub { font-size: 13px; }
    svg.pd .t-left { text-anchor: start; }
    svg.pd .mark { fill: var(--accent); font-size: 14px; font-weight: 700; }
    svg.pd .edge { fill: none; stroke: var(--foreground); stroke-width: 1.5; marker-end: url(#pd-arrow); }
    svg.pd .arrow-head { fill: var(--foreground); }
  </style>
  <defs>
    <marker id="pd-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path class="arrow-head" d="M0 0 L10 5 L0 10 z" />
    </marker>
  </defs>
  <path class="edge" d="M220 56 V82" />
  <path class="edge" d="M220 160 V188" />
  <path class="edge" d="M220 232 V258" />
  <path class="edge" d="M220 424 V450" />
  <rect class="box" x="20" y="10" width="400" height="46" rx="6" />
  <text class="t" x="220" y="38">Borrow transaction, signed by wallet W</text>
  <rect class="box" x="20" y="82" width="400" height="78" rx="6" />
  <text class="t t-strong" x="220" y="107">Pool derives the address from W</text>
  <text class="t t-sub" x="220" y="129">seeds: attestation, credential,</text>
  <text class="t t-sub" x="220" y="147">schema, nonce = W</text>
  <rect class="box" x="20" y="188" width="400" height="44" rx="6" />
  <text class="t" x="220" y="215">Pool reads the account at that address</text>
  <rect class="box" x="20" y="258" width="400" height="166" rx="6" />
  <text class="t t-strong t-left" x="38" y="284">Pool checks what it read</text>
  <text class="mark" x="38" y="312">✓</text>
  <text class="t t-sub t-left" x="62" y="312">credential and schema are the pinned ones</text>
  <text class="mark" x="38" y="334">✓</text>
  <text class="t t-sub t-left" x="62" y="334">signer is the oracle's PDA</text>
  <text class="mark" x="38" y="356">✓</text>
  <text class="t t-sub t-left" x="62" y="356">attestation is fresh</text>
  <text class="mark" x="38" y="378">✓</text>
  <text class="t t-sub t-left" x="62" y="378">enclave build approved and active</text>
  <text class="mark" x="38" y="400">✓</text>
  <text class="t t-sub t-left" x="62" y="400">policy hash matches</text>
  <rect class="box box-ok" x="20" y="450" width="400" height="46" rx="6" />
  <text class="t t-strong" x="220" y="478">Borrow allowed</text>
  <rect class="box-side" x="20" y="520" width="400" height="62" rx="6" />
  <text class="mark" x="36" y="545">✕</text>
  <text class="t t-sub t-left" x="62" y="545">Another wallet's tier sits at a different</text>
  <text class="t t-sub t-left" x="62" y="563">address. The pool never derives it from W.</text>
</svg>

The pool still checks what it reads. The address pins the credential and schema. The pool requires the stored signer to be the oracle's own derived address, so a foreign credential can't pass. It also checks freshness, that the enclave build is approved and still active, and the policy hash. That is the G6 link from [part 1](/posts/trust-model-of-an-income-oracle/).

### The oracle's signer is a PDA too

The SAS credential has an authorized signer. In TIO that signer is a PDA of the oracle program, derived from the seed `sas_signer`. It has no private key.

That matters for two reasons. It can't be stolen, because there is nothing to steal. And only the oracle program's logic can sign with it, which means a tier can be written only after the program has checked the enclave's signature against the registry. The enclave never writes to chain itself. It signs a payload, and the program decides whether to turn that into an attestation.

### A signature that can't be replayed

What the enclave signs is domain-separated. The signed bytes cover a tag, the program, the credential, the schema, the wallet, the payload and an expiry. Each part closes a replay:

- The **tag, program, credential and schema** stop a signature from one deployment or one schema being accepted by another.
- The **wallet** stops one borrower's signature being used for another.
- The **expiry** stops an old signature from living forever.

Replacing a tier follows one more rule: a refresh must carry a strictly newer `issued_at` for that wallet. Without it, someone could resubmit an older, better signature over a newer, worse tier. A refresh closes the old attestation and creates a new one, and `submit_attestation` does both itself. The relayer gets the old rent back and pays the new rent, so a refresh costs about nothing. The SAS attestation expires 30 days after `issued_at`, and the pool adds its own limits on attestation age, statement age and statement length.

### Why SAS and not a custom program

**Pro.** A tier written as a standard credential is readable by any pool that reads SAS, not just mine.

**Con.** I depend on someone else's program. The rent for an attestation (about 0.002 SOL) stays locked until the same wallet refreshes, because I haven't built a close path for expired attestations.

### Why secp256k1, and what it costs

The enclave signs with a secp256k1 key because Oyster gives each enclave one at boot. So the oracle uses Solana's secp256k1 precompile rather than the native ed25519 one.

**Pro.** Solana verifies the signature in a built-in instruction, and the key type is platform-neutral, so changing the TEE never changes the on-chain check.

**Con.** Every transaction carries an extra instruction and the bytes that go with it.

There is also a classic bug class here. The program never verifies the signature itself. The precompile does, one instruction earlier, and the program reads back what the precompile was given. The instruction-index fields in the precompile instruction must point at the precompile itself, or an attacker can make the check pass against other data. I test that case explicitly. If you copy this pattern, test it too. The five checks, and the attack each one stops, are in [Don't pass the signed bytes twice](/posts/dont-pass-the-signed-bytes-twice/).

How the attested key is tied to this exact code (G3 and G4) is covered in [Seven checks: verifying an AWS Nitro attestation in the browser](/posts/seven-checks-nitro-attestation/).

### What this doesn't cover

The registry is still the weak link, G5 from part 1. An admin registers the enclave key, and in the demo that same wallet is also the program upgrade authority. The PDA design protects borrowers from each other. It doesn't protect anyone from a stolen admin key. That, and what I'd change, is in [part 3](/posts/the-crypto-held-the-restarts-didnt/).

## Where to look yourself

- [`docs/ARCHITECTURE.md`](https://github.com/pandaa880/tee-income-oracle/blob/main/docs/ARCHITECTURE.md): the full sequence, the on-chain layout and the threat table, hop by hop
- [`docs/FORMATS.md`](https://github.com/pandaa880/tee-income-oracle/blob/main/docs/FORMATS.md): the 83-byte payload and the signed message, byte by byte
- The [verify page](https://tee-income-oracle-web.vercel.app/verify) runs the verifier in your browser and reads Solana directly. As of 23 November 2026 it is up, on a paid enclave that runs to about 8 December. After that the hosted pages may go offline. The repo, the docs and the verifier stay.

**Previous:** [part 1](/posts/trust-model-of-an-income-oracle/), the trust model. **Next:** [part 3](/posts/the-crypto-held-the-restarts-didnt/) looks at what breaks first.
