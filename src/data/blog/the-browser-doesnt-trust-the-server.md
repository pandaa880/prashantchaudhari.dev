---
title: "The browser doesn't trust the server: a Solana frontend that checks its own backend"
description: "My server can tell the page a borrower got tier A. The page doesn't show it until Solana agrees. Five checks a Solana frontend can run on its own backend."
pubDatetime: 2026-11-01T10:00:00+05:30
tags:
  - solana
  - frontend
  - typescript
  - security
draft: true
---

My server can tell the web page that a borrower got credit tier A. The page doesn't show it until Solana agrees.

That sounds like paranoia about my own code, so here's the context. I'm building [TEE Income Oracle](https://github.com/pandaa880/tee-income-oracle). A borrower's bank statement is scored inside a secure enclave, the enclave signs a credit tier, and the tier is written to Solana, where a lending pool reads it before it lends. Between the browser and all of that sits a server I wrote, the gateway. It talks to the enclave, streams progress to the page, and pays transaction fees so a demo wallet needs no SOL.

The whole product claims that a lender doesn't have to trust me. If the page repeats whatever my gateway says, that claim stops at the page. So the page treats the gateway as a messenger: it can carry bytes, but it never becomes the source of anything the page calls verified.

This post is for frontend developers building on Solana. You know transactions, signatures and RPC calls; you don't need to know anything about enclaves. It walks through five places the page checks its own backend, each as the shortcut, what can go wrong with it, and what the page does instead. The page still trusts two things, the RPC node it reads from and the code I serve it, and I'll come back to both at the end. Every link points to release [v0.5.3](https://github.com/pandaa880/tee-income-oracle/tree/v0.5.3/web/src).

## Table of contents

## 1. Sign your own copy

Before scoring starts, the borrower signs a short text that ties the session to their wallet. It's a plain message signature, the kind a wallet's `signMessage` produces, not a transaction:

```text
tee-income-oracle: bind session
session: <session id>
wallet: <borrower's address>
policy: <policy hash>
expires: <unix seconds>
```

The policy hash identifies the scoring rules the enclave will apply; each pool says which policy it accepts.

**The shortcut:** the gateway sends this text, the page passes it to the wallet, and the wallet signs it.

**What can go wrong:** the gateway now holds the pen. Whatever it puts in that text gets signed: a different wallet, an expiry next year, a policy no pool lends under. In the demo the wallet lives in the browser tab and signs without a prompt, so nobody reads the text first.

**What the page does:** it writes the text itself and signs its own copy, and only if the gateway's copy is identical. The wallet line comes from the page alone. The other values come from the gateway, so the page can only hold them to rules: the session id must be this session's, the policy must be one a listed pool lends under, and the expiry must fall within the next ten minutes (plus a minute for clock skew). A gateway can still choose the session and the policy within those rules. It can't get a signature for anything else. ([`intent.ts`](https://github.com/pandaa880/tee-income-oracle/blob/v0.5.3/web/src/domain/intent.ts))

This isn't a quirk of my setup. Kit's documentation for [signing off-chain messages](https://github.com/anza-xyz/kit/blob/main/packages/offchain-messages/README.md) makes the same argument from the other side: a valid signature from a wallet proves little until you've also confirmed it covers the message you meant to have signed.

## 2. Check that the signature you got back is yours

To borrow, the page builds a transaction and the borrower signs it. The gateway's relayer pays the fee, so it signs too, sends the transaction, and returns its signature. The page polls that signature until it's confirmed.

**The shortcut:** take the returned signature, wait for "confirmed", show "borrowed".

**What can go wrong:** every confirmed transaction has a signature. A buggy or hostile relayer could hand back one from an earlier borrow, or from someone else's, and the page would celebrate a loan that never happened. Reading the loan account afterwards helps, but on public RPC that read can come from a node that's behind.

**What the page does:** on Solana, a transaction's id is its first signature, and the first signature belongs to the fee payer, signed over the transaction's message bytes. The fee payer here is the relayer. So the page checks that the returned id is a valid relayer signature over the exact bytes it built. With [`@solana/kit`](https://github.com/anza-xyz/kit) (the library formerly released as web3.js 2.0), that's a decode and a verify:

```ts
const { messageBytes } = getTransactionDecoder().decode(wire);
const signature = getBase58Encoder().encode(returnedId);
return verifySignature(relayerKey, signature, messageBytes);
```

Solana's own [guide to partial signing](https://solana.com/docs/core/transactions/partial-signing) recommends this check whenever a backend or sponsor pays the fee: check each signature you get back against the exact message bytes and the key you expected. A signature over any other message fails, so the id is tied to these exact message bytes. That still isn't complete replay protection. Two identical borrows built on the same blockhash produce identical bytes and the same signature, and asking for the latest blockhash each time doesn't guarantee a different one. The chain is safe either way: validators drop a transaction whose signature they've already processed, so nothing executes twice. The risk is to what the page believes. A relayer could answer a new, identical request with the signature of the earlier one, which did confirm. The page also reads the loan account after confirmation, which makes that harder to slip through, but the read has no lower bound on how fresh it must be, so a stale node could still show the state the page expects. (The excerpt is condensed from `isOurTransaction` in [`use-loan.ts`](https://github.com/pandaa880/tee-income-oracle/blob/v0.5.3/web/src/app/use-loan.ts).)

## 3. Show what the chain says, not what the server says

When scoring finishes, the gateway streams the result: the tier, and the payload it says the oracle wrote to Solana. The payload is the signed part of the on-chain record, including the tier, the policy, the statement dates and the enclave build that scored it.

**The shortcut:** show the tier straight away, and read the chain for extra details. My first version did this. A reviewer described it as the gateway's word with a seal on it.

**What can go wrong:** the page looks verified while showing an unverified value. My first fix had a subtler hole. It matched the chain record to the gateway's report by timestamp, then kept displaying the gateway's tier. A gateway could relay a real tier C record and report tier A with the same timestamp. The timestamps match, and the page says A.

**What the page does:** it shows "reading your tier back from Solana…" until the payload on chain matches the reported payload, field by field. It then displays that payload and the record's expiry, both as read from Solana. If a payload at least as new as the report differs in any field, the page shows an error. That doesn't prove the gateway lied, because the oracle lets a newer record replace an older one, but the chain no longer confirms the report, so the page fails closed. ([`borrow-view.ts`](https://github.com/pandaa880/tee-income-oracle/blob/v0.5.3/web/src/domain/borrow-view.ts))

The same mistake hid in a smaller place. A "registered on Solana" chip was fed by a gateway endpoint. Now only a read of the on-chain registry can say "registered". The gateway still moves the page from one step to the next, and it supplies the link to its transaction. It never supplies a value the page shows as fact.

## 4. A "valid" badge is a promise about the program

The loan page shows a badge for the borrower's tier against a pool: valid, stale, expired, policy mismatch and so on.

**The shortcut:** check the rules that seem important. My first version did that, and review found four of the pool's checks missing. The badge could say "valid" about a credential the program would reject.

**What the page does:** it runs every credential check the pool program runs, in the program's order:

1. the record was written by the oracle,
2. it hasn't expired,
3. the pool lends to this tier at all,
4. it was scored under the pool's policy,
5. it's fresh enough (how old the record is, how old the bank statement is, and how many days it covers),
6. the enclave build that scored it is approved by the pool and not revoked.

The order matters because the badge names the first check that fails, and that should match what the program would say about the same credential. ([`credential.ts`](https://github.com/pandaa880/tee-income-oracle/blob/v0.5.3/web/src/domain/credential.ts), [`borrow.rs`](https://github.com/pandaa880/tee-income-oracle/blob/v0.5.3/programs/demo-pool/src/instructions/borrow.rs))

Even then, "valid" makes a narrow promise: the credential passes this pool's checks at the state and time the page read. A borrow can still fail for reasons outside the credential: the amount is over the tier's limit, there's already a loan in this pool, the vault is short, a token account is frozen, or the state changes before the transaction runs. The funders' loan book runs the same function for every borrower, so "fresh" there makes the same narrow promise.

Choosing which checks to run is a product decision too. Repay first sat behind the same "is your tier valid?" gate as Borrow, which locked a borrower with a stale tier out of repaying, and repaying needs no tier at all. Repay now has no tier check in front of it.

## 5. The RPC node is a server too

Reading "from the chain" really means reading from an RPC node, which is someone else's server. Two things went wrong there.

**A node one step behind.** Public devnet RPC is load-balanced, so the read right after a confirmation can land on a node that hasn't caught up. The tests didn't catch this; a manual run on the live site did. After a repay, the page read the pool and saw the loan was gone. Then the data layer fetched again, hit a lagging node, and the closed loan came back on screen.

The fix has two parts. The read-back retries a few times, and it reads the pool, its vault and the loan in one call, so all three come from the same node. Then the read that proved the change goes straight into the query cache, and any fetch already in flight is cancelled, so it can't overwrite it:

```ts
await queryClient.cancelQueries({ queryKey: poolKey });
queryClient.setQueryData(poolKey, provingRead);
```

That fixes the race I saw, and no more. A later refetch, say when the tab regains focus, can still hit a lagging node. Solana's RPC has a parameter for the general case, `minContextSlot`. Account reads such as `getMultipleAccounts` return the slot they were evaluated at in `context.slot`. Keep the highest slot you've accepted, pass it as `minContextSlot` on later reads with the same commitment level, and a node that hasn't reached that slot returns an error instead of older data. The page doesn't do this yet.

**A reply that's one short.** The funders' loan book asks for up to 100 accounts per call and matches each reply to its request by position. Nothing checked the reply's length. The RPC spec says a node returns one entry per address, with `null` for an account that doesn't exist, but the page took that on trust. A node, or a proxy in front of one, that returned 99 accounts for 100 addresses would shift every row after the gap, and show one borrower with the next borrower's "fresh" badge. Now a reply of the wrong length is an error ([`rpc.ts`](https://github.com/pandaa880/tee-income-oracle/blob/v0.5.3/web/src/adapters/rpc.ts)). So is a duplicated loan row, which would inflate every total, and so is a record that doesn't name the borrower it was fetched for. One bad row fails the whole book ([`use-book.ts`](https://github.com/pandaa880/tee-income-oracle/blob/v0.5.3/web/src/app/use-book.ts)), because a partial book presented as the book is worse than an error.

## Where the trust actually stops

None of this makes the page trustless:

- **It reads one RPC node.** It checks what's cheap to check: reply lengths, account sizes and types, which wallet a record belongs to, and signatures over bytes it built. A node that invented consistent data could still fool it.
- **"Confirmed" also comes from that node.** The signature check proves the id belongs to the bytes the page built; the node still reports whether they landed.
- **I serve the page.** A different build could skip every check. That's why the source is public at release tags, and why the receipt checks also run from a command line.

What the checks do buy: my gateway is no longer the only authority for a tier, a loan or a registration. The page checks each of those claims against what an RPC node returns, and most gateway bugs now show up as an error on screen instead of a wrong number. The limits above still apply: a stale read, or a reused identical transaction, can get past these checks.

## A checklist for your own frontend

- **Rebuild anything the user signs** from data you already hold, and sign your copy.
- **Treat a signature from an API as a claim.** If you built the transaction, verify the signature over its bytes. It ties the id to those bytes; it doesn't stop an identical transaction being reused.
- **Show values from a chain read**, not from the API that triggered the write. Compare every field of the reported payload, display the chain's values, and fail closed when the payloads differ. Read anything outside the payload, such as expiry, straight from the chain.
- **Make a status badge mirror the program's checks**, in the program's order, and say what it doesn't cover.
- **After a write, keep the read that proved it.** For later reads, carry the highest slot you've accepted forward as `minContextSlot`.
- **Check reply lengths** whenever you match results to requests by position.

To try this on your own app, pick one value your UI shows as confirmed, and trace where it comes from. If the answer is "the API told us", that's the first check to add.
