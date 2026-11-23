---
title: "A bank statement goes in, a risk tier comes out: the trust model of an income oracle on Solana"
description: "How TEE Income Oracle scores a bank statement in an enclave nobody can read and leaves a receipt anyone can check. The three claims it makes, the chain of six guarantees, and a plain list of who you still have to trust."
pubDatetime: 2026-11-26T17:00:00+05:30
tags:
  - solana
  - aws-nitro
  - architecture
  - attestation
  - security
draft: true
---

> **TL;DR:** TIO scores a bank statement inside an AWS Nitro enclave, so no one, including me, reads it. It signs a risk tier, and a Solana program stores it. Anyone can check which code ran. The system is only as honest as four things you still trust: AWS Nitro and the enclave code, the Account Aggregator, one admin key, and a sandbox bank. This post lays out the trust model and its limits. The next two posts follow one session from the borrower to the Solana pool, and then look at what breaks first.

**This is part 1 of 3 on how TEE Income Oracle works.**

1. **[A bank statement goes in, a risk tier comes out: the trust model of an income oracle on Solana](/posts/trust-model-of-an-income-oracle/)**
2. [My own server carries every byte and still can't read or forge one: from borrower to Solana pool in six hops](/posts/six-hops-through-an-enclave/)
3. [The crypto held, the restarts didn't: what breaks first in an enclave oracle](/posts/the-crypto-held-the-restarts-didnt/)

A lender in India can read a borrower's bank statement with the borrower's consent, through the Account Aggregator (AA) system. The lender scores it and decides. The funder behind that lender sees none of this. They get a loan book and a promise that the income check ran honestly.

I built [TEE Income Oracle](https://github.com/pandaa880/tee-income-oracle) (TIO) to test one idea: can the income check run somewhere nobody can read the statement, and still leave a receipt anyone can verify?

The "somewhere" is an enclave: a locked-down virtual machine on an AWS server (AWS Nitro). Not even the machine's owner can read its memory, and it can produce a signed document that says which code it is running. I run mine on Marlin Oyster, a service that deploys and attests enclaves for you.

Scope: this is an MVP on Solana devnet, running against a **sandbox bank** I wrote, not a live bank. Every claim in this series is about that setup unless I say otherwise.

## The question that shapes everything

The enclave that does the scoring runs on a machine I operate. So the first design question is: **how does a host that carries every byte still fail to read or forge them?**

Every decision in TIO answers that with one of two moves:

1. A key is **created inside the enclave** and never leaves it.
2. A key is **compiled into the measured image**, so the host can't swap it.

If a design choice needs a third move, it is a trust assumption, and I list it as one.

## The mental model

A bank statement goes into a sealed box. Only a risk tier comes out. Anyone can check that the box ran the published code.

That sentence makes three separate claims, and each one rests on something different:

| Claim                                                            | What makes it true                                                                                                           | What it doesn't cover                                                                    |
| ---------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| **Provenance:** a licensed AA states the data came from the bank | The AA's signature on the fetch response and on the consent, checked inside the enclave against keys compiled into the image | Accounts the borrower chose not to link. A dishonest AA, which is part of the trust base |
| **Blind computation:** nobody, including me, saw the data        | The decryption key and the request-signing key are created inside the enclave                                                | AWS hardware and Marlin's base image are trusted                                         |
| **Verifiable output:** the tier came from this code              | Nitro remote attestation binds the enclave's signing key to the image of this repo's build; Solana stores the signed result  | In the MVP, an admin registers the attested key on chain after checking it off-chain     |

Here is who is trusted. Everything outside the enclave is treated as hostile, including my own gateway.

<svg class="tz" viewBox="0 0 440 420" role="img" aria-labelledby="tz-title tz-desc" xmlns="http://www.w3.org/2000/svg">
  <title id="tz-title">Trust zones of TEE Income Oracle</title>
  <desc id="tz-desc">Four zones. Untrusted: web app, gateway, Oyster host and verifier. Trusted: the Nitro enclave. External: the sandbox bank. Public on Solana: the oracle program with its enclave registry, the attestation service, and a demo lending pool. The web app talks to the gateway. The gateway sends encrypted and signed bytes through the host to the enclave, sends requests to the bank, and sends the signed result to the oracle program. The oracle writes the attestation to the attestation service, and the pool reads it. The verifier checks the enclave's attestation document against the oracle's registry.</desc>
  <style>
    svg.tz { display: block; width: 100%; height: auto; max-width: 440px; margin-inline: auto; font-family: inherit; }
    svg.tz .zone { fill: var(--muted); fill-opacity: 0.35; stroke: var(--foreground); stroke-opacity: 0.45; stroke-width: 1; }
    svg.tz .zone-trusted { fill: var(--accent); fill-opacity: 0.12; stroke: var(--accent); stroke-opacity: 1; stroke-width: 2.5; }
    svg.tz .box { fill: var(--background); stroke: var(--foreground); stroke-width: 1.25; }
    svg.tz .box-trusted { stroke: var(--accent); stroke-width: 2.5; }
    svg.tz .zone-label { fill: var(--foreground); font-size: 12px; font-weight: 700; letter-spacing: 0.06em; }
    svg.tz .zone-label-trusted { fill: var(--accent); }
    svg.tz .t { fill: var(--foreground); font-size: 14px; text-anchor: middle; }
    svg.tz .t-sub { font-size: 12px; }
    svg.tz .edge { fill: none; stroke: var(--foreground); stroke-width: 1.5; marker-end: url(#tz-arrow); }
    svg.tz .edge-label { fill: var(--foreground); font-size: 12px; }
    svg.tz .arrow-head { fill: var(--foreground); }
  </style>
  <defs>
    <marker id="tz-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path class="arrow-head" d="M0 0 L10 5 L0 10 z" />
    </marker>
  </defs>
  <rect class="zone" x="6" y="8" width="428" height="176" rx="8" />
  <text class="zone-label" x="16" y="28">UNTRUSTED</text>
  <rect class="zone" x="6" y="204" width="128" height="86" rx="8" />
  <text class="zone-label" x="16" y="222">EXTERNAL</text>
  <rect class="zone zone-trusted" x="150" y="204" width="140" height="86" rx="8" />
  <text class="zone-label zone-label-trusted" x="160" y="222">TRUSTED</text>
  <rect class="zone" x="6" y="312" width="428" height="100" rx="8" />
  <text class="zone-label" x="16" y="330">PUBLIC: SOLANA</text>
  <path class="edge" d="M120 66 H170" />
  <path class="edge" d="M220 88 V124" />
  <path class="edge" d="M180 88 V106 H105 V236" />
  <path class="edge" d="M270 66 H405 V346" />
  <path class="edge" d="M220 168 V236" />
  <path class="edge" d="M360 168 V346" />
  <path class="edge" d="M120 368 H170" />
  <path class="edge" d="M320 368 H270" />
  <text class="edge-label" x="111" y="122">requests</text>
  <text class="edge-label" x="337" y="58" text-anchor="middle">result</text>
  <text class="edge-label" x="226" y="198">encrypted</text>
  <text class="edge-label" x="354" y="256" text-anchor="end">checks</text>
  <text class="edge-label" x="145" y="361" text-anchor="middle">reads</text>
  <text class="edge-label" x="295" y="361" text-anchor="middle">writes</text>
  <rect class="box" x="20" y="44" width="100" height="44" rx="6" />
  <text class="t" x="70" y="71">Web app</text>
  <rect class="box" x="170" y="44" width="100" height="44" rx="6" />
  <text class="t" x="220" y="71">Gateway</text>
  <rect class="box" x="170" y="124" width="100" height="44" rx="6" />
  <text class="t" x="220" y="151">Oyster host</text>
  <rect class="box" x="320" y="124" width="80" height="44" rx="6" />
  <text class="t" x="360" y="151">Verifier</text>
  <rect class="box" x="20" y="236" width="100" height="44" rx="6" />
  <text class="t" x="70" y="255">Sandbox</text>
  <text class="t t-sub" x="70" y="271">bank + AA</text>
  <rect class="box box-trusted" x="170" y="236" width="100" height="44" rx="6" />
  <text class="t" x="220" y="255">Enclave</text>
  <text class="t t-sub" x="220" y="271">Rust core</text>
  <rect class="box" x="20" y="346" width="100" height="44" rx="6" />
  <text class="t" x="70" y="373">Demo pool</text>
  <rect class="box" x="170" y="346" width="100" height="44" rx="6" />
  <text class="t" x="220" y="373">SAS</text>
  <rect class="box" x="320" y="346" width="100" height="44" rx="6" />
  <text class="t" x="370" y="365">Oracle</text>
  <text class="t t-sub" x="370" y="381">+ registry</text>
</svg>

| Zone                | Pieces                                                                                                                            |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| **Untrusted**       | The web app, the gateway (orchestrator and relayer), the Oyster host (a network proxy), and the verifier                          |
| **External**        | The sandbox bank (a mock bank and AA)                                                                                             |
| **Trusted**         | The Nitro enclave and its scoring core, written in Rust                                                                           |
| **Public (Solana)** | The oracle program, the Solana Attestation Service (SAS), a standard way to store signed claims on chain, and a demo lending pool |

Data flows like this. The web app talks to the gateway. The gateway passes ciphertext and signed bytes through the host to the enclave, and talks to the bank directly. It submits the enclave's signed result to the oracle program, which creates an attestation in SAS. The pool reads that attestation. The verifier checks the enclave's attestation document against the oracle's registry.

The enclave is the only trusted piece, so it is small, public and attested. The gateway can delay, drop or censor a request. It cannot read the data or forge a tier.

## The chain of six guarantees

The security argument is a chain. A weak link anywhere breaks the claim, so I name the weak one up front.

| Link | Guarantee                            | Mechanism                                                                                                                                                        |
| ---- | ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| G1   | Input is genuine                     | The enclave verifies the AA signature with pinned keys before it parses anything                                                                                 |
| G2   | Only the enclave can decrypt         | The session key and the request-signing key are generated inside it                                                                                              |
| G3   | The code is the published code       | The image id, a fingerprint of the exact docker-compose file and images the enclave runs, is recomputed by the verifier from the compose file at the release tag |
| G4   | The signing key belongs to that code | The Nitro attestation document carries the enclave's public key                                                                                                  |
| G5   | The chain accepts only that key      | An on-chain registry maps image id to attester key. **This is the weak link: in the MVP an admin sets it**                                                       |
| G6   | Consumers check what they read       | The pool checks signer, schema, freshness, that the enclave build is approved and still active, and the policy hash (a fingerprint of the scoring thresholds)    |

G5 is the honest gap. Someone with the admin key could register a fake enclave. Anyone can re-run the verifier and spot it, because registry changes are public events, but that is detection, not prevention.

## What this does not give you

I'd rather you read this list than discover it.

- **It is not trustless.** You trust AWS Nitro and the published enclave code, and in this deployment Marlin's base image.
- **The admin step is off-chain.** The attested key is registered after a human checks it. On-chain verification of the enclave is future work.
- **No bank signature reaches the lender in real AA.** This is the claim I had to walk back. In my sandbox, the bank signs the statement data, which is an extension I added. The AA specification does not give the lender a bank signature: each hop signs its own HTTP body, and the statement schema has no signature element (I checked this on 2026-10-05 against ReBIT's AA specification 2.1.0, FIP specification 2.2.0 and the `deposit_v2.0.0.xsd` schema). So for real data the provenance claim is only: _a licensed AA states that this bank returned this statement._ The AA joins the trust base. Whether a given AA forwards a bank signature outside the spec, I haven't confirmed.
- **No sybil resistance.** One person with several wallets can get several tiers. This is documented and not claimed solved.
- **Not a live AA connection.** The bank here is a sandbox I wrote, not a regulated institution of record. What going live would take is in [part 3](/posts/the-crypto-held-the-restarts-didnt/).
- **No numbers yet.** I haven't measured session latency, the full cost of one attestation (rent plus fee) or the monthly cost of running the enclave, so this series doesn't quote any.
- **Not underwriting.** The tier measures ability to pay from bank cash flow. It does not measure intent to pay or identity.

## Where to look yourself

The architecture doc is in the repo, and the verifier lets you check an attestation yourself:

- Repo: [tee-income-oracle](https://github.com/pandaa880/tee-income-oracle)
- [`docs/ARCHITECTURE.md`](https://github.com/pandaa880/tee-income-oracle/blob/main/docs/ARCHITECTURE.md): the full security argument and threat model
- [`docs/VERIFY.md`](https://github.com/pandaa880/tee-income-oracle/blob/main/docs/VERIFY.md): how to run the verifier
- The [verify page](https://tee-income-oracle-web.vercel.app/verify) runs the verifier in your browser. As of 23 November 2026 it is up, on a paid enclave that runs to about 8 December. After that the hosted pages may go offline. The repo, the docs and the verifier stay.

**Next:** [part 2](/posts/six-hops-through-an-enclave/) follows one session from the borrower to the Solana pool in six hops, and shows what my own gateway can and can't do at each one.
