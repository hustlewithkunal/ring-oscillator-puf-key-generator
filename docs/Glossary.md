# Project Glossary: Terms Explained Simply

This is a plain-language reference for every important term in the RO-PUF Key Generator project. Each entry says **what it means**, gives an **analogy or example** where that helps, and says **where it appears in our project**.

---

## Contents

0. [The big picture in one page](#0-the-big-picture-in-one-page)
1. [PUF basics](#1-puf-basics)
2. [Measuring PUF quality](#2-measuring-puf-quality)
3. [Error-correcting codes (ECC)](#3-error-correcting-codes-ecc)
4. [Galois field GF(2⁴): the maths behind BCH](#4-galois-field-gf2-the-maths-behind-bch)
5. [BCH encoding and decoding, step by step](#5-bch-encoding-and-decoding-step-by-step)
6. [Fuzzy extractor and key generation](#6-fuzzy-extractor-and-key-generation)
7. [Cryptography and authentication](#7-cryptography-and-authentication)
8. [Logic minimisation: ESPRESSO and BDD](#8-logic-minimisation-espresso-and-bdd)
9. [Hand HLS (high-level synthesis)](#9-hand-hls-high-level-synthesis)
10. [FSM, lock and formal verification (CTL)](#10-fsm-lock-and-formal-verification-ctl)
11. [SoC and RV32 processor](#11-soc-and-rv32-processor)
12. [FPGA, Vivado and verification terms](#12-fpga-vivado-and-verification-terms)
13. [Research-improvement terms](#13-research-improvement-terms)
14. [Quick cheat sheet](#14-quick-cheat-sheet)

---

## 0. The big picture in one page

1. **The chip has a fingerprint.** No two FPGAs are manufactured exactly alike. Tiny random differences make identical ring oscillators run at slightly different speeds.
2. **We read the fingerprint.** We compare pairs of oscillators: "Is A faster than B?" Each answer is one bit, and 128 comparisons give a **128-bit response**.
3. **The fingerprint is smudgy.** Read it again and a few bits flip, because of noise and temperature. A cryptographic key must be **exactly** the same every time.
4. **The fuzzy extractor fixes the smudges.** At **enrolment** we store public **helper data**. Later, at **reconstruction**, the helper data plus **error-correcting codes** (repetition + BCH) turn the noisy reading back into the exact original.
5. **The key is derived and used internally.** The corrected response is hashed into a 128-bit **key**. The key never leaves the chip. It is only used to compute a **MAC tag** that answers a challenge.
6. **Proof it works.** The enrolled board answers challenges correctly. A different board, even with the same helper data, fails.

---

## 1. PUF basics

**PUF (Physically Unclonable Function)**
A circuit that produces a chip-unique answer because of random manufacturing variation. It works like a fingerprint for silicon. Nobody, not even the manufacturer, can make two chips with the same PUF output.
*Project:* the whole project. Our PUF is built from ring oscillators.

**Process variation**
Microscopic, random differences between transistors and wires, such as slightly different thickness or doping, that happen during manufacturing. This randomness is the source of a PUF's uniqueness.

**Ring oscillator (RO)**
A loop of an odd number of inverters. The signal keeps chasing its own tail, so the output toggles 0→1→0 forever. Its frequency depends on the delay of the gates and wires, so process variation makes every RO a little faster or slower.
*Project:* 256 ROs. Each is 1 NAND (an on/off enable) plus 2 inverters, which gives 3 inversions.

**Challenge and response**
- *Challenge:* the question you ask the PUF, here "which RO pair?".
- *Response:* the answer, here "which one is faster?".

The full set of 128 answers is the **response word**.

**CRP (challenge–response pair)**
One challenge together with its recorded answer. In authentication, the verifier stores CRPs at enrolment and checks them later.

**Pairwise comparison**
Run two ROs at the same time, count their oscillations for a fixed time, and output 1 if the first counted more and 0 otherwise.
*Project:* response bit i = 1 if count(RO 2i) > count(RO 2i+1). Ties give 0.

**Counter / measurement window (gate time)**
A counter clocked by the RO counts its edges while a timer, running from the board's 125 MHz clock, keeps a "gate" open for a fixed time, for example 2¹⁶ cycles ≈ 0.52 ms. More counts means a faster RO.

**Enrolment**
The one-time "registration" of a chip: read the PUF, generate the helper data and key, and store the helper data.

**Reconstruction**
Every later use: read the PUF again (noisy), combine it with the helper data, correct the errors, and get back the same key.

**Bit error / bit flip**
A response bit that comes out different from the enrolled one on a re-read. It happens when two ROs in a pair have almost the same speed, so noise or temperature can swap which one wins.

**BER (bit-error rate)**
The fraction of response bits that flip between reads. For example, BER = 2% means about 2–3 of 128 bits are wrong per read. It's the single most important number for choosing the error correction.

---

## 2. Measuring PUF quality

**Hamming distance (HD)**
The number of positions where two bit strings differ. `10110` and `10011` differ in 2 positions, so HD = 2. *Fractional HD* divides by the length: 2/5 = 40%.

**Hamming weight**
The number of 1s in a bit string. `10110` has weight 3.

**Intra-chip HD**
The HD between two readings of the **same** chip. It measures noise, so it should be close to 0%.

**Inter-chip HD**
The HD between responses of **different** chips. It measures how different chips are, and ideally it is 50%, like comparing two random coin-flip sequences.

**Uniqueness**
The average inter-chip HD over all pairs of boards. Target ≈ 50%.
*Project deliverable:* measured on at least 3 lab boards.

**Reliability**
How stable one chip's response is: 100% − average intra-chip HD. Target close to 100%.
*Project deliverable:* at least 100 reads, plus a warm-board test.

**Uniformity**
The fraction of 1s in one response. Ideal is 50%, meaning no bias towards 0 or 1.

**Bit-aliasing**
For each bit position, the fraction of boards on which that bit is 1. Ideally about 50% for every position. If bit 17 is 1 on *every* board, it is caused by the layout (wiring), not by the chip, so it is predictable and useless as a secret.

**Warm-board test**
Re-measure the PUF while the chip is hotter (using a hair dryer or an on-chip "heater" circuit) to see how many bits flip with temperature. The die temperature is read with the Zynq's **XADC** sensor.

**Key-failure rate (before and after ECC)**
- *Before ECC:* the fraction of reads where the raw 128-bit response is not exactly the enrolled one. This is nearly always 100%, because just one flipped bit counts as a failure.
- *After ECC:* the fraction of reconstructions where the final key is wrong or invalid. It should be tiny, for example below 1 in a million.

**Entropy**
A measure of unpredictability, in bits. 128 truly random bits have 128 bits of entropy. A 128-bit string that an attacker can partly guess has less. A key is only as strong as its entropy.

**BSC (binary symmetric channel)**
The simplest noise model: every bit flips independently with probability p.
*Project:* `noise.bsc()` in the golden model.

**Monte Carlo simulation**
Estimating a probability by simply trying many times. For example, simulate 50,000 noisy reconstructions and count the failures.

**Analytic (binomial) estimate**
Computing the same probability with a formula instead of simulation. "Probability of at least 3 errors among 15 bits" is a binomial calculation. We use it to check the Monte Carlo results and to reach very small probabilities that simulation can't measure.

---

## 3. Error-correcting codes (ECC)

**ECC (error-correcting code)**
A way of adding carefully chosen extra bits (redundancy) to data so that if some bits get corrupted, the original can still be recovered.
*Analogy:* spelling your name on the phone as "A for Apple, N for Nancy…". The extra words let the listener fix a misheard letter.

**Message (data bits)**
The original bits you want to protect. In BCH(15,7), the message is 7 bits.

**Codeword**
The message plus the redundancy bits: the protected, encoded version. In BCH(15,7), it is 15 bits. Only a small set of 15-bit strings are valid codewords: 2⁷ = 128 of the 32,768 possible.

**Parity bits / redundancy**
The extra bits added by the encoder. In BCH(15,7), 15 − 7 = 8 parity bits.

**Encoder / decoder**
- *Encoder:* message → codeword (adds redundancy).
- *Decoder:* noisy codeword → corrected codeword or message (removes errors).

**(n, k, t) notation**
- *n* is the codeword length.
- *k* is the message length.
- *t* is how many bit errors per codeword can be corrected.

BCH(15,7,t=2) has 15-bit codewords and 7-bit messages, and corrects up to 2 errors per codeword.

**Code rate**
k/n, the fraction of useful bits. BCH(15,7) has rate 7/15 ≈ 0.47. Lower rate means more protection and less useful data.

**Minimum distance (d)**
The smallest Hamming distance between any two valid codewords. A code with distance d corrects t = ⌊(d − 1)/2⌋ errors.
*BCH(15,7):* d = 5, so it corrects 2 errors. With 2 errors, the received word is still closer to the original codeword than to any other.
*Analogy:* if valid codewords are cities at least 5 km apart, being 2 km off course still leaves you nearest your own city.

**Linear code**
A code where XOR-ing any two codewords gives another codeword. Both BCH and repetition codes are linear. Linearity is what makes the **code-offset** fuzzy extractor work.

**Systematic code**
A code where the original message appears unchanged inside the codeword, with the parity bits added beside it.
*Project:* bits 14..8 are the message, bits 7..0 are the parity.

**Repetition code**
The simplest code: repeat every bit r times. With r = 3, `1` becomes `111` and `0` becomes `000`.

**Majority vote (repetition decoding)**
Decode by taking whichever value appears most often among the r copies: `110` → 1, `001` → 0. With r = 3 this corrects 1 flipped copy; with r = 5 it corrects 2.

**Concatenated code (inner and outer code)**
Two codes stacked together.
- The **outer** code (BCH) is applied first.
- The **inner** code (repetition) is applied on top of it.

When decoding, the inner code goes first: the majority vote cleans up most errors, and BCH fixes what is left.
*Project:* "repetition code concatenated with BCH(15,7,2)", with repetition factor r = 1, 3 or 5.

**Decoding failure**
The decoder notices that there are too many errors and says "I can't fix this". This is safe, because we know the result is bad.

**Miscorrection**
Too many errors (3 or more) push the word closer to a *different* codeword, and the decoder confidently "fixes" it to the wrong one. This is dangerous, because the result looks fine. We catch it with the **key-check value** (Section 6).

---

## 4. Galois field GF(2⁴): the maths behind BCH

**Field**
A set of numbers where you can add, subtract, multiply and divide (except by zero), and all the usual rules hold: a·b = b·a, a·(b+c) = a·b + a·c, and so on. Real numbers form a field. So do some finite sets.

**Finite field / Galois field, GF(q)**
A field with only a finite number of elements. It is named after Évariste Galois. Computers like them because every value fits in a fixed number of bits and arithmetic never overflows.

**GF(2)**
The smallest field: just {0, 1}.
- Addition is XOR: 1 + 1 = 0.
- Multiplication is AND.
- Subtraction is the same as addition.

**GF(2⁴), also written GF(16)**
A field with 16 elements. Each element is a **4-bit value** (0–15), thought of as a polynomial with 0/1 coefficients. For example, `1011` means x³ + x + 1.
*Project:* every syndrome and error-locator value in the BCH decoder is a GF(2⁴) element (4 bits).

**Addition in GF(2⁴)**
Bitwise XOR, with no carries: `0110 + 0011 = 0101`. Every element is its own negative (a + a = 0), so subtraction is also XOR. In hardware this is very cheap: 4 XOR gates.

**Primitive (irreducible) polynomial**
The "modulus" used to keep multiplication results within 4 bits. Ours is **p(x) = x⁴ + x + 1**, written `10011`. It plays the same role as "mod 7" in clock arithmetic.

**Multiplication in GF(2⁴)**
Multiply the two polynomials (using XOR instead of addition), then reduce the result modulo p(x).
- *Example without reduction:* `0110 × 0011` = (x² + x)(x + 1) = x³ + x² + x² + x = x³ + x = `1010`.
- *Example with reduction:* `1000 × 0100` = x³ · x² = x⁵. Since x⁴ = x + 1 in this field, x⁵ = x · x⁴ = x(x + 1) = x² + x = `0110`.

*Project:* `gf16.mul()`. In hardware it is a small AND/XOR network, and it is the block we build with ESPRESSO.

**α (alpha), the primitive element**
A special element, α = `0010` (the polynomial x), whose powers α⁰, α¹, …, α¹⁴ produce **all 15 non-zero elements**. After α¹⁴ the sequence repeats (α¹⁵ = 1).

| Power | α⁰ | α¹ | α² | α³ | α⁴ | α⁵ | α⁶ | α⁷ |
|---|---|---|---|---|---|---|---|---|
| Value | 0001 | 0010 | 0100 | 1000 | 0011 | 0110 | 1100 | 1011 |

**Log / antilog (EXP/LOG) tables**
Because every non-zero element is some αⁱ, we can multiply by adding exponents: αⁱ · αʲ = α⁽ⁱ⁺ʲ⁾ ᵐᵒᵈ ¹⁵. This is just like ordinary logarithms turning multiplication into addition.
*Project:* used in the golden model to double-check the bitwise multiplier.

**Inverse (a⁻¹)**
The element that multiplies with a to give 1. For example, the inverse of `0010` (α) is `1001` (α¹⁴), because α · α¹⁴ = α¹⁵ = 1. Zero has no inverse; by our hardware convention inv(0) = 0. Dividing by a means multiplying by a⁻¹.

**Squaring**
In GF(2⁴), squaring is a *linear* operation: it needs only XOR gates, with no AND gates. This is a useful hardware shortcut.

**Polynomial over GF(2)**
A polynomial whose coefficients are 0 or 1. A 15-bit word can be seen as a polynomial: bit i is the coefficient of xⁱ. BCH treats codewords this way.

**Root of a polynomial**
A value that makes the polynomial equal to zero. BCH codewords are designed so that α, α², α³ and α⁴ are roots. Errors break this, and that is how they are detected.

**Minimal polynomial**
The smallest polynomial over GF(2) that has a given element as a root. For α it is x⁴ + x + 1; for α³ it is x⁴ + x³ + x² + x + 1. Multiplying these two gives our BCH generator polynomial.

---

## 5. BCH encoding and decoding, step by step

**BCH code**
A family of powerful error-correcting codes (named after Bose, Chaudhuri and Hocquenghem) built on Galois-field maths. You can choose how many errors to correct. Ours is **BCH(15,7,2)**: 7 message bits, 15 codeword bits, corrects 2 errors.

**Generator polynomial g(x)**
The polynomial that defines the code. Every codeword is a multiple of it.
Ours: **g(x) = x⁸ + x⁷ + x⁶ + x⁴ + 1**, which equals (x⁴ + x + 1)(x⁴ + x³ + x² + x + 1).

**BCH encoding (systematic)**
1. Take the 7-bit message m(x) and shift it up by 8 positions: m(x)·x⁸.
2. Divide by g(x) and keep the 8-bit remainder. This is the parity.
3. Codeword = message bits followed by parity bits.

The result is divisible by g(x), so it is a valid codeword. In hardware this is a small XOR network or LFSR.

**Received word**
What arrives at the decoder: the codeword plus possible bit errors.

**Syndrome (S₁, S₃)**
A "symptom" value computed from the received word: plug α (for S₁) or α³ (for S₃) into the received polynomial.
- **All syndromes are zero:** no errors detected.
- **Non-zero syndromes:** something is wrong, and the values encode where the errors are.

*Analogy:* a doctor's test results. Normal results mean healthy, and abnormal values hint at what is wrong.
*Shortcut:* we only compute S₁ and S₃, because S₂ = S₁² and S₄ = S₁⁴ come for free in binary BCH. In hardware the syndromes are pure XOR networks.

**Error-locator polynomial Λ(x) ("lambda")**
A polynomial whose roots reveal the positions of the errors: Λ(x) = 1 + Λ₁x + Λ₂x². If errors are at positions i and j, then α⁻ⁱ and α⁻ʲ are its roots.

**Peterson algorithm (Peterson's error locator)**
A direct formula that computes Λ₁ and Λ₂ from the syndromes. It works well for small t, like our t = 2:
- **Λ₁ = S₁**
- **Λ₂ = S₃ · S₁⁻¹ + S₁²**. This is the same as (S₃ + S₁³)/S₁, rewritten so the two multiplications can run at the same time.

It also handles three special cases:
- S₁ = 0 and S₃ = 0: no errors.
- S₁ = 0 and S₃ ≠ 0: too many errors, so decoding fails.
- Λ₂ = 0: exactly one error.

*Project:* this is the part we turn into hardware with "hand HLS", using 1 or 2 GF multipliers.

**Chien search**
Finding Λ(x)'s roots by brute force: try each of the 15 positions i, compute Λ(α⁻ⁱ), and if it equals 0, bit i is wrong, so flip it. It is named after R. T. Chien.
*Hardware:* 15 evaluations, each needing 2 GF multiplications. With 1 multiplier that takes about 30 cycles; with 2 multipliers about 15.

**Error mask**
A 15-bit word with 1s at the erroneous positions. Corrected word = received XOR error mask.

**Decoder success check**
If Λ has degree 2 (claims 2 errors) but the Chien search finds only 0 or 1 roots, the error pattern was beyond the code's power, so decoding fails (`ok = 0`).

---

## 6. Fuzzy extractor and key generation

**Fuzzy extractor**
A method that turns a **noisy, non-uniform** secret, such as a PUF response or a fingerprint scan, into a **stable, exact** cryptographic key. It has two parts:
- **Gen (enrolment):** response → key + helper data
- **Rep (reconstruction):** noisy response + helper data → same key

**Secure sketch**
The error-correction half of a fuzzy extractor: the part that recovers the exact original response from a noisy one using helper data.

**Code-offset construction**
The specific fuzzy-extractor method we use:
- **Enrol:** pick a random codeword c and store **helper h = w ⊕ c**, where w is the PUF response.
- **Reconstruct:** compute w′ ⊕ h = c ⊕ (noise). This is a codeword with a few errors, so decode it to get c back, then compute w = c ⊕ h.

*Analogy:* the helper data is like a stencil. On its own it reveals little, but laid over a close-enough fingerprint it guides you back to the exact original.

**Helper data**
The public data stored at enrolment: the offset h plus the key-check value. It is not secret and can sit in ordinary memory. Without the chip's own PUF it is useless.
*Project:* stored in SoC memory and exported to the PC at enrolment.

**Helper-data leakage**
Helper data reveals *some* information about w: up to n − k bits per BCH block, 8 bits per block in our case. This reduces the key's real entropy. This is why bigger r leaves less entropy (Section 5.1 of the model README).

**Residual entropy**
The secret entropy left after accounting for helper-data leakage. For our 128-bit response it is about 56 bits with r = 1, 14 bits with r = 3 and 7 bits with r = 5, assuming fully random response bits.

**Repetition factor r**
How many times each BCH codeword bit is repeated: 1, 3 or 5. Larger r tolerates more noise but uses more response bits and leaves less entropy.
*Project:* chosen after measuring the real BER.

**Used bits**
The response bits actually protected by the code: 120 for r = 1, 90 for r = 3, 75 for r = 5. The remaining bits are ignored.

**KDF (key-derivation function)**
A function that turns the corrected response into a uniform-looking key, like a blender that mixes input bits so that every key bit depends on all of them.
*Project:* K = SipHash with a fixed public key, run twice to get 128 bits.

**Privacy amplification**
The general idea behind the KDF: compress a partly predictable secret into a shorter but more uniform key.

**KCV (key-check value)**
A short (32-bit) public fingerprint of the key, stored with the helper data. After reconstruction, the hardware recomputes it. If it matches, the key is correct and `key_valid = 1`. It catches BCH **miscorrections**.

**key_valid**
The hardware flag that says the reconstructed key is correct and usable. It is asserted only after the ECC succeeds and the KCV matches. If it is 0, the key is held at zero.

---

## 7. Cryptography and authentication

**Cryptographic key**
A secret number (128 bits for us) that controls a cryptographic operation. Whoever knows it can produce valid tags.

**MAC (message authentication code) / keyed MAC**
A short tag computed from a message *and* a secret key. Without the key you cannot compute the right tag. It proves "I have the key" without revealing it.

**Tag**
The output of a MAC. Ours is 64 bits.

**SipHash-2-4**
A fast, compact keyed hash/MAC with a 128-bit key and 64-bit output. "2-4" means 2 mixing rounds per message block and 4 finalisation rounds. It was designed by Aumasson and Bernstein (2012).
*Project:* used for the MAC, the KDF and the KCV. It is small in hardware.

**ARX (Add–Rotate–XOR)**
The style of operations SipHash uses: 64-bit additions, bit rotations and XORs. These are simple and hardware-friendly.

**Challenge–response authentication**
The verifier (PC) sends a random challenge, and the device replies with MAC(key, challenge). If the reply matches the expected value, the device is genuine. A fresh challenge each time stops replay attacks.

**Nonce**
"Number used once": a challenge value that is never reused.

**Verifier**
The party checking authenticity. Here it is a Python program on the PC.

**Key isolation ("never readable over the bus")**
The key register is not connected to anything the processor can read. Software can ask for a MAC but can never see the key itself.

**Zeroisation**
Clearing the key to all zeros when it is no longer valid, for example on failure or reset.

**Replay attack**
Recording a valid answer and sending it again later. It is defeated by never reusing challenges.

---

## 8. Logic minimisation: ESPRESSO and BDD

**Truth table**
A table listing the output for every possible input combination. The GF(2⁴) multiplier has 8 inputs (a and b), so 2⁸ = 256 rows and 4 outputs.

**SOP (sum of products)**
Writing logic as an OR of AND terms, for example y = a·b + a′·c. It is also called "two-level logic".

**Product term / cube**
One AND term of an SOP expression, for example a·b′·c.

**Two-level logic minimisation**
Finding an SOP with as few (and as small) product terms as possible that still matches the truth table. This saves gates.

**Karnaugh map (K-map)**
The pen-and-paper way to minimise logic for up to about 4–5 inputs. ESPRESSO does the same job automatically for larger functions.

**PLA file**
The text format ESPRESSO reads and writes. It lists inputs, outputs and truth-table rows (`.i`, `.o`, `.p`, `.e` lines).
*Project:* `model/vectors/espresso/gf_mul.pla` and `gf_inv.pla`.

**ESPRESSO**
A classic logic-minimisation program from UC Berkeley. It reads a truth table (PLA) and outputs a near-minimal SOP. We use it to build the GF(2⁴) multiplier and inverse, then turn its output into Verilog.

**Don't-care**
An input combination whose output doesn't matter, marked `-`. ESPRESSO can use these to simplify further. We don't use them, because we define inv(0) = 0.

**BDD (binary decision diagram)**
A graph that represents a Boolean function as a chain of yes/no decisions on each input variable, with identical sub-graphs merged. It is like a flowchart: "Is a3 = 1? Then check b0…".

**ROBDD (reduced ordered BDD)**
A BDD with a fixed variable order and all redundancy removed. Its key property is that it is **canonical**: two functions are equal exactly when their ROBDDs are identical.

**Variable ordering**
The order in which variables are tested in a BDD. A good order can make the BDD tiny and a bad one huge. Comparing orderings is part of our analysis.

**Equivalence checking**
Proving that two circuits compute the same function, for example ESPRESSO's minimised logic and the reference multiplier. With BDDs: build both and check that they are the same graph.

**Mastrovito multiplier**
A standard GF(2ⁿ) multiplier structure, written as a matrix of AND/XOR operations. We compare it with the ESPRESSO version, because XOR-heavy functions are often awkward in SOP form but map well onto FPGA LUTs.

---

## 9. Hand HLS (high-level synthesis)

**HLS (high-level synthesis)**
Automatically turning an algorithm, written like software, into a hardware circuit of datapath plus controller. Tools such as Vitis HLS do this.

**Hand HLS**
Doing the same steps **manually**: drawing the data-flow graph, scheduling operations into clock cycles, deciding how many hardware units to use, and writing the resulting RTL yourself.
*Project:* applied to the BCH syndrome and Peterson decoder.

**DFG (data-flow graph)**
A diagram of the computation. Nodes are operations (GF multiply, XOR, inverse) and arrows show which results feed which operations.

**Scheduling**
Deciding *in which clock cycle* each operation runs, while respecting dependencies (you can't use a result before it is computed).
- **ASAP (as soon as possible):** run every operation as early as its inputs allow.
- **ALAP (as late as possible):** run every operation as late as the deadline allows.
- **List scheduling:** schedule cycle by cycle while respecting a limit on hardware units (for example, only 1 multiplier).

**Allocation**
Deciding *how many* of each hardware unit to build, for example 1 vs. 2 GF multipliers.

**Binding**
Deciding *which* physical unit runs each operation, for example "multiply #3 runs on multiplier B in cycle 2".

**Register allocation**
Deciding where intermediate values are stored between cycles, using as few registers as possible.

**Datapath and controller**
- *Datapath:* the units, muxes and registers that do the computation.
- *Controller:* a small FSM that steers the muxes and enables each cycle.

**Latency**
How many clock cycles the computation takes.

**Area–latency trade-off**
More hardware (2 multipliers) means fewer cycles but more LUTs. Less hardware (1 multiplier) means more cycles but fewer LUTs. Our deliverable compares the two.

**Resource sharing**
Reusing one unit for several operations in different cycles. This is what makes the 1-multiplier design small.

---

## 10. FSM, lock and formal verification (CTL)

**FSM (finite state machine)**
A circuit that moves between a fixed set of states (IDLE, MEASURE, ENROL, …) according to inputs and rules.

**Sequencer FSM**
Our controller FSM. It runs the steps of measure → enrol, or measure → reconstruct → key check → key valid or fail, in the right order.

**Enrolment lock (one-time lock)**
After enrolment, a lock bit is set, and from then on any new enrolment command is refused. This stops an attacker from re-enrolling the chip with helper data of their choice.

**Sticky bit**
A register bit that, once set to 1, stays 1 until reset. Our lock is a sticky bit.

**eFUSE**
Real one-time-programmable fuses inside the Zynq. Programming them is **permanent**, so we do not use them on shared lab boards; we emulate the lock instead.

**Formal verification**
*Proving* mathematically that a design always satisfies a property, for every possible input sequence. Simulation can only check the cases you happen to test.

**Model checking**
An automatic formal method. The tool explores every reachable state of the FSM and checks each property. If a property fails, it shows a **counterexample** (a step-by-step trace to the bug).

**CTL (computation tree logic)**
A language for stating properties about how a system behaves over time, considering all possible futures as a tree of paths.

| Operator | Meaning |
|---|---|
| **A** | on **A**ll paths (whatever happens) |
| **E** | there **E**xists a path (something *can* happen) |
| **G** | **G**lobally (always, at every step) |
| **F** | **F**uture (eventually, at some step) |
| **X** | ne**X**t step |

**AG p** means "p is always true, no matter what". **AF p** means "p will eventually happen, no matter what". **EF p** means "p can possibly happen".

*Our required properties:*
- `AG (key_valid → ecc_ok)`: the key is only ever valid after ECC succeeded.
- `AG (locked → AG ¬enrol)`: once locked, enrolment never happens again.

**Safety property**
"Something bad never happens", for example enrolment after lock. These are written with AG.

**Liveness property**
"Something good eventually happens", for example a started operation eventually finishes. These are written with AF.

**Fairness**
An assumption that rules out unrealistic paths (for example, "the clock keeps running"), so that liveness can be proven.

**Counterexample**
The trace a model checker produces when a property fails. It shows exactly how to reach the bug.

**Mutant (bug injection)**
A deliberately broken copy of the design, for example "allow enrolment when locked". The checker should catch it, which proves the properties actually test something.

**NuSMV / nuXmv**
Model-checking tools that understand CTL directly. We describe the FSM in their language (SMV) and check the properties.

**SVA (SystemVerilog Assertions)**
Properties written inside the RTL (`assert property (...)`) and checked in simulation or by formal tools. This is an optional addition.

**SymbiYosys (SBY)**
An open-source formal-verification front end that can prove SVA properties directly on the Verilog. Optional.

---

## 11. SoC and RV32 processor

**SoC (system on chip)**
A complete small computer on one chip: processor, memory, peripherals and the bus connecting them.

**RISC-V / RV32**
An open processor instruction set. RV32 means the 32-bit version. "RV32IMC" adds integer multiply/divide (M) and compressed instructions (C).

**Soft core**
A processor built from FPGA logic rather than fixed silicon.

**PicoRV32**
A small, popular open-source RV32 soft core that we plan to use.

**Firmware**
The C program running on the RV32 core: our enrolment and authentication program.

**Bus**
The shared set of wires that the processor uses to read and write memory and peripherals.

**Memory-mapped peripheral**
A hardware block that the processor talks to by reading and writing particular addresses, as if it were memory.
*Project:* the PUF/MAC peripheral.

**Register map**
The list of a peripheral's addresses and what each one does (CTRL, STATUS, HELPER, CHAL, TAG, …).

**BRAM (block RAM)**
Dedicated memory blocks inside the FPGA. They hold the firmware and the helper data.

**UART**
A simple serial link (TX/RX wires) used to talk to the PC terminal or Python script.

**Pmod**
Digilent's small plug-in expansion connectors on the Zybo. A Pmod USB-UART module gives the FPGA logic its own serial port.

**PS / PL (Zynq)**
- *PS (processing system):* the hard ARM cores and their peripherals.
- *PL (programmable logic):* the FPGA fabric.

The Zybo's built-in USB-UART is wired to the PS only, which is why we need a Pmod or a PS bridge.

**AXI**
ARM's standard on-chip bus protocol, used between the PS and PL.

---

## 12. FPGA, Vivado and verification terms

**Zybo Z7-10 / Zynq-7010**
Our board and its chip (Vivado part `xc7z010clg400-1`).

**LUT (look-up table)**
The basic logic element of the FPGA. A small memory that can implement any function of up to 6 inputs. Each RO stage is one LUT.

**Slice / CLB**
Groups of LUTs and flip-flops. In 7-series FPGAs a slice has 4 LUTs, so one RO fits in one slice.

**RTL (register-transfer level)**
Hardware described in Verilog/VHDL as registers plus the logic between them.

**Synthesis / implementation / bitstream**
- *Synthesis:* turn RTL into a netlist of LUTs and flip-flops.
- *Implementation (place and route):* choose physical locations and wires.
- *Bitstream:* the final file that is programmed into the FPGA.

**XDC (Xilinx design constraints)**
The file of pin assignments, clock definitions and placement constraints.

**Pblock**
A rectangular region of the FPGA reserved for a group of logic. It keeps all ROs together in one controlled area.

**LOC / BEL constraints**
- **LOC:** place a cell in an exact slice.
- **BEL:** place it in an exact LUT within that slice.

These give every RO identical placement, which keeps the comparison fair.

**DONT_TOUCH / KEEP**
Attributes that stop Vivado from optimising away or merging logic. Without them, Vivado would delete the "useless-looking" RO loops.

**Combinational loop**
A logic loop with no flip-flop in it. Normally this is a bug, but for an RO it is the whole point. Vivado must be told it is allowed (`ALLOW_COMBINATORIAL_LOOPS`).

**Clock domain / CDC (clock-domain crossing)**
Signals moving between parts clocked by different clocks, such as the RO counters and the 125 MHz system clock. They must be handled carefully. We stop the counters first and then read them.

**Metastability**
An unstable in-between state of a flip-flop when its input changes right at the clock edge. Safe CDC design avoids it.

**Golden model**
The trusted reference implementation (our Python model in `model/`). The hardware must match it bit for bit.

**Test vector**
One set of inputs with the expected outputs, used to check a design automatically.

**.mem file / $readmemh**
A text file of hex values, one per line, and the Verilog system task that loads such a file into a memory array in a testbench.
*Project:* `model/vectors/*.mem`.

**Testbench (self-checking)**
Verilog code that drives a design under test and compares its outputs with expected values automatically, reporting PASS or FAIL.

**Exhaustive testing**
Testing every possible input. This is feasible here: 256 cases for the GF multiplier, and all 15,488 single and double error patterns for BCH.

**Resource utilisation**
How many LUTs, flip-flops and BRAMs a design uses. It is reported by Vivado and compared between designs.

**f_max / timing**
The highest clock frequency a design can run at, as reported by Vivado's timing analysis.

---

## 13. Research-improvement terms

**Configurable RO (Maiti and Schaumont, 2011)**
Each RO stage can choose between two different LUT paths. At enrolment, the configuration that makes the two ROs in a pair *most different* is chosen and stored. This reduces bit flips. It is our recommended improvement.

**1-out-of-k masking (Suh and Devadas, 2007)**
From each group of k ROs, use only the pair with the biggest frequency gap. This is very reliable, but it produces fewer bits.

**Temperature compensation**
Techniques that pick or adjust RO pairs so that heating affects both ROs equally, so the comparison result stays the same.

**Entropy distiller**
Post-processing that removes systematic bias (such as layout gradients) from the RO frequencies before comparison, improving uniqueness and bit-aliasing.

**Reliability-aware helper data**
Helper data that also records *which* bits or configurations are reliable, so reconstruction relies mostly on stable bits.

**Baseline vs. improved PUF**
We measure our plain RO-PUF (the baseline), then the improved version, on the same boards with the same tests, and compare uniqueness, reliability and bit-aliasing.

---

## 14. Quick cheat sheet

| Term | One-line meaning |
|---|---|
| PUF | Chip fingerprint from manufacturing randomness |
| RO | Inverter loop whose frequency is slightly unique per chip |
| Response | 128 bits from comparing 128 RO pairs |
| BER | Fraction of bits that flip between reads |
| Intra-HD / reliability | Same chip read twice: should differ ≈ 0% |
| Inter-HD / uniqueness | Two different chips: should differ ≈ 50% |
| Bit-aliasing | Is a bit position biased the same way on every chip? Want 50% |
| ECC | Extra bits that let you fix errors |
| Repetition code | Repeat each bit r times and take a majority vote |
| BCH(15,7,2) | 7 data bits → 15-bit codeword, fixes 2 errors |
| GF(2⁴) | 16-element number system on 4-bit values. Add = XOR, multiply = polynomial mod x⁴+x+1 |
| α | Generator element. Its powers give all 15 non-zero values |
| Syndrome | "Symptom" of errors. Zero means no error detected |
| Peterson | Formula that gives the error-locator polynomial from the syndromes |
| Chien search | Try all 15 positions to find where the errors are |
| Miscorrection | Decoder "fixes" to the wrong codeword (caught by the KCV) |
| Fuzzy extractor | Noisy PUF response → exact stable key |
| Code-offset | Helper = response XOR random codeword |
| Helper data | Public data needed to reconstruct the key |
| KDF | Hashes the corrected response into a 128-bit key |
| KCV | Public check value that confirms the key is right |
| MAC / SipHash | Keyed tag that proves you have the key without revealing it |
| ESPRESSO | Tool that minimises truth tables into small SOP logic |
| BDD | Graph form of a Boolean function, used to prove equivalence |
| Hand HLS | Manually scheduling an algorithm onto limited hardware units |
| FSM / sequencer | Controller that runs enrol and reconstruct in order |
| CTL (AG, AF, EF) | Logic for "always", "eventually" and "possibly" properties |
| Model checking | Automatic proof of properties over all FSM states |
| Pblock / LOC | Constraints that fix where the ROs are placed |
| Golden model | Trusted Python reference the RTL must match |
| .mem / $readmemh | Test-vector file and the Verilog command that loads it |
