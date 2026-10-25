---
title: "The browser doesn't trust the server: a Solana frontend that checks its own backend"
description: "Five places my Solana frontend checks its own backend: what the user signs, the relayer's answer, the result, a status badge, and the RPC node itself."
pubDatetime: 2026-11-01T10:00:00+05:30
tags:
  - solana
  - frontend
  - typescript
  - security
draft: true
---

I'm building [TEE Income Oracle](https://github.com/pandaa880/tee-income-oracle). A borrower's bank statement is scored inside an AWS Nitro enclave, the enclave signs a credit tier, and that tier is written to Solana, where a lending pool reads it inside its own borrow instruction.

Between the browser and all of that sits a server I wrote: the gateway. It opens a session with the enclave, streams the processing stages to the page, and runs a relayer that pays transaction fees, so a demo wallet needs no SOL.

The product's whole claim is that a lender doesn't have to trust me. If the web page shows whatever my gateway says, that claim ends at the page. So the frontend treats the gateway as a messenger: it can carry bytes, but it never becomes the source of anything the page calls verified. The project's coding guidelines put it in one line: anything shown as verified is read from the chain, not from the gateway.

"Read from the chain" has limits of its own, and I'll be specific about them at the end. In short: the page still trusts the RPC node it reads from, and the code I serve it. What it stops trusting is my gateway.

This post covers the five places that rule became code, and the review findings that showed where it still leaked. Every excerpt is from release [v0.5.3](https://github.com/pandaa880/tee-income-oracle/tree/v0.5.3/web/src).

## Table of contents

## 1. Sign what you rebuilt, not what you're handed

Before the enclave scores anything, the borrower signs a short text that binds the session to their wallet:

```text
tee-income-oracle: bind session
session: <session id>
wallet: <borrower's address>
policy: <policy hash, 64 hex characters>
expires: <unix seconds>
```

The gateway sends this text. The easy version shows it, has the wallet sign it, and sends the signature back. That gives the gateway the pen: whatever it puts in front of the wallet gets signed, whether that's a different wallet, an expiry next year, or a policy no pool lends under. In the demo the wallet lives in the tab and signs without a prompt, so the page is the only thing that reads the text before it's signed.

So the page builds the text itself from what it already knows, and signs only if the gateway's copy matches it exactly:

```ts
const fresh = expires > now && expires <= now + MAX_LIFETIME_SECS + SKEW_SECS;
if (
  !fresh ||
  expected !== session.intent ||
  policy === undefined ||
  !poolPolicies.includes(policy)
) {
  return { ok: false, error: { code: "protocol_error" } };
}
return { ok: true, value: new TextEncoder().encode(expected) };
```

The lines fall into two groups. The wallet line comes from the page alone: it's the wallet in the tab, whatever the gateway says. The other three come from the gateway, so the page can only hold them to rules:

- **Session id:** the one the gateway issued when it opened this session. The page checks it's the same session, not that the id means anything.
- **Policy hash:** must be a policy one of the listed pools lends under. An attestation under any other policy would only ever fail the pool's `PolicyMismatch` check.
- **Expiry:** must fall within the next ten minutes, plus a minute for clock skew.

So a gateway can't get a signature for a different wallet, a policy no pool accepts, or an expiry next year. It still picks the session and the policy, within those limits.

The function returns bytes the browser built, and those are what get signed. Signing whatever the gateway sends is trusting the gateway. I sign what I rebuilt. ([`intent.ts`](https://github.com/pandaa880/tee-income-oracle/blob/v0.5.3/web/src/domain/intent.ts))

## 2. A signature from the relayer proves something landed, not that yours did

To borrow, the page builds a transaction with the relayer as fee payer, and the borrower signs it. The gateway's relayer adds its own signature, sends the transaction and returns its signature. The page then polls that signature until it's confirmed.

The obvious version believes that answer. But every confirmed transaction has a signature. A buggy or hostile relayer could return one from an earlier borrow, or from someone else's, and the page would say "borrowed".

Reading the account you expected to change helps, and the page does that: a borrow needs no loan account before and a loan with this amount after. But a read from public RPC can come from a node that's behind, so a read alone can't settle it.

The fix is cryptographic. On Solana, a transaction's id is its first signature, and the first signature is the fee payer's, over the message bytes. Here the fee payer is the relayer. So the id the relayer returns has to verify, under the relayer's public key, over the exact message the page built and the borrower signed:

```ts
async function isOurTransaction(
  signature: string,
  txB64: string,
  relayer: Address
) {
  const wire = Uint8Array.from(getBase64Encoder().encode(txB64));
  const { messageBytes } = getTransactionDecoder().decode(wire);
  const bytes = Uint8Array.from(getBase58Encoder().encode(signature));
  if (!isSignatureBytes(bytes)) return false;
  return verifySignature(
    await getPublicKeyFromAddress(relayer),
    bytes,
    messageBytes
  );
}
```

A signature over a different message fails. That binds the returned id to the message the browser signed, so a confirmed status for that id is a confirmed status for these bytes.

It doesn't stop every replay. Two identical borrows built on the same recent blockhash produce the same message, and Ed25519 signatures are deterministic, so an earlier signature over those exact bytes would still verify. That gap is narrow here: the page fetches a fresh blockhash for every transaction, and it still reads the loan account after confirmation, which a replayed id can't change. ([`use-loan.ts`](https://github.com/pandaa880/tee-income-oracle/blob/v0.5.3/web/src/app/use-loan.ts))

## 3. Show the chain's values, not the server's

When scoring finishes, the gateway streams the result: the tier, and the payload the oracle wrote on chain. The first result page showed the tier right away and read the chain "for the details". A reviewer called it the gateway's word with a seal on it, which was accurate.

Now the page says "reading your tier back from Solana…" until a chain read holds the same payload, and every field on the result comes from that read.

Getting the comparison right took two tries. The first matched the chain record to the gateway's report by its `issued_at` timestamp and kept the gateway's tier for display. A gateway could relay a real tier C attestation and then report tier A with the same timestamp. The timestamps match, and the page shows A.

The fix compares every field of the payload, takes every value from the chain, and treats a difference as an error rather than "still loading":

```ts
if (record === null || record.payload.issuedAt < reported.issuedAt)
  return { kind: "pending" };
if (credential === undefined || NOT_SHOWABLE.has(credential.status))
  return { kind: "mismatch" };
return samePayload(record.payload, reported)
  ? { kind: "confirmed", record }
  : { kind: "mismatch" };
```

An older record means the new one hasn't landed yet. A record at or after the reported time that differs in any field means the chain doesn't confirm the report. That isn't proof the gateway lied: the oracle lets a newer attestation replace an older one, so a legitimate later attestation could land before the read. Either way the page has nothing it can confirm, so it fails closed. ([`borrow-view.ts`](https://github.com/pandaa880/tee-income-oracle/blob/v0.5.3/web/src/domain/borrow-view.ts))

The same mistake was hiding one level down. A "registered on Solana" chip next to the enclave build was fed by the gateway's `/v1/info` endpoint. Now only a read of the on-chain registry can say "registered".

The gateway still adds one thing to the result: the link to its transaction. Its messages move the page from one step to the next; they never supply a value the page shows as fact.

## 4. "Valid" has to mean the program would agree about the credential

The loan page shows a badge for the borrower's tier against a pool: valid, stale, expired, policy mismatch and so on. The first version checked the rules I thought mattered most. Review found four of the pool's credential checks missing, so the badge could say "valid" about a credential the program would reject.

A "valid" badge is a prediction about what the program will say about this credential. The honest way to make that prediction is to run the program's attestation checks, all of them, in the program's order. Order matters because the badge names the first credential check that fails, and that should match the error the program would give for that credential.

The program, condensed:

```rust
require_keys_eq!(stored.signer, sas_signer_address(), PoolError::WrongAttestationSigner);
check_expiry(now, stored.expiry)?;
let limit = tier_limit(&params.tier_limits, payload.tier)?;
require!(amount <= limit, PoolError::AmountOverTierLimit);
require!(payload.policy_hash == params.policy_hash, PoolError::PolicyMismatch);
check_freshness(params, now, &payload)?;
// then: check_enclave (approved by this pool, matches the registry entry, not revoked)
```

The browser:

```ts
if (attestation.signer !== sasSigner) return "foreign_signer";
if (now >= attestation.expiry) return "expired";
// ...
if (tierLimit(params.tierLimits, payload.tier) === 0n)
  return "tier_not_accepted";
if (!sameBytes(payload.policyHash, Uint8Array.from(params.policyHash)))
  return "policy_mismatch";
return (
  freshness(params, payload, now) ??
  enclave(params, payload, enclaveEntry) ??
  "valid"
);
```

So "valid" means the credential passes this pool's attestation checks, at the state and time the page read. ([`credential.ts`](https://github.com/pandaa880/tee-income-oracle/blob/v0.5.3/web/src/domain/credential.ts), [`borrow.rs`](https://github.com/pandaa880/tee-income-oracle/blob/v0.5.3/programs/demo-pool/src/instructions/borrow.rs)) It doesn't promise the borrow succeeds. That can still fail for reasons outside the credential: the amount is over the tier's limit, the borrower already has a loan in this pool, the vault is short, a token account is frozen, or the state changes before the transaction runs. The loan book that funders see runs the same function on every borrower, so FRESH there makes the same, narrower promise.

Choosing which checks to run is a product decision too. Repay first sat behind the same "is your tier valid?" gate as Borrow. A borrower whose tier had gone stale couldn't repay their loan, and repaying needs no tier at all. Repay now has no tier check in front of it.

## 5. The RPC node is a server too

Moving trust from my gateway to "the chain" really moves it to an RPC endpoint, which is someone else's server. Two things went wrong there.

**A node one slot behind.** Public devnet RPC is load-balanced. Right after a transaction confirms, the next read can come from a node that hasn't seen it yet. The tests didn't catch this; a manual run on the live site did. After a repay, the page read the pool and saw the loan was gone. Then the data layer refetched, got a node that was behind, and the closed loan came back on screen.

Two changes fixed that race. The read-back retries briefly, five times at half-second intervals, and reads the pool, its vault and the loan in a single `getMultipleAccounts` call, so all three come from one node's view. And the read that proved the change goes straight into the query cache, cancelling any fetch already in flight, instead of being requested again:

```ts
const settle = async ({
  signature,
  read,
}: {
  signature: string;
  read: PoolRead;
}) => {
  await queryClient.cancelQueries({ queryKey: poolKey });
  queryClient.setQueryData(poolKey, read);
  return signature;
};
```

The read that proved the change is the freshest read you have, so the page keeps it instead of asking again straight away. That fixes the race I saw, and no more. A later refetch, say when the window regains focus, can still land on a node that's behind, because nothing tells the node how fresh its answer must be.

Solana's RPC has a parameter for that: `minContextSlot`. Each response carries the slot it was evaluated at; pass that slot as `minContextSlot` on later requests, and a node that hasn't reached it returns an error instead of older state. The page doesn't do this yet. It's the fix for the general case.

**A reply that's one short.** The funders' loan book reads borrowers' attestations with `getMultipleAccounts`, 100 addresses per call, and matches each account to its address by position. Nothing checked the reply's length. A node that returned 99 accounts for 100 addresses would have shifted every row after the gap: borrower K shown with borrower K+1's FRESH badge.

Now a reply of the wrong length is a protocol error ([`rpc.ts`](https://github.com/pandaa880/tee-income-oracle/blob/v0.5.3/web/src/adapters/rpc.ts)). So is a repeated loan row from `getProgramAccounts`, which would inflate every total. And each attestation must name its own borrower: the attestation's address is derived from the borrower's wallet, and the stored record says which wallet that was, so the page checks the two agree. Any bad row fails the whole book ([`use-book.ts`](https://github.com/pandaa880/tee-income-oracle/blob/v0.5.3/web/src/app/use-book.ts)). A partial book presented as the book is worse than an error.

## Where the trust actually stops

None of this makes the page trustless, and I'd rather say where the limits are.

- The page reads one RPC endpoint. It checks what's cheap to check: reply lengths, account sizes and discriminators, which wallet a record belongs to, and signatures over bytes it built. An endpoint that invented consistent account data could still fool it.
- Whether a transaction confirmed also comes from that endpoint. The signature check proves the id belongs to my message; the RPC still reports the status.
- The page itself is served by me. A different build could skip every check. That's why the source is public at release tags, and why the receipt checks also run from a command line.

What the checks do buy: my gateway can't make the page show a tier, a loan or a registration that isn't on chain. A bug in the gateway shows up as an error on screen, not as a wrong number a lender acts on.

## If you build a frontend for a chain

- **Rebuild anything the user signs** from data you already hold. Compare it with what the server sent, and sign your own copy.
- **Treat a transaction signature from an API as a claim.** If you built the message, verify the signature over it, and still read the state it should have changed.
- **Show values from a chain read**, not from the API that triggered the write. Compare whole records, not a timestamp, and fail closed when they don't match.
- **A status badge is a promise about the program.** Mirror the checks it covers, in the program's order, and say what it doesn't cover.
- **After a write, keep the read that proved it.** For later reads, carry its slot forward as `minContextSlot`.
- **Check reply lengths** whenever you match results to requests by position.
