---
title: "Money without floats: parsing rupees as integer paise"
description: "Why 96 of 100 paise endings repeat in binary, how that can flip a signed credit tier, and how I parse bank amounts from text into integer paise."
pubDatetime: 2026-10-25T17:41:00+05:30
tags:
  - fintech
  - floating-point
  - rust
  - typescript
  - javascript
draft: false
---

I'm building [TEE Income Oracle](https://github.com/pandaa880/tee-income-oracle), a service that reads a borrower's bank statement inside a secure enclave and signs a credit tier: A, B, C or reject. A lending pool reads that tier on chain. The score has two implementations: the enclave scorer in Rust, and a second scorer, written separately in TypeScript, that produces the expected tier for a set of test statements. The Rust tests fail unless the two agree.

So I need the same statement to produce the same tier, every time, in two languages. This post follows one amount through that pipeline: from the bank's text, to exact paise, to arithmetic that both scorers do the same way.

## Table of contents

## A tier that depends on the order of addition

One rule for tier A is about FOIR: monthly loan repayments (EMIs) as a share of monthly income. My policy measures it in whole basis points, rounded down, and tier A allows at most 4,000 (40.00%).

Take a ₹50,000 income and three EMIs that add up to ₹20,005.00. That's 40.01%, or 4,001 basis points, so this borrower is not tier A. Here's the check with floats:

```js
const income = 50000;
const emis = [5000.0, 12345.06, 2659.94]; // ₹20,005.00: 40.01%, not tier A

const bps = total => Math.floor((total * 10000) / income);

const forward = emis[0] + emis[1] + emis[2]; // 20004.999999999996
const backward = emis[2] + emis[1] + emis[0]; // 20005

bps(forward); // 4000 → tier A
bps(backward); // 4001 → not tier A
```

Same amounts, same rule, two tiers. Nothing here is a bug in the usual sense: both orders are reasonable, and two programs written separately can easily pick different ones. With floats, they don't have to be wrong to disagree. And in my system the tier gets signed, so a wrong one is a signed claim about a real person.

With integer paise, the order can't matter:

```js
const emisPaise = [500000n, 1234506n, 265994n];
const total = emisPaise[0] + emisPaise[1] + emisPaise[2]; // 2000500n

(total * 10000n) / 5000000n; // 4001n in any order → not tier A
```

## Why floats can't hold most rupee amounts

A float stores a number as a binary fraction. A paisa is a decimal fraction: 1/100 of a rupee.

Decimal has the same problem with other numbers. You can't write 1/3 in decimal; it's `0.3333…` forever, because 3 doesn't divide any power of 10. A fraction ends in decimal only if its denominator, in lowest terms, is made of 2s and 5s. Binary is stricter: the denominator has to be a power of 2. ½ and ¼ are fine. 1/20 has a 5 in it, so 0.05 repeats forever in binary:

```js
(0.05).toFixed(30); // "0.050000000000000002775557561563"
```

A paise ending is k/100, and it reduces to a power-of-two denominator only when k is a multiple of 25. I checked all 100 endings with a script: **96 of the 100 possible paise endings repeat in binary.** Only `.00`, `.25`, `.50` and `.75` can be stored exactly, and only if the whole amount fits the format's precision.

That's a statement about endings, not about real transactions, which don't spread evenly across them. For amounts with any of those 96 endings, a binary float holds an approximation. Each error is tiny. Across hundreds of transactions, rounding errors can accumulate, and as the example above shows, a tiny error is enough when it lands on a boundary.

## Where the amounts come from

The statement arrives in the format India's Account Aggregator network uses. ReBIT defines it as an XML schema, and the [DEPOSIT schema](https://specifications.rebit.org.in/api_schema/account_aggregator/documentation/deposit.html) types `Transaction.amount` as [`xs:float`](https://www.w3.org/TR/xmlschema-2/#float). Balances and limits are `xs:string`, with no pattern.

ReBIT doesn't say why, and it isn't specific to this field. Across the 23 FI type schemas in the [Account Aggregator standards repo](https://github.com/Sahamati/account-aggregator-standards), the numeric declarations use `xs:float` and integer types, including `xs:integer` and `xs:positiveInteger`. None uses `xs:decimal`. The deposit schema has typed amounts this way since the earliest version in that repo (April 2021), and version 2.0.0 keeps it. I read it as "this is a number", not as a choice of binary format. Strictly, `xs:float` means a 32-bit float, and taken literally a 32-bit float can't hold ₹1,23,456.78 (it becomes 123456.78125).

The schema describes XML, but the data my service accepts is JSON. [Finvu's sample fetch response](https://finvu.github.io/sandbox/finvu_fiu_integration.html#fetch-data), from the Account Aggregator I target, shows the mapping: attributes become keys, `amount` arrives as a JSON number (`6036`), and balances arrive as JSON strings (`"322644.09"`). So my parser sees two forms:

- **JSON numbers**, such as `85000`, `1234.050` or `1.2E7`.
- **Numeric strings**, such as `"112340.50"`. Here the schema allows any text, so XML-style spellings like `"+5"` and `".5"` can appear too. They aren't valid JSON numbers, only valid inside strings.

`1.2E7` is a real possibility, not a curiosity. Java's [`Double.toString`](https://docs.oracle.com/javase/8/docs/api/java/lang/Double.html#toString-double-) writes values of 10⁷ and above in scientific notation, so a producer that uses it sends ₹1.2 crore as `1.2E7`. My first parser accepted only plain decimals with at most two places, and it would have rejected that spelling.

## Integer paise, parsed from the text

The money type in the oracle is a count of paise:

```rust
/// Money in integer paise (₹1 = 100 paise). The only money type in
/// `tio-core`.
pub struct Paise(i64);
```

₹1,234.05 is `123405`. Integer sums are exact as long as every intermediate result stays in range, so the Rust scorer adds with checked arithmetic and does ratio maths in `i128`. The TypeScript scorer uses `bigint` with the same bounds.

The amount has to become an integer without ever becoming a float. If a JSON library turns `1234.05` into a float first, the error is in before my code sees the value. So the parser reads the raw text of each JSON value and never converts through a float. That avoids adding error at this step. It can't recover precision a producer already lost upstream.

The rule: **within the supported grammar and range, accept any spelling that is exactly a whole number of paise, and reject everything else. Never round.** Rounding would hide bad bank data inside a signed result.

The parser splits the text into sign, digits and exponent, then works out which power of ten turns the digits into paise:

```rust
let trailing_zeros = to_i64(digits.len() - significant.len())?;
let power = decimal.exponent + 2 - to_i64(decimal.frac.len())? + trailing_zeros;
if power < 0 {
    return Err(MoneyError::NotWholePaise);
}
```

The `+ 2` converts rupees to paise, and trailing zeros fold into the power, so `1234.050` and `1234.05` are the same value:

| Input      | Significant digits | Power | Result                         |
| :--------- | :----------------- | :---- | :----------------------------- |
| `1234.05`  | `123405`           | 0     | 1,23,405 paise                 |
| `1234.050` | `123405`           | 0     | 1,23,405 paise                 |
| `1.2E7`    | `12`               | 8     | 1,20,00,00,000 paise (₹1.2 cr) |
| `1234.567` | `1234567`          | −1    | rejected: not whole paise      |

The supported range has two deliberate limits. Exponents are capped at ±30, and the grammar is checked before any range check, so a hostile `1e999999999` is rejected cheaply. And `i64::MIN` is rejected, so every value the parser returns can be negated safely. The full parser is about 220 lines with comments: [`tio-core/src/money.rs`](https://github.com/pandaa880/tee-income-oracle/blob/v0.5.3/tio-core/src/money.rs).

## Rounding that both scorers agree on

Integers remove accidental rounding, not all rounding. A scorer still divides: FOIR is a ratio, a median of an even number of months falls between two values, and income volatility needs a square root. So every rounding step is written into the spec, and both scorers implement it the same way:

- FOIR is `floor(obligations × 10000 / income)` in basis points.
- An even-length median is the floor of the two middle values' mean.
- The coefficient of variation uses an integer square root, rounded down.

The FOIR floor is a policy choice, and it's worth saying plainly what it means: ₹20,000.01 against ₹50,000 is 40.00002%, which floors to 4,000 basis points and still counts as tier A. I'm fine with that band in an eligibility rule, because it's written down and both scorers apply it. If you need "at most 40%" exactly, skip the division and compare products: `obligations × 5 ≤ income × 2`.

## Other ways to do it

Integer paise isn't the only sound design. Exact decimal types, such as Java's `BigDecimal`, also avoid binary rounding.

I chose integers for my own constraints: two languages that must agree to the paisa, arithmetic that is mostly sums and comparisons plus a few specified ratios, and an output that gets signed. Payment APIs work the same way: [Stripe](https://docs.stripe.com/currencies) takes `1099` to charge 10.99 USD, and [Razorpay](https://razorpay.com/docs/api/orders/create/) takes amounts as integers in the smallest currency sub-unit.

## If you handle money in JavaScript or TypeScript

- **Keep amounts as integers in the smallest unit**, and check intermediate results too, not just amounts. `Number.MAX_SAFE_INTEGER` is about ₹90 lakh crore in paise, but a paise amount times 10,000 leaves the safe range above about ₹900 crore. Use `bigint` when products can get that big.
- **Don't multiply a float by 100 and hope.** `19.99 * 100` is `1998.9999999999998`. Parse the string.
- **Get the raw text if an API sends JSON numbers.** Newer runtimes pass the original text to the `JSON.parse` reviver (I checked Node 24):

  ```js
  JSON.parse('{"amount": 1234.05}', (key, value, context) =>
    key === "amount" ? context.source : value
  ); // { amount: "1234.05" }
  ```

- **Don't round money with `toFixed`.** `(1.005).toFixed(2)` returns `"1.00"`, because the stored value is slightly below 1.005.
- **Write the rounding rules down**, and use the same ones in every implementation.
- **Read the spec, not just the sample.** The sample I started from had plain decimals. The schema allows much more.

Integer paise keeps the money exact. Specified rounding rules make the remaining calculations reproducible across both implementations. Together, the same statement gives the same signed tier in Rust and in TypeScript.
