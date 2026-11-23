---
title: "A bank statement goes in, a risk tier comes out: designing a verifiable income oracle on Solana"
description: "How TEE Income Oracle scores a bank statement in an enclave nobody can read and leaves a receipt anyone can check. Each design choice with what it buys and what it costs, where it breaks first, and a plain list of who you still have to trust."
pubDatetime: 2026-11-23T12:00:00+05:30
tags:
  - solana
  - aws-nitro
  - architecture
  - attestation
  - security
draft: false
---

> **TL;DR:** TIO scores a bank statement inside an AWS Nitro enclave, so no one, including me, reads it. It signs a risk tier, and a Solana program stores it. Anyone can check which code ran. The system is only as honest as four things you still trust: AWS Nitro and the enclave code, the Account Aggregator, one admin key, and a sandbox bank. This post lists each design choice with its cost, and where it breaks first.

A lender in India can read a borrower's bank statement with the borrower's consent, through the Account Aggregator (AA) system. The lender scores it and decides. The funder behind that lender sees none of this. They get a loan book and a promise that the income check ran honestly.

I built [TEE Income Oracle](https://github.com/pandaa880/tee-income-oracle) (TIO) to test one idea: can the income check run somewhere nobody can read the statement, and still leave a receipt anyone can verify?

This post explains how it works and why each design choice is there. For every choice I list what it buys and what it costs. The limits are at the end, and they matter as much as the design.

Scope: this is an MVP on Solana devnet, running against a **sandbox bank** I wrote, not a live bank. Every claim below is about that setup unless I say otherwise.

## The question that shapes everything

The enclave that does the scoring runs on a machine I operate. So the first design question is: **how does a host that carries every byte still fail to read or forge them?**

Every decision in TIO answers that with one of two moves:

1. A key is **created inside the enclave** and never leaves it.
2. A key is **compiled into the measured image**, so the host can't swap it.

If a design choice needs a third move, it is a trust assumption, and I list it as one.

## The mental model

A bank statement goes into a sealed box. Only a risk tier comes out. Anyone can check that the box ran the published code.

That sentence makes three separate claims, and each one rests on something different:

| Claim                                                     | What makes it true                                                                                                           | What it doesn't cover                                                                    |
| --------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| **Provenance:** the data came from the bank               | The AA's signature on the fetch response and on the consent, checked inside the enclave against keys compiled into the image | Accounts the borrower chose not to link. A dishonest AA, which is part of the trust base |
| **Blind computation:** nobody, including me, saw the data | The decryption key and the request-signing key are created inside the enclave                                                | AWS hardware and Marlin's base image are trusted                                         |
| **Verifiable output:** the tier came from this code       | Nitro remote attestation binds the enclave's signing key to the image of this repo's build; Solana stores the signed result  | In the MVP, an admin registers the attested key on chain after checking it off-chain     |

Here is who is trusted. Everything outside the enclave is treated as hostile, including my own gateway.

| Zone                | Pieces                                                                                                   |
| ------------------- | -------------------------------------------------------------------------------------------------------- |
| **Untrusted**       | The web app, the gateway (orchestrator and relayer), the Oyster host (a network proxy), and the verifier |
| **External**        | The sandbox bank (a mock bank and AA)                                                                    |
| **Trusted**         | The Nitro enclave and its scoring core, written in Rust                                                  |
| **Public (Solana)** | The oracle program, the attestation service (SAS), and a demo lending pool                               |

Data flows like this. The web app talks to the gateway. The gateway passes ciphertext and signed bytes through the host to the enclave, and talks to the bank directly. It submits the enclave's signed result to the oracle program, which creates an attestation in SAS. The pool reads that attestation. The verifier checks the enclave's attestation document against the oracle's registry.

The enclave is the only trusted piece, so it is small, public and attested. The gateway can delay, drop or censor a request. It cannot read the data or forge a tier.

## The chain of six guarantees

The security argument is a chain. A weak link anywhere breaks the claim, so I name the weak one up front.

| Link | Guarantee                            | Mechanism                                                                                                           |
| ---- | ------------------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| G1   | Input is genuine                     | The enclave verifies the AA signature with pinned keys before it parses anything                                    |
| G2   | Only the enclave can decrypt         | The session key and the request-signing key are generated inside it                                                 |
| G3   | The code is the published code       | The image id is a measurement of the pinned docker-compose and images, reproducible from the repo                   |
| G4   | The signing key belongs to that code | The Nitro attestation document carries the enclave's public key                                                     |
| G5   | The chain accepts only that key      | An on-chain registry maps image id to attester key. **This is the weak link: in the MVP an admin sets it**          |
| G6   | Consumers check what they read       | The pool checks signer, schema, freshness, that the enclave build is approved and still active, and the policy hash |

G5 is the honest gap. Someone with the admin key could register a fake enclave. Anyone can re-run the verifier and spot it, because registry changes are public events, but that is detection, not prevention.

## One session, end to end

Here is the happy path, trimmed to the steps that matter. The full sequence is in the repo's architecture doc.

1. The borrower starts a session with the gateway, giving a wallet and a persona.
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

The gateway touches every message and can still do very little. This table is the part of the design I'm proudest of:

| Hop            | The gateway/host sees                      | It can           | It cannot                                                                                                        |
| -------------- | ------------------------------------------ | ---------------- | ---------------------------------------------------------------------------------------------------------------- |
| Session create | Public key material and the signed request | Read public keys | Change the key (the signature covers it) or swap the enclave's request key (the bank checks a binding signature) |
| Bind wallet    | The intent and the wallet signature        | Drop it          | Bind a wallet it doesn't control                                                                                 |
| Fetch          | Ciphertext and signed envelopes            | Store it         | Decrypt it or alter it (the AES-GCM tag and signatures break)                                                    |
| Evaluate       | Raw bytes in, signed payload out           | Replay old bytes | Get them accepted (one-time session nonce)                                                                       |
| Submit         | The Solana transaction                     | Censor it        | Change the tier (the signature breaks)                                                                           |
| Borrow         | Nothing relevant                           | Nothing          | Use another wallet's attestation, a stale one, or one from a build the pool hasn't approved                      |

The enclave talks plain HTTP to the gateway. That sounds wrong, and it's fine for a specific reason: every byte that matters is signed or encrypted end to end. The enclave produces signed requests and consumes signed responses. Whoever carries them doesn't matter.

## The decisions, with pros and cons

This is the section I wish more architecture posts had. For each choice: what it bought, what it cost, and what I would change.

### TEE vs zero-knowledge proofs vs a signed API

**Why a TEE.** The statement has to be decrypted and scored somewhere. A TEE lets that happen on code anyone can inspect, in a box the operator can't open. The scoring core is small and public.

**What it costs.** The trust root is AWS Nitro plus the enclave code, plus Marlin's base image in this deployment. Attestation proves _which_ code ran. It does not prove the code is correct. A bug in the scorer is attested like everything else.

**The alternatives.** A plain signed API is simpler and cheaper, but then the operator reads the data and you are back to "trust the operator". A ZK proof of the scoring would remove the hardware trust, but proving statement parsing and scoring in zero knowledge is a much heavier project than an MVP can carry. I'd move toward ZK-verified attestation later, after a multisig stage.

### Marlin Oyster vs self-hosted Nitro

**Why Oyster.** It was the fastest route to a public attestation path with a deploy flow I could script.

**What it costs.** A single enclave instance processes sessions one at a time. Its signing key changes on restart, so a restart means re-registering on chain, and after a restart outstanding tiers stop working for new borrows. High availability is not supported. Self-hosted Nitro with a key released by AWS KMS only to a matching measurement is the likely production path.

The design keeps that swap at the edges. The scoring core, the enclave API, the on-chain programs, the payload and the signed message all stay. Only packaging, networking and the key source change. A swap is a new registry entry, run side by side with the old one, and the old one is revoked. Nothing already on chain is rewritten.

### Keys born inside the enclave, new on every boot

**Pro.** The host can't extract them. Each session also uses its own key, wiped afterward, so one leak exposes one session.

**Con.** The request-signing key is new on every boot. My sandbox bank trusts it by reading the on-chain registry. A real AA onboards an institution's public key out of band, so going live needs a stable key (for example, sealed by KMS to the measurement) or a re-onboarding flow.

### A secp256k1 attester and an on-chain precompile check

**Pro.** Solana can verify a secp256k1 signature cheaply through its precompile, and the key type is platform-neutral, so changing the TEE never changes the on-chain check.

**Con.** The precompile has a classic bug class: the instruction-index fields in the precompile instruction must point at the precompile itself, or an attacker can make the check pass against other data. I test that case explicitly. If you copy this pattern, test it too. I wrote up the five checks in [Don't pass the signed bytes twice](/posts/dont-pass-the-signed-bytes-twice/).

### Standard attestations (SAS) vs a custom program

**Pro.** A tier written as a standard credential is readable by any pool. The pool pins the credential and schema, and requires the stored signer to be the oracle's own derived address, so a foreign credential can't pass. Nothing personal goes on chain, only a tier, ids, hashes and timestamps.

**Con.** I depend on someone else's program, and the rent for an attestation (about 0.002 SOL) stays locked until the same wallet refreshes. I haven't built a close path for expired attestations yet.

### The admin-registered enclave key (G5)

**Pro.** It's simple, every change is a public event, and a compromised key is replaceable.

**Con.** It is one key. In the demo, that same wallet is also the program upgrade authority, so it could replace the oracle's checks outright. Beyond the demo this needs separate keys, a multisig with a timelock, and eventually an immutable program.

### Verify before parse

**Pro.** The enclave checks signatures with pinned keys before it parses anything, so hostile bytes never reach the parser.

**Con.** The keys are compiled into the image. Rotating one means shipping a new build. I accept that. It is the point of move 2 above.

### One score per account, scored by fixed rules

**Pro.** The rules are simple and auditable. Thresholds are policy, pinned by a policy hash the pool checks. The classification rules are code, pinned by the image id.

**Con.** One session scores one account, chosen by the borrower. Obligations paid from another account are not seen. Every non-bounce credit counts as income, including self-transfers and loan proceeds. EMIs without recognizable narration are missed. Rounding is slightly lender-unsafe at tier boundaries, so a file at the limit can land one tier better than exact arithmetic gives. Thresholds are not calibrated on repayment data.

## Where it breaks first

The cryptographic chain is the strongest part, apart from G5. The system breaks earlier, in operations and in input quality. In the order I expect to hit them:

1. **A restart.** The enclave's signing key is new on every boot. Until someone re-registers it on chain, tiers from before the restart stop working for new borrows. Recovery waits on a person, so the outage lasts as long as that person takes to reply. This is a hidden single point of failure: the manual step.
2. **Load.** One enclave handles one session at a time, with no second instance. Any real traffic queues, and a crash stops everything.
3. **Going live with a real AA.** A real AA onboards an institution's key once, out of band. Mine changes on every boot, so it fails on the first day. A key sealed by KMS to the measurement fixes this and the restart problem together, which is why it is first on my list.
4. **Inputs the borrower controls.** The borrower picks the account, and self-transfers and loan proceeds count as income. A person can make money look like income by moving it around. The enclave scores the file faithfully, and the file is the weak part.
5. **Thresholds with no feedback.** No repayment data has ever flowed back to the tier rules, so I can say a tier is attested, not that it predicts repayment.
6. **The admin key.** This is G5 again. It breaks the trust claim outright, and I rank it later only because it needs a stolen key, not a normal day.

The pattern: attestation tells you the right code ran on the data it was given. It does not tell you the data was good or the rules were right. Verified is not the same as correct.

## What this does not give you

I'd rather you read this section than discover it.

- **It is not trustless.** You trust AWS Nitro and the published enclave code, and in this deployment Marlin's base image.
- **The admin step is off-chain.** The attested key is registered after a human checks it. On-chain verification of the enclave is future work.
- **No bank signature reaches the lender in real AA.** This is the claim I had to walk back. In my sandbox, the bank signs the statement data, which is an extension I added. The AA specification does not give the lender a bank signature: each hop signs its own HTTP body, and the statement schema has no signature element (I checked this on 2026-10-05 against the published specs). So for real data the provenance claim is only: _a licensed AA states that this bank returned this statement._ The AA joins the trust base. Whether a given AA forwards a bank signature outside the spec, I haven't confirmed.
- **No sybil resistance.** One person with several wallets can get several tiers. This is documented and not claimed solved.
- **No high availability.** One enclave, one session at a time, a new key per restart.
- **Not a live AA connection.** Going live needs a stable request key and a regulated institution of record.
- **Not underwriting.** The tier measures ability to pay from bank cash flow. It does not measure intent to pay or identity.

## What I'd build next

In rough order: self-hosted Nitro with a KMS-released key, a multisig with a timelock for the admin and upgrade keys, a stable request key or re-onboarding flow for a real AA, and ZK-verified attestation to replace the off-chain registration step.

## The lesson

When your system's operator is the adversary, list the trust assumptions as a table before you write the pitch. Mine are: AWS and the enclave code, the AA, one admin key, and a sandbox bank. Each has a row, a mitigation and a planned fix. That table does more for a reader's confidence than any claim that the system is secure.

The architecture doc is in the repo, and the verifier lets you check an attestation yourself:

- Repo: [tee-income-oracle](https://github.com/pandaa880/tee-income-oracle)
- [`docs/ARCHITECTURE.md`](https://github.com/pandaa880/tee-income-oracle/blob/main/docs/ARCHITECTURE.md): the full security argument and threat model
- [`docs/VERIFY.md`](https://github.com/pandaa880/tee-income-oracle/blob/main/docs/VERIFY.md): how to run the verifier
- The [verify page](https://tee-income-oracle-web.vercel.app/verify) runs the verifier in your browser
