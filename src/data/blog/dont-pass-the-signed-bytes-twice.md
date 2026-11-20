---
title: "Don't pass the signed bytes twice: verifying an enclave's signature in a Solana program"
description: "The Solana program never verifies the enclave's signature; a precompile does, one instruction earlier. Five checks that make sure the program reads the bytes that were actually verified, and the attack each one stops."
pubDatetime: 2026-11-20T16:00:00+05:30
tags:
  - solana
  - rust
  - anchor
  - cryptography
  - security
draft: false
---

> **TL;DR:** On Solana, a program can let a built-in verifier check a signature in the instruction just before its own, then read what that verifier was given. If the program reads the wrong bytes, a forged approval gets through: that's how an attacker minted over $320 million of unbacked tokens from the Wormhole bridge in 2022. This post covers the five checks the TEE Income Oracle program makes so it reads only the bytes that were actually verified, and the attack each one stops.

[TEE Income Oracle](https://github.com/pandaa880/tee-income-oracle) reads a borrower's bank statement inside an AWS Nitro enclave and signs a credit tier for their wallet. A Solana program then writes that tier to the [Solana Attestation Service](https://github.com/solana-foundation/solana-attestation-service) (SAS), where a lending pool reads it before it lends.

The program has one job: write the tier only if the enclave really signed it. Here is the odd part. The program never verifies that signature. Solana does, in a separate instruction just before it. The program only reads what that instruction was given, and trusts it because the transaction would have failed otherwise.

That hand-off is where it can go wrong. This post covers the five checks I ended up with, and the attack each one stops. It assumes you've written an Anchor program and know what PDAs and CPIs are.

## How a Solana program checks a signature it never sees

The enclave's key is secp256k1: the enclave platform I run on ([Marlin Oyster](https://www.marlin.org/oyster)) gives each enclave one when it boots. Solana has a built-in verifier for secp256k1 signatures, a **precompile**. It runs as native code inside the runtime, not inside the program, and only as its own instruction in the transaction: a program [can't call it through a CPI](https://github.com/anza-xyz/agave/blob/v4.4.1/program-runtime/src/cpi.rs#L234-L236). So the transaction carries these two instructions, one right after the other (the real one also starts with a compute-budget instruction):

| #   | Instruction          | What it does                                                                    |
| --- | -------------------- | ------------------------------------------------------------------------------- |
| 0   | secp256k1 precompile | Checks that a signature over some bytes recovers to some Ethereum-style address |
| 1   | `submit_attestation` | The program                                                                     |

If the signature is wrong, the whole transaction fails, so the program's instruction never runs. The program can't see the check happen. It can only look back at instruction 0 through the **instructions sysvar**, a special account the runtime fills in for each transaction: its top-level instructions, plus the index of the one now running. From there it reads what the precompile was given.

So the real question isn't "is the signature valid?" Solana answers that. The question is: **is the thing the precompile verified the same thing the program is about to write?**

## Why not verify inside the program?

You can. Solana has a `secp256k1_recover` syscall: hash the message, recover the public key, turn it into an address, compare. One instruction, no hand-off. It costs [25,000 compute units](https://github.com/anza-xyz/agave/blob/v4.4.1/program-runtime/src/execution_budget.rs#L224) on its own, though. On devnet, a whole transaction that creates a tier costs 22,143 compute units at the median: 19,143 to 34,143 across the 21 transactions since the last program upgrade. The spread comes from deriving the attestation's address, which takes more tries for some wallets. (Half of that spread is SAS deriving the same address again when it creates the account, so taking the bump from the caller would save at most the other half.) So the syscall alone would cost more than a typical create. It also leaves the keccak hashing and the address derivation to me.

The precompile does the cryptography in native code that the runtime maintains, so I took it. It isn't free: each signature it verifies is [charged like a transaction signature](https://github.com/anza-xyz/agave/blob/v4.4.1/fee/src/lib.rs#L42-L56), 5,000 lamports. But it doesn't draw from the transaction's compute budget. The price is the hand-off: the program has to prove that what the precompile verified is what it's about to write. Checks 2 to 4 below are that price.

## Check 1: pass the signed bytes once

A common shape for this is to pass the message as an instruction argument, then compare it with the precompile's data. That's two copies of the same bytes, and the comparison is code that can be wrong: one field compared, one forgotten, a length off by one.

`submit_attestation` takes no arguments at all. The enclave signs a fixed 232-byte message: a domain tag, then this program's id, the SAS credential, the schema, the borrower's wallet, the 83-byte tier payload (which carries `issued_at`, the time the enclave signed), and an expiry. The program reads every one of those from inside the precompile instruction, where they were verified. Then it checks the accounts against the message: the credential and schema accounts must be the ones it names, and the attestation account must be the SAS address derived from that credential, schema and wallet.

There is no second copy that could disagree. That's the whole idea: **read the signed bytes where they were verified, not from somewhere else.**

## Check 2: make sure it's the real instruction list

The instructions sysvar is just an account, and the caller passes it in. If the program reads whatever account it is handed, an attacker can pass a fake account that _looks_ like an instruction list with a verified signature in it.

That isn't hypothetical. In February 2022 an attacker minted about 120,000 unbacked wrapped ETH (over $320 million at the time) from the Wormhole bridge on Solana this way. Its signature check never confirmed that the account it was handed was the real instructions sysvar, so a fake one let the attacker forge a guardian message ([Wormhole's incident report](https://wormholecrypto.medium.com/wormhole-incident-report-02-02-22-ad9b8f21eec6), [Halborn's write-up](https://www.halborn.com/blog/post/explained-the-wormhole-hack-february-2022)).

Anchor validates typed sysvars like `Sysvar<'info, Clock>` for you. The instructions sysvar has no typed Anchor wrapper, so it usually arrives as an `UncheckedAccount`, and pinning its address is on you. (Wormhole's code used older, now-deprecated loader functions that didn't check it.) The fix is one constraint on the account, plus the `_checked` loaders, which check the sysvar address again:

```rust
/// CHECK: pinned to the instructions sysvar, so introspection can't read
/// a fake instruction list.
#[account(address = solana_sdk_ids::sysvar::instructions::ID)]
pub instructions: UncheckedAccount<'info>,
```

## Check 3: the precompile must point at itself

This is the one I found least obvious.

The secp256k1 precompile doesn't have to verify the bytes in its own instruction. After a one-byte signature count, its data holds an 11-byte offsets block for each signature. The block tells it _where_ to find three things: the signature, the address, and the message (with the message's size). Each comes as an offset plus an **instruction index**. Each index is a single byte, and it is absolute: instruction 0, 1, 2, and so on ([the crate's layout table](https://github.com/anza-xyz/solana-sdk/blob/secp256k1-program%40v3.1.1/secp256k1-program/src/lib.rs#L136-L147)).

The ed25519 precompile has a special value, `u16::MAX`, that means "this instruction". secp256k1 has nothing like it. So any index can point at a _different_ instruction, and the precompile will verify bytes from there.

Here is the attack that allows. Two parties read the precompile's bytes: the runtime follows the index fields, and the program reads fixed offsets. If they point at different bytes, the attacker controls the gap. The tests build exactly this transaction:

| #   | Instruction                 | Contents                                                                                                                                                                                                             |
| --- | --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0   | Decoy secp256k1 precompile  | The attacker's own message, signed with the attacker's own key. Valid.                                                                                                                                               |
| 1   | "Real" secp256k1 precompile | Its own data holds, at the usual offsets, the **enclave's** address and a **forged** message giving the attacker tier A. But all three index fields say `0`, so the precompile checks instruction 0's bytes instead. |
| 2   | `submit_attestation`        | The program                                                                                                                                                                                                          |

When the runtime checks instruction 1, it follows instruction 1's indexes to instruction 0 and verifies the attacker's signature over the attacker's message. That's valid, so instruction 1 passes. The program, reading instruction 1 at the usual offsets, sees the enclave's address and a tier-A message, and writes a tier the enclave never signed.

The fix: build the offsets block a correct precompile at this position must have, and compare all 11 bytes.

```rust
// Where each part sits in the precompile's data (one signature):
// count (1), offsets (11), address (20), signature + recovery id (65),
// message (232).
const OFFSETS_LEN: usize = 11;
const ETH_ADDRESS_OFFSET: u16 = 12;
const SIGNATURE_OFFSET: u16 = 32;
const MESSAGE_OFFSET: u16 = 97;
const MESSAGE_SIZE: u16 = 232;

/// The 11 offset bytes a well-formed precompile instruction at
/// `precompile_index` must carry: signature, address and message offsets,
/// each with its instruction index set to the precompile itself.
pub fn expected_offsets(precompile_index: u8) -> [u8; OFFSETS_LEN] {
    let mut offsets = [0u8; OFFSETS_LEN];
    // Bytes 0..3: where the signature is.
    offsets[0..2].copy_from_slice(&SIGNATURE_OFFSET.to_le_bytes());
    offsets[2] = precompile_index;
    // Bytes 3..6: where the Ethereum address is.
    offsets[3..5].copy_from_slice(&ETH_ADDRESS_OFFSET.to_le_bytes());
    offsets[5] = precompile_index;
    // Bytes 6..11: where the message is, and how long it is.
    offsets[6..8].copy_from_slice(&MESSAGE_OFFSET.to_le_bytes());
    offsets[8..10].copy_from_slice(&MESSAGE_SIZE.to_le_bytes());
    offsets[10] = precompile_index;
    offsets
}
```

The parser then accepts exactly one layout: a signature count of 1, this offsets block, and a fixed total length. Anything else is `InvalidPrecompileLayout`. Comparing the whole block, and not just the three index bytes, also pins _where_ the address and message sit, so the program reads them from the same place the precompile did.

The count matters too. A precompile instruction whose data is just `[0]` claims zero signatures, so there is nothing to verify, and [the runtime lets it pass](https://github.com/anza-xyz/agave/blob/v4.4.1/precompiles/src/secp256k1.rs#L32-L37): it only rejects a zero count when more bytes follow. A program that only checks that a secp256k1 instruction came right before it would accept that as a verified signature. Requiring the count to be exactly 1 closes it.

The crate's own documentation [recommends these checks](https://github.com/anza-xyz/solana-sdk/blob/secp256k1-program%40v3.1.1/secp256k1-program/src/lib.rs#L167-L176) ("That there are exactly the expected number of signatures", "That the three indexes … are as expected"). They're easy to skip, though, because a test with one honest precompile instruction passes either way. The test only fails once there is a decoy in the transaction, so I wrote one decoy test for each index field, plus the full forgery above.

## Check 4: one precompile, one submit

The program doesn't scan the transaction for "a secp256k1 instruction somewhere". It requires the precompile at exactly the position before the top-level instruction that's running:

```rust
/// The instruction right before this one must be the secp256k1 precompile.
/// A fixed position (not a scan) keeps one precompile from backing several
/// top-level `submit_attestation`s. Replay itself is stopped by the strictly
/// increasing `issued_at` (`close_older`), which also covers a wrapper
/// program that CPIs twice. Returns its index and data.
fn load_precompile(instructions_sysvar: &AccountInfo) -> Result<(u8, Vec<u8>)> {
    let current_position = load_current_index_checked(instructions_sysvar)?;
    let precompile_position = current_position
        .checked_sub(1)
        .ok_or(OracleError::PrecompileNotFound)?;
    let precompile =
        load_instruction_at_checked(usize::from(precompile_position), instructions_sysvar)?;
    require!(
        precompile.program_id == solana_sdk_ids::secp256k1_program::ID,
        OracleError::PrecompileNotFound
    );
    // The precompile's index fields are one byte, so a precompile beyond
    // position 255 can't point at itself.
    let precompile_index =
        u8::try_from(precompile_position).map_err(|_| OracleError::InvalidPrecompileLayout)?;
    Ok((precompile_index, precompile.data))
}
```

With a scan, one verified signature could back two `submit_attestation` instructions in the same transaction. It also checks the program id, so an impostor program can't sit in that slot.

One subtlety: if a wrapper program calls `submit_attestation` through a CPI, "the instruction that's running" is the wrapper's, because the sysvar only lists top-level instructions. So the precompile has to sit right before the wrapper. A wrapper that calls twice is covered in check 5.

## Check 5: a valid signature isn't a fresh one

After checks 1 to 4, the program knows the enclave signed these exact bytes. It doesn't know _when_, or whether it has already used them.

**Replay through refresh.** A borrower's tier can be refreshed: close the old attestation, write the new one. The first design had a hole there. An older signature that hadn't expired yet could close a _newer_ attestation and write the older tier back. Refresh is a write path, and it needs the same suspicion as create.

The rule that closes it: for each wallet, the new `issued_at` must be strictly later than the stored one. That only works if the stored attestation can't disappear, because an empty slot has nothing to compare against. Here it can't: SAS lets only the credential's authorized signer close an attestation, that signer is the program itself (more on that below), and the program only closes one inside a refresh that writes a newer tier.

```rust
/// Closes the wallet's existing attestation if there is one, after checking
/// the new one is strictly newer. Without that, a still-valid older
/// signature (or a replay of the same one) could replace a newer tier.
/// Returns whether one was closed.
fn close_older(
    accounts: &SubmitAttestation,
    new_issued_at: i64,
    signer_seeds: &[&[u8]],
) -> Result<bool> {
    let attestation = accounts.attestation.to_account_info();
    // Empty (even if someone sent lamports to it): nothing to replace, and
    // SAS creates the account over the lamports.
    if attestation.data_is_empty() {
        return Ok(false);
    }
    // The data borrow ends with this statement, before the SAS call below.
    let previous_issued_at = stored_issued_at(attestation.owner, &attestation.try_borrow_data()?)?;
    require!(
        new_issued_at > previous_issued_at,
        OracleError::StaleAttestation
    );
    let close_instruction = close_attestation_ix(&sas_accounts(accounts));
    invoke_sas(accounts, &close_instruction, signer_seeds)?;
    Ok(true)
}
```

That one rule also stops an exact replay of the same signature. By the same reasoning it should stop a wrapper program that calls `submit_attestation` twice against the same precompile, since the second call finds the attestation the first one wrote. The tests don't cover that case yet. I never use the signature bytes as an id. That matters, because Solana's secp256k1 precompile accepts both forms of a malleable signature ([Agave has a test for exactly that](https://github.com/anza-xyz/agave/blob/v4.4.1/precompiles/src/secp256k1.rs#L345)), so "have I seen this signature before?" would be a weak check.

**Clocks.** The enclave's clock comes from its host, which I don't trust. So the program checks the claimed time: `issued_at` may be at most 300 seconds ahead of Solana's clock, the enclave's signed `expiry` may be at most 600 seconds after `issued_at`, and the transaction must land before that expiry. So a signature stops working within ten minutes of the time it claims. The 30-day expiry the lending pool reads is a separate value, set by the program, not the enclave.

## The signer with no private key

All five checks would be useless if anyone could write to SAS directly. So the SAS credential has exactly one authorized signer: a [program-derived address](https://solana.com/docs/core/pda) (PDA), derived from the program's id and the seed `"sas_signer"`. A PDA lies off the ed25519 curve, so no private key exists for it. Only the program's code can sign as it, by passing the seeds along when it calls SAS (`invoke_signed`), and it does that only after these checks pass.

That doesn't make the trust disappear; it moves it to three keys. The credential's authority could add another signer. The program's upgrade authority could change the code. And the registry's admin decides which enclave keys count, so a bad registration would pass every check above. It's also why a lending program must check that a stored attestation's signer is this PDA, as the demo pool does.

Revocation has its own rule. Each enclave build gets an id from a counter that only goes up, so a revoked id is never given out again. After build 3 is revoked, a reader that checks the registry entry, as the demo pool does, rejects every tier that says "measured by build 3". The attestations themselves stay on chain.

## How I tested it

- One negative test for each of the instruction's 17 error codes, plus tests that two faults together fail on the one checked first.
- The decoy tests above, one for each index field, and unit tests for a signature count of 0 and 2.
- The integration tests run in-process in [Surfpool](https://github.com/txtx/surfpool), against the real SAS program binary dumped from devnet.
- When I first built it, I broke each security check by hand, one at a time (29 mutants), and ran the tests against each. All 29 were caught.
- The whole transaction (a compute-budget instruction, the precompile with its signature and 232-byte message, and the submit instruction with its accounts) is 882 bytes, under the 1,232-byte limit for legacy and v0 transactions.

## A checklist, if you verify signatures this way

The five checks, split into steps:

1. Read every signed value from the precompile's data. Don't take a second copy as an argument.
2. Pin the instructions sysvar's address, and use the `_checked` loaders.
3. Check the precompile's program id.
4. Require a signature count of exactly 1 (a bare `[0]` passes the runtime), and compare the whole offsets block with the one a self-pointing precompile must have. With ed25519, require `u16::MAX` or the precompile's own index.
5. Fix the precompile's position (current − 1, where current is the top-level instruction); don't scan.
6. Decide what makes a signature _fresh_ (a strictly increasing time or nonce per subject). Validity isn't enough, and the signature bytes aren't a safe id.
7. Write a test with a decoy instruction. A test without a decoy passes whether or not check 3 is there.

The code is in [`programs/oracle/src/attest.rs`](https://github.com/pandaa880/tee-income-oracle/blob/main/programs/oracle/src/attest.rs) and [`submit_attestation.rs`](https://github.com/pandaa880/tee-income-oracle/blob/main/programs/oracle/src/instructions/submit_attestation.rs). The snippets above rename a few variables for reading; the logic is the same. In [the previous post](/posts/seven-checks-nitro-attestation/) I covered the other end: checking, in the browser, that the key behind these signatures really lives in the enclave.
