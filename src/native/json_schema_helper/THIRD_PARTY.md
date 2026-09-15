# Third-party source

The helper is built from jsoncons 1.9.0 at commit
`bcb44594c50c495ee1e690602cdd71455942ad0e`, acquired and verified using
`dependency-lock.json`. jsoncons is Copyright Daniel Parker and contributors
and distributed under the Boost Software License 1.0. The acquisition step
retains its `LICENSE` and `LICENSE_1_0.txt` files in the source-built artifact.

The bundled `schema_draft202012.hpp` provides the complete offline Draft
2020-12 meta-schema and vocabulary set used by the helper. No schema is fetched
from the network at runtime.

Minerva applies `jsoncons-integral-multiple-of.patch` to the pinned source.
The helper accepts only positive integral, safe-range `multipleOf` divisors and the
patch removes jsoncons' one-ULP tolerance for that supported subset. This
prevents adjacent floating-point values from being accepted as multiples.
