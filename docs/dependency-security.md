# Dependency security findings

Recorded: 2026-10-11. This is the disposition record for `bun audit` findings
against the host's locked dependencies. Rerun the audit when dependencies change
and update this record; an older result is not current evidence.

```sh
bun install --cwd host --frozen-lockfile
(cd host && bun audit)
```

Audit run: Bun 1.4.2 (`744846f84`) on macOS 27.0.1 arm64, from `host/`.
`bun audit` exits 1 while any finding remains, including the two exceptions below.
Any finding not listed here is new and needs triage.

## What ships

Only the Excalidraw editor bundle reaches users. `host/build-editor.ts` bundles
`editor-bootstrap.ts` for the browser, and the compiled `portal-host` embeds
those files. The server imports no npm packages. Markdown previews use Bun's
built-in `Bun.markdown`, not a dependency.

A package counts as shipped when its files are inputs to that bundle. Find them
with the same `Bun.build` options plus `metafile: true`, then list the inputs
under `node_modules/`. An installed package that is not an input is not shipped.

Some packages compile other packages into their own files. Neither `bun audit`
nor the bundle inputs show that code. The `embeds` entries in
`licenses/inventory.json` list it, as its source maps name it (see
[licenses](licenses.md)). Check those versions against the GitHub Advisory
Database as well.

Excalidraw's paste handler converts text that starts with a Mermaid diagram
keyword through `@excalidraw/mermaid-to-excalidraw`. Pasted Mermaid text is the
untrusted input that reaches Mermaid, DOMPurify and KaTeX.

## Findings

Before is the lockfile at `406fc7d`; after is this record's lockfile.

| Package | Before → after | Shipped | Disposition |
| --- | --- | --- | --- |
| `dompurify` | 3.4.15 → 3.4.16 | yes, via Mermaid | Fixed in range |
| `nanoid` | 3.3.3 and 4.0.2 → 3.3.20 | yes, both copies | Fixed by override |
| `lodash-es` | 4.18.1 and 4.17.21 → 4.18.1 | 4.18.1 only as a package | Fixed by override |
| `source-map-js` | 1.2.1 → 1.2.2 | no | Fixed in range |
| `katex` | 0.16.47 (unchanged) | yes, via Mermaid | Exception |
| `braces` | 3.0.3 (unchanged) | no | Exception, no patched release |
| `lodash-es`, compiled in | 4.17.23 in `@mermaid-js/parser` 1.2.1 | yes | Affected functions absent |
| `js-yaml`, compiled in | 4.3.0 in `mermaid` 11.17.2 | yes | Affected types not enabled |

### `dompurify`

Path: `@excalidraw/excalidraw` → `@excalidraw/mermaid-to-excalidraw` →
`mermaid` → `dompurify`. Advisories:
[GHSA-p98j-92pf-mc4p](https://github.com/advisories/GHSA-p98j-92pf-mc4p) and
[GHSA-6688-9rhm-gjv2](https://github.com/advisories/GHSA-6688-9rhm-gjv2),
both low and fixed in [3.4.16](https://github.com/cure53/DOMPurify/releases/tag/3.4.16).
Both need `IN_PLACE` sanitization; Mermaid 11.17.2 sanitizes strings and never
passes `IN_PLACE`. Mermaid's `^3.3.3` range already allowed the fixed release,
so only the lockfile changed.

### `nanoid`

Paths: `@excalidraw/excalidraw` pinned 3.3.3 and
`@excalidraw/mermaid-to-excalidraw` pinned 4.0.2. Advisories:
[GHSA-mwcw-c2x4-8c55](https://github.com/advisories/GHSA-mwcw-c2x4-8c55) (moderate),
[GHSA-28wg-ghj8-5hjv](https://github.com/advisories/GHSA-28wg-ghj8-5hjv),
[GHSA-2v37-7h3g-55p8](https://github.com/advisories/GHSA-2v37-7h3g-55p8) and
[GHSA-xwg4-73v4-xw9w](https://github.com/advisories/GHSA-xwg4-73v4-xw9w) (high).
3.3.18 fixes all four on the 3.x line; 4.x needs 5.1.16.

Each advisory needs a caller-supplied fractional, negative, zero or overflowing
size, or the `non-secure` module. The bundle uses only `index.browser.js`.
Excalidraw calls `nanoid()` and `nanoid(40)`; mermaid-to-excalidraw calls
`nanoid()`. No input reaches a size argument, so no exploit path was found.

Both pins are exact, so no in-range upgrade exists. One top-level override
serves both instead of separate scoped ones. `nanoid` 3.3.20 is the maintained 3.x
release. Its `index.browser.js` exports the same names as 3.3.3's and 4.0.2's.
Apart from whitespace, `nanoid` is unchanged. Only `customRandom`, which
`customAlphabet` uses, changed: it returns `''` for a size of 0 or less and
truncates its byte count with `step | 0`. Portal's callers use `nanoid()` and
`nanoid(40)` only, so their behavior is unchanged. The 4.0 major dropped CommonJS and old Node.js, which
this browser bundle does not use. [host/dependencies.test.ts](../host/dependencies.test.ts)
checks that the editor bundle holds this one `nanoid` beside mermaid-to-excalidraw, and
that its `nanoid()` and `nanoid(40)` make IDs of those lengths.

Remove the override when Excalidraw and mermaid-to-excalidraw depend on fixed
releases.

### `lodash-es`

Paths: `chevrotain` 11.0.3, `@chevrotain/gast` and `@chevrotain/cst-dts-gen`
pinned 4.17.21, under `@mermaid-js/parser` → `langium`. Mermaid's
`dagre-d3-es` already resolved 4.18.1. Advisories:
[GHSA-r5fr-rjxr-66jc](https://github.com/advisories/GHSA-r5fr-rjxr-66jc) (high),
[GHSA-xxjr-mmjv-4gpg](https://github.com/advisories/GHSA-xxjr-mmjv-4gpg) and
[GHSA-f23m-r3pf-42rh](https://github.com/advisories/GHSA-f23m-r3pf-42rh) (moderate),
all fixed in 4.18.0. The audit also listed 4.18.1, which is outside every
vulnerable range.

The 4.17.21 copies were installed but not shipped: no installed `chevrotain` or
`langium` file is a bundle input. The override to 4.18.1 removes them. It is a 4.x minor
release, the version already in the bundle, and the chevrotain packages are not
bundled. Remove the override when those pins move past 4.17.23.

### `source-map-js`

Path: `@excalidraw/excalidraw` → `sass` → `source-map-js`.
[GHSA-68fv-2mgg-jv7q](https://github.com/advisories/GHSA-68fv-2mgg-jv7q) (high)
is a denial of service when parsing a crafted indexed source map. Portal never
runs `sass`; see `braces`. Sass's `>=0.6.2 <2.0.0` range allowed 1.2.2, so only
the lockfile changed.

### `katex` exception

Path: `@excalidraw/excalidraw` → `@excalidraw/mermaid-to-excalidraw` →
`mermaid` → `katex`. [GHSA-238p-pmpm-9mq7](https://github.com/advisories/GHSA-238p-pmpm-9mq7)
(low) is fixed in [0.18.2](https://github.com/KaTeX/KaTeX/releases/tag/v0.18.2).

Scope: the bundled lazy chunk Mermaid loads for `$$…$$` labels. Pasted Mermaid
text can reach it. The advisory needs `Object.prototype` to be polluted
already, or attacker control of the options object. Mermaid passes a fresh
literal (`throwOnError`, `displayMode`, `output`) and sanitizes the result with
DOMPurify. No prototype-pollution source was found in the bundle. The bundled
lodash-es package is patched, and the copy compiled into `@mermaid-js/parser`
lacks the affected functions. That is no demonstrated path, not proof of safety.

Not fixed: Mermaid 11.17.2 and the latest Mermaid 12.1.0 both require
`katex ^0.16.47`. An override would cross KaTeX 0.17 and 0.18, whose release
notes list breaking changes, including prefixed CSS classes in 0.18.0.
Mermaid and DOMPurify have not been tested with those classes.

Review when Mermaid or mermaid-to-excalidraw accepts KaTeX 0.18.2 or later, when
a prototype-pollution finding appears in a shipped package, or when the advisory
changes.

### `braces` exception

Path: `@excalidraw/excalidraw` → `sass` → `chokidar` → `braces`.
[GHSA-vfj7-8cjw-p6xm](https://github.com/advisories/GHSA-vfj7-8cjw-p6xm) (high)
is stack exhaustion in Node.js from deeply nested brace patterns. No patched
release exists.

Scope: an installed but unused package. Excalidraw 0.18.1 declares `sass` as a
runtime dependency, but its `dist/prod` files never import it. No `sass`,
`chokidar` or `braces` file is a bundle input, and Portal's build uses
`Bun.build`, not Sass. Nothing in Portal runs this code.

Review when `braces` publishes a fix, when Excalidraw changes its `sass`
dependency, or when Portal's build starts using Sass or file watching.

## Compiled-in code

These copies are inside another package's files, so no override or lockfile
change can replace them. They change only when that package releases.

### `lodash-es` 4.17.23 in `@mermaid-js/parser` 1.2.1

Path: `mermaid` 11.17.2 → `@mermaid-js/parser` 1.2.1, which compiles in Langium,
Chevrotain and lodash-es 4.17.23. That version is in
[GHSA-r5fr-rjxr-66jc](https://github.com/advisories/GHSA-r5fr-rjxr-66jc) and
[GHSA-f23m-r3pf-42rh](https://github.com/advisories/GHSA-f23m-r3pf-42rh).
The package's source maps name 231 lodash-es modules, none of them `template`,
`unset`, `omit` or `_baseUnset`. The affected functions are not shipped.

Review when Mermaid updates `@mermaid-js/parser`, or when an advisory names
another lodash function.

### `js-yaml` 4.3.0 in `mermaid` 11.17.2

Mermaid compiles in js-yaml 4.3.0 and parses diagram frontmatter with it, so
pasted Mermaid text reaches it. Advisories, both high:
[GHSA-2883-xcg3-v3hh](https://github.com/advisories/GHSA-2883-xcg3-v3hh) (CPU use
through empty merge sources, fixed in 4.3.2) and
[GHSA-5p4m-2wfm-xmqj](https://github.com/advisories/GHSA-5p4m-2wfm-xmqj)
(quadratic `!!omap` resolution, fixed in 4.3.1).

Both need YAML types in js-yaml's default schema: merge keys (`<<`) and
`!!omap`. Mermaid 11.17.2's four `load` calls, frontmatter included, all pass `schema: JSON_SCHEMA`,
which has neither. Against js-yaml 4.3.0 with that schema, the advisories'
inputs did not merge `<<`, and explicit `!!merge` and `!!omap` failed as
unknown tags. With the default schema, the same `!!omap` input took 591 ms.

Review when Mermaid releases with js-yaml 4.3.2 or later, or when it loads YAML
with another schema.
