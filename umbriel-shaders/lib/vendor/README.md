# tinytoml

Source: https://github.com/FourierTransformer/tinytoml

Revision: `5517aa5d398ae0c992799decc460ec253a62552a`

License: MIT; see `LICENSE.tinytoml`.

`tinytoml.luau` is the upstream `tinytoml.lua`, renamed for Noctalia's module
loader. The local adaptation adds an optional `checkpoint` callback to parsing,
UTF-8 validation, and long quoted-string scanning, allowing the plugin to yield
between chunks of work. The application uses string input only; filesystem access
is handled through Noctalia. No contribution code is imported from shader sources.
