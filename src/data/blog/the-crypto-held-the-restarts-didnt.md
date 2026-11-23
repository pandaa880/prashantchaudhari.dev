---
title: "The crypto held, the restarts didn't: what breaks first in an enclave oracle"
description: "The design choices behind TEE Income Oracle with what each bought and cost, then where it breaks first: a restart that needs a person, one instance with no failover, inputs the borrower controls, and thresholds with no feedback."
pubDatetime: 2026-12-07T17:00:00+05:30
tags:
  - solana
  - aws-nitro
  - architecture
  - reliability
  - security
draft: true
---

> **TL;DR:** The signature chain in TEE Income Oracle held up. What broke was operations: the enclave died twice, and getting it back needs a person, me. Past that, the weak spots are one instance with no failover, a borrower who picks the account being scored, and tier thresholds that have never seen repayment data. This post lists the design choices with their costs, ranks where it breaks first, and says what I'd build next.

**This is part 4 of 4 on how TEE Income Oracle works.**

1. [A bank statement goes in, a risk tier comes out: the trust model of an income oracle on Solana](/posts/trust-model-of-an-income-oracle/)
2. [My own server carries every byte and still can't read or forge one: six hops through an enclave](/posts/six-hops-through-an-enclave/)
3. [A PDA is the permission check: how a Solana pool refuses someone else's income tier](/posts/a-pda-is-the-permission-check/)
4. **[The crypto held, the restarts didn't: what breaks first in an enclave oracle](/posts/the-crypto-held-the-restarts-didnt/)**

[Part 1](/posts/trust-model-of-an-income-oracle/) set out the trust model, [part 2](/posts/six-hops-through-an-enclave/) followed a session through six hops, and [part 3](/posts/a-pda-is-the-permission-check/) covered the on-chain side. This last part is about the choices I made along the way and where the system gives out. The scope is the same: an MVP on Solana devnet, against a sandbox bank I wrote.

## The decisions, with pros and cons

For each choice: what it bought, what it cost, and what I would change.

### TEE vs zero-knowledge proofs vs a signed API

**Why a TEE.** The statement has to be decrypted and scored somewhere. A TEE lets that happen on code anyone can inspect, in a box the operator can't open. The scoring core is small and public.

**What it costs.** The trust root is AWS Nitro plus the enclave code, plus Marlin's base image in this deployment. Attestation proves _which_ code ran. It does not prove the code is correct. A bug in the scorer is attested like everything else.

**The alternatives.** A plain signed API is simpler and cheaper, but then the operator reads the data and you are back to "trust the operator". A ZK proof of the scoring would remove the hardware trust. My view is that proving statement parsing and scoring in zero knowledge is a much heavier project than an MVP can carry, but I haven't built or measured it. I'd move toward ZK-verified attestation later, after a multisig stage.

### Marlin Oyster vs self-hosted Nitro

**Why Oyster.** It was the fastest route to a public attestation path with a deploy flow I could script.

**What it costs.** I run one instance, and its signing key changes on every restart. There is no failover. The sections below show what that does. Self-hosted Nitro, with a key that AWS KMS releases only to a matching measurement, is the likely production path.

The design keeps that swap at the edges. The scoring core, the enclave API, the on-chain programs, the payload and the signed message all stay. Only packaging, networking and the key source change. A swap is a new registry entry, run side by side with the old one, and the old one is revoked. Nothing already on chain is rewritten.

### Keys born inside the enclave, new on every boot

**Pro.** The host can't extract them. Each session also uses its own key, wiped afterward, so one leak exposes one session.

**Con.** The request-signing key is new on every boot. My sandbox bank trusts it by reading the on-chain registry. A real AA onboards an institution's public key out of band, so going live needs a stable key (for example, sealed by KMS to the measurement) or a re-onboarding flow.

### The admin-registered enclave key

**Pro.** It's simple, every change is a public event, and a compromised key is replaceable.

**Con.** It is one key. In the demo, that same wallet is also the program upgrade authority, so it could replace the oracle's checks outright. Beyond the demo this needs separate keys, a multisig with a timelock, and eventually an immutable program.

### One score per account, scored by fixed rules

**Pro.** The rules are simple and auditable. Thresholds are policy, pinned by a policy hash the pool checks. The classification rules are code, pinned by the image id.

**Con.** One session scores one account, chosen by the borrower. Obligations paid from another account are not seen. Every non-bounce credit counts as income, including self-transfers and loan proceeds. EMIs without recognizable narration are missed. Rounding is slightly lender-unsafe at tier boundaries, so a file at the limit can land one tier better than exact arithmetic gives. Thresholds are not calibrated on repayment data.

## Where it breaks first

The cryptographic chain is the strongest part, apart from the admin key. The system breaks earlier, in operations and in input quality. In the order I expect to hit them:

1. **A restart.** The enclave's signing key is new on every boot. Until someone re-registers it on chain, tiers from before the restart stop working for new borrows, and each borrower has to attest again. Open loans are unaffected. Recovery waits on a person, and that person is me, so the outage lasts as long as I take to notice and act. This is a hidden single point of failure: the manual step. It has already happened. The enclave died twice and the hosted demo was down from [YOU: date] to [YOU: date].
2. **Capacity and failover.** I haven't load-tested it. The enclave bounds its work at 2 evaluations running at once, 4 evaluate requests in flight, 32 create and bind requests in flight and 256 open sessions. Throughput is the smaller worry. A borrower attests once per application, and an attestation lasts 30 days, so each borrower needs the enclave rarely. Failover is the bigger one, because there is one instance. Every restart changes the key, and each re-registration takes one of the 255 registry ids. I can't run several replicas of one build either, because the registry holds one attester key per entry.
3. **Going live with a real AA.** A real AA onboards an institution's key once, out of band. Mine changes on every boot, so it would fail on the first day. A key sealed by KMS to the measurement would fix this and the restart problem together, so it is the first thing I'd build.
4. **Inputs the borrower controls.** The borrower picks the account, and self-transfers and loan proceeds count as income. A person can make money look like income by moving it around. The enclave scores the file faithfully, and the file is the weak part.
5. **Thresholds with no feedback.** No repayment data has ever flowed back to the tier rules, so I can say a tier is attested, not that it predicts repayment.
6. **The admin key.** It breaks the trust claim outright, and I rank it last only because it needs a stolen key, not a normal day.

The pattern: attestation tells you the right code ran on the data it was given. It does not tell you the data was good or the rules were right. Verified is not the same as correct.

## What I'd build next

In rough order: self-hosted Nitro with a KMS-released key, a multisig with a timelock for the admin and upgrade keys, a stable request key or re-onboarding flow for a real AA, and ZK-verified attestation to replace the off-chain registration step.

## The lesson

When your system's operator is the adversary, list the trust assumptions as a table before you write the pitch. Mine are: AWS and the enclave code, the AA, one admin key, and a sandbox bank. Each has a row, a mitigation and a planned fix. That table does more for a reader's confidence than any claim that the system is secure.

## Where to look yourself

- Repo: [tee-income-oracle](https://github.com/pandaa880/tee-income-oracle)
- [`docs/ARCHITECTURE.md`](https://github.com/pandaa880/tee-income-oracle/blob/main/docs/ARCHITECTURE.md): the full security argument, threat model and the limits above
- [`docs/VERIFY.md`](https://github.com/pandaa880/tee-income-oracle/blob/main/docs/VERIFY.md): how to run the verifier
- The [verify page](https://tee-income-oracle-web.vercel.app/verify) runs the verifier in your browser. As of 23 November 2026 it is up, on a paid enclave that runs to about 8 December. After that the hosted pages may go offline. The repo, the docs and the verifier stay.

**Previous:** [part 3](/posts/a-pda-is-the-permission-check/), a PDA is the permission check.
