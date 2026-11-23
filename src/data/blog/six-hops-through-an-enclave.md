---
title: "My own server carries every byte and still can't read or forge one: six hops through an enclave"
description: "Follow one session through the gateway, the host, the enclave and Solana, and see what my own server sees, what it can do, and what it can't at each of six hops. Plus why plain HTTP is fine, and why the enclave's clock is not trusted."
pubDatetime: 2026-11-29T17:00:00+05:30
tags:
  - solana
  - aws-nitro
  - architecture
  - security
  - tee
draft: true
---

> **TL;DR:** In TEE Income Oracle my gateway touches every message and still can't read the statement or change the tier. Each hop is either signed, encrypted, or bound to a one-time value, so carrying the bytes gives no power over them. The one thing a carrier can do is stop them, so availability is the part this design doesn't protect. The enclave also doesn't trust its own clock.

**This is part 2 of 4 on how TEE Income Oracle works.**

1. [A bank statement goes in, a risk tier comes out: the trust model of an income oracle on Solana](/posts/trust-model-of-an-income-oracle/)
2. **[My own server carries every byte and still can't read or forge one: six hops through an enclave](/posts/six-hops-through-an-enclave/)**
3. [A PDA is the permission check: how a Solana pool refuses someone else's income tier](/posts/a-pda-is-the-permission-check/)
4. [The crypto held, the restarts didn't: what breaks first in an enclave oracle](/posts/the-crypto-held-the-restarts-didnt/)

[Part 1](/posts/trust-model-of-an-income-oracle/) set up the trust model: an enclave scores a bank statement, and everything outside it, including my own gateway, is treated as hostile. This post walks one session through to show what that means in practice. The scope is the same: Solana devnet and a sandbox bank I wrote.

If you want the other end of this, the browser page that refuses to show a tier until Solana agrees, read [The browser doesn't trust the server](/posts/the-browser-doesnt-trust-the-server/). It is the same idea from the frontend side.

## One session, end to end

Here is the happy path, trimmed to the steps that matter. The full sequence is in the repo's architecture doc.

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

Notice who does what. The gateway (my server) is in the middle of nearly every step. The enclave is in steps 3, 4, 8 and 9. The bank and Solana each appear once or twice. The gateway never holds a key that matters.

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
- **Borrow** is the pool's job, and it is the subject of [part 3](/posts/a-pda-is-the-permission-check/).

One more rule sits under all of this: verify before parse. The enclave checks signatures with pinned keys before it parses anything, so hostile bytes never reach the parser. The keys are compiled into the image. That is the cost: rotating one means shipping a new build. I accept it, because it is the point of the second move in [part 1](/posts/trust-model-of-an-income-oracle/): a key compiled into the measured image can't be swapped by the host.

## Why plain HTTP is fine

The enclave talks plain HTTP to the gateway. That sounds wrong, and it's fine for a specific reason: every byte that matters is signed or encrypted end to end. The enclave produces signed requests and consumes signed responses. Whoever carries them can't change them.

That covers integrity. It does not cover availability. The enclave's port is public, so anyone who can get consents can fill its 256 open-session slots and lock other borrowers out. The gateway rate-limits session creation, and I accept this as a liveness risk. The host and gateway can already deny service anyway, so availability was never something this design could promise. The last column of the table says "censor it" for a reason.

## The enclave's clock is not trusted

There is one more thing a carrier controls: time. The host runs the enclave's clock, so the enclave can't be asked what day it is.

So the scoring window doesn't come from the clock. It comes from the statement's own dates, which must sit inside the range the enclave requested and inside the signed consent. Freshness is checked on chain, against the Solana clock. The check allows five minutes of skew, and a signature is usable for ten minutes after it is issued.

The cost is that the limits are fixed. A submission that arrives after the ten-minute window is rejected.

## Where to look yourself

- [`docs/ARCHITECTURE.md`](https://github.com/pandaa880/tee-income-oracle/blob/main/docs/ARCHITECTURE.md): the full sequence and the threat table, hop by hop
- The [verify page](https://tee-income-oracle-web.vercel.app/verify) runs the verifier in your browser. As of 23 November 2026 it is up, on a paid enclave that runs to about 8 December. After that the hosted pages may go offline. The repo, the docs and the verifier stay.

**Previous:** [part 1](/posts/trust-model-of-an-income-oracle/), the trust model. **Next:** [part 3](/posts/a-pda-is-the-permission-check/) covers what the pool checks on chain, and why a PDA is the permission check.
