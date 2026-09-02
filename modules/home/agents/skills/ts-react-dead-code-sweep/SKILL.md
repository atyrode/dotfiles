---
name: ts-react-dead-code-sweep
description: Safely remove orphaned TypeScript, React, CSS, and stale test contracts after a feature deletion using reachability analysis and explicit liveness checks.
---

# TypeScript and React dead-code sweep

Use this workflow after removing a feature from a TypeScript or React application. Import-graph results identify candidates; they never prove that a file is dead.

## 1. Find module candidates

Build an import graph for production TypeScript and TSX files, resolve relative paths and index modules, then walk from the real application entry points. Treat unreachable files as candidates because static scans can miss dynamic imports, path aliases, and test-only consumers.

## 2. Adjudicate every candidate

Search production code and tests for every candidate basename and classify each reference:

- Dead code importing dead code can be removed together.
- A test-only consumer requires deciding whether the contract remains useful.
- Any live consumer means the candidate stays and the graph assumption must be corrected.

Remove confirmed files with the repository's version-control command, then run the narrowest typecheck that proves no imports dangle.

## 3. Prove CSS liveness separately

Extract class tokens per stylesheet and compare them with live code, but do not treat a substring match as proof. Check where a token appears and whether its selector root remains live. Dynamic class construction and third-party runtime classes invalidate simple scans; preserve those files unless their use can be traced confidently.

Delete a whole stylesheet only when every selector root is dead. Move still-live keyframes, loading states, reduced-motion rules, or shared utilities before removing their old file, then update the central stylesheet imports.

## 4. Retarget contracts

Tests and policy checks that name deleted paths should be retargeted to the live replacement when the underlying contract still matters. Do not delete a boundary test merely because one implementation disappeared. Document intentionally empty consumer lists or equivalent exceptions.

## 5. Bound uncertain work

Defer areas that static analysis cannot prove safely, such as dynamically assembled translation keys. Documentation counts as a callsite; update architecture and design references to deleted modules.

## 6. Verify

Run the repository's full typecheck, unit tests, lint, and browser projects when available. Summarize the method, files deliberately retained, and deferred candidates with reasons.
