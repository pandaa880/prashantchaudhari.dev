---
title: "Money without floats: why 96% of rupee amounts can't be stored exactly"
description: "India's bank-data schema types amounts as xs:float. Why 96 of 100 paise endings can't be stored exactly, and how I parse money as integer paise."
pubDatetime: 2026-10-27T10:00:00+05:30 # placeholder: set the real time when publishing
tags:
  - fintech
  - rust
  - javascript
draft: true
---

I'm building [TEE Income Oracle](https://github.com/pandaa880/tee-income-oracle), a service that reads a borrower's bank statement inside a secure enclave and signs a credit tier: A, B, C or reject. The statement arrives in the format India's Account Aggregator network uses, which is defined by ReBIT's XML schema. Before writing the parser, I opened that schema to see how it describes a transaction amount.

The [DEPOSIT schema](https://specifications.rebit.org.in/api_schema/account_aggregator/documentation/deposit.html) types `Transaction.amount` as `xs:float`.

In XML Schema, [`xs:float`](https://www.w3.org/TR/xmlschema-2/#float) is a 32-bit IEEE floating-point number. Taken literally, ₹1,23,456.78 can't even survive the trip:

```js
Math.fround(123456.78); // 123456.78125
Math.fround(12345678.9); // 12345679
```

The second line is a ₹1.2 crore amount that has lost its paise. JavaScript's own numbers are 64-bit, so they do better, but not well enough for money. This post is about why, and what I did instead.

## Table of contents

## Floats count in halves and quarters

A float stores a number as a binary fraction. Rupee amounts are decimal fractions: a paisa is 1/100 of a rupee. Those two systems don't line up.

Decimal has the same problem with other numbers. You can't write 1/3 in decimal: it's `0.3333…` forever, because 3 doesn't divide any power of 10. A fraction has a finite decimal expansion only if its denominator, in lowest terms, is made of 2s and 5s.

Binary is stricter. A fraction has a finite binary expansion only if its denominator is a power of 2. So ½ (`0.1` in binary) and ¼ (`0.01`) are exact. But 1/20 = 1/(2² × 5) has a 5 in it, so 0.05 repeats forever in binary, the way 1/3 does in decimal.

A paise ending is k/100 for k from 0 to 99. Reduce that fraction and it has a power-of-two denominator only when k is a multiple of 25. I counted it with a short script instead of trusting my arithmetic:

```js
const gcd = (a, b) => (b === 0 ? a : gcd(b, a % b));
const isPowerOfTwo = n => (n & (n - 1)) === 0;

const exact = [];
for (let k = 0; k < 100; k++) {
  if (isPowerOfTwo(100 / gcd(k, 100))) exact.push(k);
}
// exact: [0, 25, 50, 75]  →  96 of 100 endings are approximations
```

Only `.00`, `.25`, `.50` and `.75` are stored exactly. Every other amount is stored as the nearest binary fraction the float can hold:

```js
(0.05).toFixed(30); // "0.050000000000000002775557561563"
(0.25).toFixed(30); // "0.250000000000000000000000000000"

0.1 + 0.2; // 0.30000000000000004

let total = 0;
for (let i = 0; i < 10; i++) total += 0.1;
total; // 0.9999999999999999
```

Most of the time the error is far below a paisa and display code rounds it away. That's why floats feel fine for money until the day they aren't.

## Why "close enough" isn't enough for a signed score

For my oracle, a tiny error is not a cosmetic problem, for three reasons.

**Errors add up.** A statement has hundreds or thousands of transactions. Each one carries its own small error into every sum.

**The order of addition changes the answer.** Float addition isn't associative: `(a + b) + c` can differ from `a + (b + c)`.

<!-- prettier-ignore -->
```js
(0.1 + 0.2) + 0.3; // 0.6000000000000001
0.1 + (0.2 + 0.3); // 0.6
```

This matters because the score has two implementations. The enclave scorer is written in Rust. A second scorer, written separately in TypeScript, produces the expected tier for a set of test statements, and the Rust tests fail unless they match it. Two programs in two languages will not always add the same numbers in the same order. With floats, they don't have to be wrong to disagree.

**Thresholds flip.** One rule for tier A is that loan repayments (EMIs) are at most 40% of income. Here is a simplified version of that check with three EMIs that add up to exactly ₹20,000.00, which is exactly 40% of a ₹50,000 income:

```js
const emis = [1000.06, 12345.01, 6654.93]; // ₹20,000.00 in total
const limit = 50000 * 0.4; // tier A: EMIs ≤ 40% of a ₹50,000 income

const forward = emis[0] + emis[1] + emis[2];
const backward = emis[2] + emis[1] + emis[0];

forward; // 20000
backward; // 20000.000000000004
forward <= limit; // true  → tier A
backward <= limit; // false → not tier A
```

Same three amounts, same rule, two different tiers. In my system that tier gets signed and written on chain, so a wrong answer is not a display bug. It's a signed claim about a real person.

The same EMIs as whole paise don't have this problem:

```js
const emisPaise = [100006, 1234501, 665493];
emisPaise[0] + emisPaise[1] + emisPaise[2]; // 2000000
emisPaise[2] + emisPaise[1] + emisPaise[0]; // 2000000
```

## Integer paise, parsed from the text

So the money type in the oracle is an integer count of paise:

```rust
/// Money in integer paise (₹1 = 100 paise). The only money type in
/// `tio-core`.
pub struct Paise(i64);
```

₹1,234.05 is the integer `123405`. Integer addition is exact and order doesn't matter, in Rust, TypeScript or anything else. The only rounding left in the scorer is explicit: the repayment ratio is computed as `floor(obligations × 10000 / income)` in basis points, and both implementations floor the same way.

The harder part is getting the amount into an integer without it ever becoming a float. If the JSON parser reads `1234.05` as a number first, the error is already in before my code sees the value. So the parser works on the raw text of the JSON value and never calls a float conversion.

My first version was strict: plain decimals, at most two decimal places. Then I asked myself what real systems actually send, and the schema answered. Because `amount` is `xs:float`, all of these are valid spellings: `1.2E7`, `85000.0`, `1234.050`, `+5`, `.5`. Balances are worse: `xs:string` with no pattern at all.

`1.2E7` is not an edge case. Java's [`Double.toString`](https://docs.oracle.com/javase/8/docs/api/java/lang/Double.html#toString-double-) switches to scientific notation for values of 10⁷ and above, so any Java service that prints a double writes ₹1.2 crore as `1.2E7`. My strict parser would have rejected every statement with a credit of ₹1 crore or more.

So I changed the rule to this: **accept any spelling that is exactly a whole number of paise, and reject everything else. Never round.** Rounding would hide bad bank data inside a signed result.

The parser splits the text into sign, digits and exponent, then works out what power of ten the digits need to be multiplied by to get paise:

```rust
let trailing_zeros = to_i64(digits.len() - significant.len())?;
let power = decimal.exponent + 2 - to_i64(decimal.frac.len())? + trailing_zeros;
if power < 0 {
    return Err(MoneyError::NotWholePaise);
}
```

The `+ 2` converts rupees to paise. Trailing zeros are folded into the power, so `1234.050` and `1234.05` are the same value. Some examples:

| Input      | Significant digits | Power | Result                         |
| :--------- | :----------------- | :---- | :----------------------------- |
| `1234.05`  | `123405`           | 0     | 1,23,405 paise                 |
| `1234.050` | `123405`           | 0     | 1,23,405 paise                 |
| `1.2E7`    | `12`               | 8     | 1,20,00,00,000 paise (₹1.2 cr) |
| `1234.567` | `1234567`          | −1    | rejected: not whole paise      |

A negative power means a fraction of a paisa, which no bank should send, so it's an error, not something to round.

Two more edge cases took some thought.

**Hostile exponents.** `1e999999999` is a valid number. The parser caps the exponent at ±30 and checks the length of the exponent's digits before parsing them, so a huge exponent costs almost nothing to reject. It also checks the whole grammar before any range check, so a malformed value is always reported as malformed, never as "too big".

**`i64::MIN`.** A signed 64-bit integer goes one further on the negative side than on the positive side, so negating `i64::MIN` overflows. The parser rejects it, which keeps the range symmetric: every value it returns can be safely negated. There's a test for exactly that boundary.

The full parser is about 220 lines, including comments: [`tio-core/src/money.rs`](https://github.com/pandaa880/tee-income-oracle/blob/v0.5.3/tio-core/src/money.rs).

## What FinBox does, and why I didn't

FinBox is an Indian bank-statement analytics provider. Its [BankConnect API](https://docs.finbox.in/bank-connect/rest-api.html) returns money as JSON numbers, for example `"amount": 5188.0` and `"balance": 922.15`, and documents its aggregate fields as `Float`.

For their use case that's reasonable. Analytics output is usually read by a person or fed into a model, and a sub-paisa error changes nothing there.

My output is different: it's a signed claim that a second implementation recomputes, and a lending program acts on it. That makes it closer to a payment than a report. Payment APIs already work this way: [Stripe](https://docs.stripe.com/currencies) takes `1099` to charge 10.99 USD, and [Razorpay](https://razorpay.com/docs/api/orders/create/) takes amounts as integers in the smallest currency sub-unit, which for rupees is paise. So the oracle uses integer paise end to end. It still accepts FinBox-style input like `5188.0`, because that's an exact whole number of paise.

## If you handle money in JavaScript or TypeScript

- **Store and add amounts as integers in the smallest unit.** A JavaScript `number` holds integers exactly up to `Number.MAX_SAFE_INTEGER` (9,007,199,254,740,991). In paise, that's about ₹90 lakh crore, which covers most uses. Use `BigInt` when it might not.
- **Don't multiply a float by 100 and hope.** `19.99 * 100` is `1998.9999999999998`, and `4.35 * 100` is `434.99999999999994`. Parse the string instead.
- **Get the raw text if the API sends JSON numbers.** By the time `JSON.parse` hands you `1234.05`, it's already a float. Newer runtimes pass the original text to the reviver (I checked Node 24):

  ```js
  JSON.parse('{"amount": 1234.05}', (key, value, context) =>
    key === "amount" ? context.source : value
  ); // { amount: "1234.05" }
  ```

- **Don't round money with `toFixed`.** `(1.005).toFixed(2)` returns `"1.00"`, because 1.005 is actually stored as slightly less than 1.005.
- **Make rounding explicit, and do it once.** If a ratio needs rounding, pick the rule (floor, half-even), write it down, and use the same rule in every implementation.
- **Check the spec, not just the sample.** The sample statement I started from had plain decimals. The schema allows much more, and real data can use all of it.

Floats count in halves and quarters. Rupees count in hundredths. When the number is going to be signed, keep it in hundredths the whole way through.
