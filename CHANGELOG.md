# Changelog

## [1.9.0](https://github.com/hyprpilot/hyprpilot.nvim/compare/hyprpilot.nvim-v1.8.0...hyprpilot.nvim-v1.9.0) (2026-05-18)


### Features

* **composer:** internalize clipboard probe — drop img-clip.nvim dependency ([#109](https://github.com/hyprpilot/hyprpilot.nvim/issues/109)) ([523778a](https://github.com/hyprpilot/hyprpilot.nvim/commit/523778a2979a524e513f7312ac61810c7fa6402b))
* **profiles:** wire set_profile + palettes.profiles.swap (live profile switch) ([#110](https://github.com/hyprpilot/hyprpilot.nvim/issues/110)) ([59c6445](https://github.com/hyprpilot/hyprpilot.nvim/commit/59c64457a54b9818d5dadf66c352b6909b96611b))


### Bug Fixes

* **instances:** close pane when last instance is shut down + bell skips auto-resolved permissions ([#107](https://github.com/hyprpilot/hyprpilot.nvim/issues/107)) ([2725222](https://github.com/hyprpilot/hyprpilot.nvim/commit/272522276fed3d36597933181e44dd70cb758933))


### Refactor

* **profiles:** set() rename + ListOnly semantic + auto-chain to sessions palette ([#112](https://github.com/hyprpilot/hyprpilot.nvim/issues/112)) ([15c093f](https://github.com/hyprpilot/hyprpilot.nvim/commit/15c093f50050d10edf6e19d372c8e5cafdf5f4f6))

## [1.8.0](https://github.com/hyprpilot/hyprpilot.nvim/compare/hyprpilot.nvim-v1.7.0...hyprpilot.nvim-v1.8.0) (2026-05-17)


### Features

* **instances:** keep-alive toggle + spacing collapse + plan body-only ([#103](https://github.com/hyprpilot/hyprpilot.nvim/issues/103)) ([49af2f7](https://github.com/hyprpilot/hyprpilot.nvim/commit/49af2f7ca067d94d14b81b815c8a4111910631d5))


### Bug Fixes

* **instances:** keep-alive toggle reports auto-shutdown status unambiguously ([#106](https://github.com/hyprpilot/hyprpilot.nvim/issues/106)) ([2e235d5](https://github.com/hyprpilot/hyprpilot.nvim/commit/2e235d5bc291681803bd1030c002b0f8a353dd09))


### Refactor

* **render:** drop collapse_blank_runs — write daemon chunks verbatim, skip blank-only ([#105](https://github.com/hyprpilot/hyprpilot.nvim/issues/105)) ([391f2ce](https://github.com/hyprpilot/hyprpilot.nvim/commit/391f2ce15f7c39617f1cdc54e2646ab6a9ae103e))

## [1.7.0](https://github.com/hyprpilot/hyprpilot.nvim/compare/hyprpilot.nvim-v1.6.2...hyprpilot.nvim-v1.7.0) (2026-05-17)


### Features

* **chat:** UX refresh — focus safety, queue sync, checklist, --- wraps, edgy ([#99](https://github.com/hyprpilot/hyprpilot.nvim/issues/99)) ([5ff16fe](https://github.com/hyprpilot/hyprpilot.nvim/commit/5ff16fef60b67f2c99a0e068aa9daa92b2e8c9cd))


### Bug Fixes

* **chat:** one space around every --- + composer attachment chat parity ([#101](https://github.com/hyprpilot/hyprpilot.nvim/issues/101)) ([835f916](https://github.com/hyprpilot/hyprpilot.nvim/commit/835f91613d04d5a54ce4f62e568a66aa74d9e307))

## [1.6.2](https://github.com/hyprpilot/hyprpilot.nvim/compare/hyprpilot.nvim-v1.6.1...hyprpilot.nvim-v1.6.2) (2026-05-16)


### Bug Fixes

* **render:** coalesce tool_call_update + cap output + skip unchanged renders ([#97](https://github.com/hyprpilot/hyprpilot.nvim/issues/97)) ([dd7fcb7](https://github.com/hyprpilot/hyprpilot.nvim/commit/dd7fcb7e28e70e623c169121f5548e5505e26073))

## [1.6.1](https://github.com/hyprpilot/hyprpilot.nvim/compare/hyprpilot.nvim-v1.6.0...hyprpilot.nvim-v1.6.1) (2026-05-16)


### Bug Fixes

* **chat:** cap terminal output + disable undo on plugin buffers (memory leak) ([#94](https://github.com/hyprpilot/hyprpilot.nvim/issues/94)) ([56ab44b](https://github.com/hyprpilot/hyprpilot.nvim/commit/56ab44b6a25864074247bc97bc996dc010e82e6b))
* **render:** drop per-block wire payloads after turn_ended ([#95](https://github.com/hyprpilot/hyprpilot.nvim/issues/95)) ([2d960c0](https://github.com/hyprpilot/hyprpilot.nvim/commit/2d960c03385a4b1a04eda6b8bc8e61a6c9609a0e))

## [1.6.0](https://github.com/hyprpilot/hyprpilot.nvim/compare/hyprpilot.nvim-v1.5.0...hyprpilot.nvim-v1.6.0) (2026-05-15)


### Features

* **palettes/instances:** cwd filter (mirrors palettes/sessions) ([#93](https://github.com/hyprpilot/hyprpilot.nvim/issues/93)) ([3164a64](https://github.com/hyprpilot/hyprpilot.nvim/commit/3164a64cc61ecfff8d9601a72440f5b2818b8c96))
* **render:** aggregate per-tool stats into `### tools` section header ([#91](https://github.com/hyprpilot/hyprpilot.nvim/issues/91)) ([d972ae9](https://github.com/hyprpilot/hyprpilot.nvim/commit/d972ae9b6cc91454391b1013f76816e870fa45f6))

## [1.5.0](https://github.com/hyprpilot/hyprpilot.nvim/compare/hyprpilot.nvim-v1.4.0...hyprpilot.nvim-v1.5.0) (2026-05-15)


### Features

* **render:** turn outcome as a prose-tail marker instead of a header pill ([#89](https://github.com/hyprpilot/hyprpilot.nvim/issues/89)) ([f6a807b](https://github.com/hyprpilot/hyprpilot.nvim/commit/f6a807bfc9d2a0bc5783d6509246a81d5ed2dbd4))

## [1.4.0](https://github.com/hyprpilot/hyprpilot.nvim/compare/hyprpilot.nvim-v1.3.1...hyprpilot.nvim-v1.4.0) (2026-05-15)


### Features

* **composer:** attach_file + dotted plugin fts + always-collapsed tools + leak fixes ([#88](https://github.com/hyprpilot/hyprpilot.nvim/issues/88)) ([5c7b8a6](https://github.com/hyprpilot/hyprpilot.nvim/commit/5c7b8a600de4cfc3eb375ca56bcd950f197a11ba))
* **instances:** with_shutdown opt — clean up owned instances on VimLeavePre ([#82](https://github.com/hyprpilot/hyprpilot.nvim/issues/82)) ([5caa48f](https://github.com/hyprpilot/hyprpilot.nvim/commit/5caa48f3b5411442daddbba24a8ff5cdfe4667d3))
* **mcp/editor:** status / file_open / jump / select / format tools ([#81](https://github.com/hyprpilot/hyprpilot.nvim/issues/81)) ([a66ca89](https://github.com/hyprpilot/hyprpilot.nvim/commit/a66ca899eb0ecf252dbabffb52de3d5812005b6b))


### Bug Fixes

* **chat:** re-assert fold setup on BufWinEnter / WinEnter ([#86](https://github.com/hyprpilot/hyprpilot.nvim/issues/86)) ([d27a22e](https://github.com/hyprpilot/hyprpilot.nvim/commit/d27a22e6e6c8a3b81634ef671a49b7f797370d04))
* header newline crash + instances palette attach for daemon-only ids ([#80](https://github.com/hyprpilot/hyprpilot.nvim/issues/80)) ([24e86e3](https://github.com/hyprpilot/hyprpilot.nvim/commit/24e86e30a3d0f1ca4486d396217990b55e3f06b4))
* **mcp/editor:** route navigation away from plugin windows + composer detach keymap ([#87](https://github.com/hyprpilot/hyprpilot.nvim/issues/87)) ([972de15](https://github.com/hyprpilot/hyprpilot.nvim/commit/972de15d2211fd674687d02adef169c1d613478e))
* **regressions:** per-instance isolation, header redesign, stats/folds, attachment body, reconnect ([#78](https://github.com/hyprpilot/hyprpilot.nvim/issues/78)) ([df87c74](https://github.com/hyprpilot/hyprpilot.nvim/commit/df87c74379a9f215b71594b47ad8c980117260c3))


### Refactor

* **composer:** rename hyprpilot_input → hyprpilot_composer + alias to markdown ([#84](https://github.com/hyprpilot/hyprpilot.nvim/issues/84)) ([3125b12](https://github.com/hyprpilot/hyprpilot.nvim/commit/3125b120682dfe17ee5b512f695a2e5f3c27dcf0))
* **queue:** daemon-mirror model — drop local FIFO, wire through queue/* RPCs ([#83](https://github.com/hyprpilot/hyprpilot.nvim/issues/83)) ([dd77240](https://github.com/hyprpilot/hyprpilot.nvim/commit/dd772403c102ea6daf9cd5752a5426dcf991b131))

## [1.3.1](https://github.com/hyprpilot/hyprpilot.nvim/compare/hyprpilot.nvim-v1.3.0...hyprpilot.nvim-v1.3.1) (2026-05-15)


### Bug Fixes

* **palettes/sessions:** wire title/updatedAt/_meta + sort by updated desc ([#76](https://github.com/hyprpilot/hyprpilot.nvim/issues/76)) ([fcc13a9](https://github.com/hyprpilot/hyprpilot.nvim/commit/fcc13a9b0dfa21748305d5e81eac52b5da2fd653))

## [1.3.0](https://github.com/hyprpilot/hyprpilot.nvim/compare/hyprpilot.nvim-v1.2.0...hyprpilot.nvim-v1.3.0) (2026-05-14)


### Features

* **palettes:** pass with_config through sessions/load ([#74](https://github.com/hyprpilot/hyprpilot.nvim/issues/74)) ([f39ca56](https://github.com/hyprpilot/hyprpilot.nvim/commit/f39ca5605a6dba4e10a2311a530a6d59c955ed64))

## [1.2.0](https://github.com/hyprpilot/hyprpilot.nvim/compare/hyprpilot.nvim-v1.1.2...hyprpilot.nvim-v1.2.0) (2026-05-14)


### Features

* **rpc:** global with_config baseline + collapse hand-rolled loops to vim.* helpers ([#71](https://github.com/hyprpilot/hyprpilot.nvim/issues/71)) ([49bd4f6](https://github.com/hyprpilot/hyprpilot.nvim/commit/49bd4f6907717362434c2db95ecfa7338a8e412c))


### Refactor

* **plugin:** drive treesitter filetype registration from a list ([#73](https://github.com/hyprpilot/hyprpilot.nvim/issues/73)) ([55ae8c1](https://github.com/hyprpilot/hyprpilot.nvim/commit/55ae8c1f490e73c78272630637f837c5bbcbdbec))

## [1.1.2](https://github.com/hyprpilot/hyprpilot.nvim/compare/hyprpilot.nvim-v1.1.1...hyprpilot.nvim-v1.1.2) (2026-05-14)


### Bug Fixes

* **ci:** inline pypi publish into release-please.yml (OIDC identity mismatch) ([#69](https://github.com/hyprpilot/hyprpilot.nvim/issues/69)) ([48d0601](https://github.com/hyprpilot/hyprpilot.nvim/commit/48d06011d89fede6cd774fc1420611dc165a2472))

## [1.1.1](https://github.com/hyprpilot/hyprpilot.nvim/compare/hyprpilot.nvim-v1.1.0...hyprpilot.nvim-v1.1.1) (2026-05-14)


### Bug Fixes

* **pkg:** build artifacts into pkg/dist (uv workspace default landed at repo root) ([#67](https://github.com/hyprpilot/hyprpilot.nvim/issues/67)) ([7a2c074](https://github.com/hyprpilot/hyprpilot.nvim/commit/7a2c07422cc109241a3f0cb945c7cc1a2e5c76bd))

## [1.1.0](https://github.com/hyprpilot/hyprpilot.nvim/compare/hyprpilot.nvim-v1.0.0...hyprpilot.nvim-v1.1.0) (2026-05-14)


### Features

* bootstrap repository scaffolding ([#1](https://github.com/hyprpilot/hyprpilot.nvim/issues/1)) ([bcf5de2](https://github.com/hyprpilot/hyprpilot.nvim/commit/bcf5de21b44f9db46fe652d44086af839328786a))
* **chat,palettes:** instances delete + transcript preview, gf, foldable code blocks ([#57](https://github.com/hyprpilot/hyprpilot.nvim/issues/57)) ([385dab5](https://github.com/hyprpilot/hyprpilot.nvim/commit/385dab520ed643b8b838ec5fc56c9e68d9ae0d95))
* **chat:** `### adapter` section for mode / config-option / system-prompt notifications ([#54](https://github.com/hyprpilot/hyprpilot.nvim/issues/54)) ([88a93e5](https://github.com/hyprpilot/hyprpilot.nvim/commit/88a93e594c5dd9e8e0b78dc3d8537adbf3c0a0b9))
* **chat:** `### request` / `### response` subheaders under captain / pilot ([#43](https://github.com/hyprpilot/hyprpilot.nvim/issues/43)) ([abf00de](https://github.com/hyprpilot/hyprpilot.nvim/commit/abf00deffe22dad849faf31f06a3e4487b448df9))
* **chat:** collapsible blocks + permission button group ([#18](https://github.com/hyprpilot/hyprpilot.nvim/issues/18)) ([0245b50](https://github.com/hyprpilot/hyprpilot.nvim/commit/0245b50f1a277d25c138e161edb53b407763993a))
* **chat:** live activity loop + cancel chip + terminal blocks + instance-state ([#25](https://github.com/hyprpilot/hyprpilot.nvim/issues/25)) ([dacfeb2](https://github.com/hyprpilot/hyprpilot.nvim/commit/dacfeb21f15e7274cedb33457942449f56c5b94a))
* **chat:** per-instance winbar with mode/model/usage chips + agent_attachment rendering ([#24](https://github.com/hyprpilot/hyprpilot.nvim/issues/24)) ([e52adf0](https://github.com/hyprpilot/hyprpilot.nvim/commit/e52adf09e71c4a88040744433e4898b0b5af1f1f))
* **chat:** render formatted.diff as a fenced diff block, skip Shiki description ([#38](https://github.com/hyprpilot/hyprpilot.nvim/issues/38)) ([97b004f](https://github.com/hyprpilot/hyprpilot.nvim/commit/97b004fb7f40cb74d10085ae26035cbb1635ae58))
* **chat:** render foundation + events subscribe + snapshot hydration ([#16](https://github.com/hyprpilot/hyprpilot.nvim/issues/16)) ([503a8ff](https://github.com/hyprpilot/hyprpilot.nvim/commit/503a8ff476fbb4047a606f8f922f15dd7d3f6a13))
* **chat:** snapshot pagination + events/lagged recovery ([#28](https://github.com/hyprpilot/hyprpilot.nvim/issues/28)) ([5391e60](https://github.com/hyprpilot/hyprpilot.nvim/commit/5391e60abf13b8dfd36c4ce9681d3c3135aa210e))
* **chat:** window management substrate ([#4](https://github.com/hyprpilot/hyprpilot.nvim/issues/4)) ([cf1a010](https://github.com/hyprpilot/hyprpilot.nvim/commit/cf1a01009e42fc9262b0c5a1ed79274c0081368d))
* **composer:** `paste_buffer` / `paste_selection` inlining helpers ([#50](https://github.com/hyprpilot/hyprpilot.nvim/issues/50)) ([7be4b3e](https://github.com/hyprpilot/hyprpilot.nvim/commit/7be4b3e89faa797a9d45e112689e0386e7cd5b36))
* **composer:** handle daemon-side prompts/send disposition + emit dispatch events ([#56](https://github.com/hyprpilot/hyprpilot.nvim/issues/56)) ([3d7812a](https://github.com/hyprpilot/hyprpilot.nvim/commit/3d7812a49af08d115e5972cd7b63fa4c7ee75640))
* **composer:** per-instance input split with submit + cancel ([#15](https://github.com/hyprpilot/hyprpilot.nvim/issues/15)) ([74cde13](https://github.com/hyprpilot/hyprpilot.nvim/commit/74cde13e5dbf061e6809129e4270cd7478d147fd))
* **composer:** per-instance submit queue + pinned queue-strip bar ([#47](https://github.com/hyprpilot/hyprpilot.nvim/issues/47)) ([ce791dc](https://github.com/hyprpilot/hyprpilot.nvim/commit/ce791dc6243f06dac2de1e9126f45c83618e04be))
* **composer:** pin attachments to the bottom as a virt_lines stack ([#51](https://github.com/hyprpilot/hyprpilot.nvim/issues/51)) ([501c67d](https://github.com/hyprpilot/hyprpilot.nvim/commit/501c67d34d4038a15d57d2362aa13630abb4f638))
* **composer:** staged attachments + img-clip + buffer-attach helpers ([#26](https://github.com/hyprpilot/hyprpilot.nvim/issues/26)) ([277247a](https://github.com/hyprpilot/hyprpilot.nvim/commit/277247a1e4cfa24b3e6adeb106e3f527311e9b15))
* **events:** fan daemon wire events out as User Hyprpilot&lt;*&gt; autocmds ([#39](https://github.com/hyprpilot/hyprpilot.nvim/issues/39)) ([52e47dd](https://github.com/hyprpilot/hyprpilot.nvim/commit/52e47dd893d576456cc761626c0e204a5d8b89e8))
* **header:** per-segment styled pills mirroring the desktop UI's Frame ([#35](https://github.com/hyprpilot/hyprpilot.nvim/issues/35)) ([9369f6f](https://github.com/hyprpilot/hyprpilot.nvim/commit/9369f6f26386ebe31ac7fe666d9b2aa473a93af7))
* **health:** full :checkhealth matrix + lazy agent header ([#20](https://github.com/hyprpilot/hyprpilot.nvim/issues/20)) ([ec21e75](https://github.com/hyprpilot/hyprpilot.nvim/commit/ec21e75b2470c5508dcfac77f10f6ce407b7fd09))
* **highlights:** default Hyprpilot* groups + render integration ([#22](https://github.com/hyprpilot/hyprpilot.nvim/issues/22)) ([045d778](https://github.com/hyprpilot/hyprpilot.nvim/commit/045d778d1ea959f050c2d49223a3832766cc47de))
* **instances:** `with_config` overlay patches on spawn / focus ([#55](https://github.com/hyprpilot/hyprpilot.nvim/issues/55)) ([59b40ed](https://github.com/hyprpilot/hyprpilot.nvim/commit/59b40ed1a3c82e43a12c422f98bb1c9caf27fb61))
* **instances:** multi-instance Lua API ([#13](https://github.com/hyprpilot/hyprpilot.nvim/issues/13)) ([fbd4dbb](https://github.com/hyprpilot/hyprpilot.nvim/commit/fbd4dbb6a7cf596da222f5a73208e305c9a9b9e5))
* **instances:** set_mode / set_model / set_option Lua API ([#27](https://github.com/hyprpilot/hyprpilot.nvim/issues/27)) ([7ef2ac3](https://github.com/hyprpilot/hyprpilot.nvim/commit/7ef2ac3d9af5dcfb911931eea0c1166a85aaf7df))
* JSON-RPC client + status surface (consolidates [#7](https://github.com/hyprpilot/hyprpilot.nvim/issues/7)–[#11](https://github.com/hyprpilot/hyprpilot.nvim/issues/11)) ([#12](https://github.com/hyprpilot/hyprpilot.nvim/issues/12)) ([01dad53](https://github.com/hyprpilot/hyprpilot.nvim/commit/01dad53be05d81145761fa556b034644299b0802))
* **mcp:** built-in lsp / editor / open tool categories ([#62](https://github.com/hyprpilot/hyprpilot.nvim/issues/62)) ([26e4071](https://github.com/hyprpilot/hyprpilot.nvim/commit/26e4071803bf9d2e444bc34dc20b39a908142ebf))
* **mcp:** lua-side tool registry surface ([#5](https://github.com/hyprpilot/hyprpilot.nvim/issues/5)) ([0303438](https://github.com/hyprpilot/hyprpilot.nvim/commit/0303438478ba4b221aa398bd4946051ba0e1e405))
* **mcp:** python dispatcher exposing lua-side tools ([#14](https://github.com/hyprpilot/hyprpilot.nvim/issues/14)) ([eb93461](https://github.com/hyprpilot/hyprpilot.nvim/commit/eb93461c2b4330bd70b70b3e8862fdc4f83cb476))
* **notification:** attention list + opt-in bell + picker + bufnr on events ([#53](https://github.com/hyprpilot/hyprpilot.nvim/issues/53)) ([78c0d0d](https://github.com/hyprpilot/hyprpilot.nvim/commit/78c0d0db6d412fce62de27224c4d2b7ea58868df))
* **palettes,completion:** snacks previews + blink.cmp completion source ([#34](https://github.com/hyprpilot/hyprpilot.nvim/issues/34)) ([e7e0638](https://github.com/hyprpilot/hyprpilot.nvim/commit/e7e0638cab484ec461acb36463dd2c754cc5aa7d))
* **palettes:** vim.ui.select pickers for instances/modes/models/effort/sessions ([#32](https://github.com/hyprpilot/hyprpilot.nvim/issues/32)) ([f744479](https://github.com/hyprpilot/hyprpilot.nvim/commit/f74447927fa7664f3d749a23bb6e7e488f53be06))
* **profiles:** list RPC + new-instance palette ([#48](https://github.com/hyprpilot/hyprpilot.nvim/issues/48)) ([82a7f6c](https://github.com/hyprpilot/hyprpilot.nvim/commit/82a7f6cf4b261d1c82427994a63639cf0438848f))
* **sessions:** default `cwd` filter to vim cwd; `cwd = false` opts out ([#49](https://github.com/hyprpilot/hyprpilot.nvim/issues/49)) ([a6dd6b9](https://github.com/hyprpilot/hyprpilot.nvim/commit/a6dd6b9a071bdd440bedae06f6ec0160786f25b7))
* **shutdown:** graceful VimLeavePre teardown (windows + events + client) ([#37](https://github.com/hyprpilot/hyprpilot.nvim/issues/37)) ([6b8a823](https://github.com/hyprpilot/hyprpilot.nvim/commit/6b8a823e1abc7f08ec1558e24346d009263b6934))
* **ui,rpc:** focus helper + inbound rpc handlers (`nvim/*`) ([#52](https://github.com/hyprpilot/hyprpilot.nvim/issues/52)) ([3091f6b](https://github.com/hyprpilot/hyprpilot.nvim/commit/3091f6b1d7b7d595040aeec090e11b5aca62ac58))
* **ui:** inline diff preview for edit-tool permission requests ([#58](https://github.com/hyprpilot/hyprpilot.nvim/issues/58)) ([b88d3e0](https://github.com/hyprpilot/hyprpilot.nvim/commit/b88d3e07c6045be4394af96373b829ea5ab636f5))


### Bug Fixes

* **buffer:** adopt existing named buffers in ensure_buffer paths ([#41](https://github.com/hyprpilot/hyprpilot.nvim/issues/41)) ([83ae70b](https://github.com/hyprpilot/hyprpilot.nvim/commit/83ae70b7e6b04fbc216c59c6b433c89f5a78fd36))
* **chat:** partition replay items by conversational exchange, not just daemon turn_id ([#40](https://github.com/hyprpilot/hyprpilot.nvim/issues/40)) ([cf61904](https://github.com/hyprpilot/hyprpilot.nvim/commit/cf6190424f7d59b186831e1146ea64442e5d5e31))
* **chat:** pcall window focus + WinClosed cascade + vim.NIL at JSON boundary ([#59](https://github.com/hyprpilot/hyprpilot.nvim/issues/59)) ([fcec720](https://github.com/hyprpilot/hyprpilot.nvim/commit/fcec720d9a8bdbbca888745aaa0228c0dcbaf0c0))
* **ci:** chain publish-pypi via release-please outputs (GITHUB_TOKEN anti-loop) ([#64](https://github.com/hyprpilot/hyprpilot.nvim/issues/64)) ([a49dda4](https://github.com/hyprpilot/hyprpilot.nvim/commit/a49dda45fee88c22984c88f245e24bde51d5eaa9))
* **header:** tolerate vim.NIL (JSON-null) in meta fields during replay ([#36](https://github.com/hyprpilot/hyprpilot.nvim/issues/36)) ([5a42e5d](https://github.com/hyprpilot/hyprpilot.nvim/commit/5a42e5dbe03d942e444b824110c0a92d3a8b65cc))
* initial commit ([a707fab](https://github.com/hyprpilot/hyprpilot.nvim/commit/a707fab38db23260bfeaf947e3c680c9e9b1f031))
* NDJSON framing in client + spawn timeout + placeholder require path ([#31](https://github.com/hyprpilot/hyprpilot.nvim/issues/31)) ([26afe5f](https://github.com/hyprpilot/hyprpilot.nvim/commit/26afe5fb8204ab98ec981a6c43da4556d66ec161))
* remove docs ([b88d3e0](https://github.com/hyprpilot/hyprpilot.nvim/commit/b88d3e07c6045be4394af96373b829ea5ab636f5))
* **ux:** cancel wire shape, edgy compat, localleader, icons, queue edit ([#60](https://github.com/hyprpilot/hyprpilot.nvim/issues/60)) ([c56b621](https://github.com/hyprpilot/hyprpilot.nvim/commit/c56b6219b40c5f15a4309113532a0a540699d21e))
* **window:** close cascade also wipes composer + drops perm queue entries ([#46](https://github.com/hyprpilot/hyprpilot.nvim/issues/46)) ([e817902](https://github.com/hyprpilot/hyprpilot.nvim/commit/e817902cc43713f30e23132eed1d925da92747ca))


### Refactor

* **chat,client:** consolidate keymap + aux-split helpers, fix socket_path throw ([#61](https://github.com/hyprpilot/hyprpilot.nvim/issues/61)) ([b8b713e](https://github.com/hyprpilot/hyprpilot.nvim/commit/b8b713e85799f2eb69430905086ed5da62902364))
* **ci:** single-version release-please config (drop multi-package) ([#65](https://github.com/hyprpilot/hyprpilot.nvim/issues/65)) ([7642b43](https://github.com/hyprpilot/hyprpilot.nvim/commit/7642b43bff6bdf8480cfe44658f3eec0a7765a66))


### Documentation

* capture session deviations + choices in CLAUDE.md ([#17](https://github.com/hyprpilot/hyprpilot.nvim/issues/17)) ([ad2d0f1](https://github.com/hyprpilot/hyprpilot.nvim/commit/ad2d0f13a9efbf756ab60d6028f2d249ffc626eb))
* distill review-driven coding rules into CLAUDE.md ([#6](https://github.com/hyprpilot/hyprpilot.nvim/issues/6)) ([f0a6eb2](https://github.com/hyprpilot/hyprpilot.nvim/commit/f0a6eb2bdd4888f2dc3015e77c9fb094ba34bb58))
* full README for v1 ship ([#23](https://github.com/hyprpilot/hyprpilot.nvim/issues/23)) ([b643890](https://github.com/hyprpilot/hyprpilot.nvim/commit/b643890cb766c0c364af41179481f6c3f0791bab))

## 1.0.0 (2026-05-14)


### Features

* bootstrap repository scaffolding ([#1](https://github.com/hyprpilot/hyprpilot.nvim/issues/1)) ([bcf5de2](https://github.com/hyprpilot/hyprpilot.nvim/commit/bcf5de21b44f9db46fe652d44086af839328786a))
* **chat,palettes:** instances delete + transcript preview, gf, foldable code blocks ([#57](https://github.com/hyprpilot/hyprpilot.nvim/issues/57)) ([385dab5](https://github.com/hyprpilot/hyprpilot.nvim/commit/385dab520ed643b8b838ec5fc56c9e68d9ae0d95))
* **chat:** `### adapter` section for mode / config-option / system-prompt notifications ([#54](https://github.com/hyprpilot/hyprpilot.nvim/issues/54)) ([88a93e5](https://github.com/hyprpilot/hyprpilot.nvim/commit/88a93e594c5dd9e8e0b78dc3d8537adbf3c0a0b9))
* **chat:** `### request` / `### response` subheaders under captain / pilot ([#43](https://github.com/hyprpilot/hyprpilot.nvim/issues/43)) ([abf00de](https://github.com/hyprpilot/hyprpilot.nvim/commit/abf00deffe22dad849faf31f06a3e4487b448df9))
* **chat:** collapsible blocks + permission button group ([#18](https://github.com/hyprpilot/hyprpilot.nvim/issues/18)) ([0245b50](https://github.com/hyprpilot/hyprpilot.nvim/commit/0245b50f1a277d25c138e161edb53b407763993a))
* **chat:** live activity loop + cancel chip + terminal blocks + instance-state ([#25](https://github.com/hyprpilot/hyprpilot.nvim/issues/25)) ([dacfeb2](https://github.com/hyprpilot/hyprpilot.nvim/commit/dacfeb21f15e7274cedb33457942449f56c5b94a))
* **chat:** per-instance winbar with mode/model/usage chips + agent_attachment rendering ([#24](https://github.com/hyprpilot/hyprpilot.nvim/issues/24)) ([e52adf0](https://github.com/hyprpilot/hyprpilot.nvim/commit/e52adf09e71c4a88040744433e4898b0b5af1f1f))
* **chat:** render formatted.diff as a fenced diff block, skip Shiki description ([#38](https://github.com/hyprpilot/hyprpilot.nvim/issues/38)) ([97b004f](https://github.com/hyprpilot/hyprpilot.nvim/commit/97b004fb7f40cb74d10085ae26035cbb1635ae58))
* **chat:** render foundation + events subscribe + snapshot hydration ([#16](https://github.com/hyprpilot/hyprpilot.nvim/issues/16)) ([503a8ff](https://github.com/hyprpilot/hyprpilot.nvim/commit/503a8ff476fbb4047a606f8f922f15dd7d3f6a13))
* **chat:** snapshot pagination + events/lagged recovery ([#28](https://github.com/hyprpilot/hyprpilot.nvim/issues/28)) ([5391e60](https://github.com/hyprpilot/hyprpilot.nvim/commit/5391e60abf13b8dfd36c4ce9681d3c3135aa210e))
* **chat:** window management substrate ([#4](https://github.com/hyprpilot/hyprpilot.nvim/issues/4)) ([cf1a010](https://github.com/hyprpilot/hyprpilot.nvim/commit/cf1a01009e42fc9262b0c5a1ed79274c0081368d))
* **composer:** `paste_buffer` / `paste_selection` inlining helpers ([#50](https://github.com/hyprpilot/hyprpilot.nvim/issues/50)) ([7be4b3e](https://github.com/hyprpilot/hyprpilot.nvim/commit/7be4b3e89faa797a9d45e112689e0386e7cd5b36))
* **composer:** handle daemon-side prompts/send disposition + emit dispatch events ([#56](https://github.com/hyprpilot/hyprpilot.nvim/issues/56)) ([3d7812a](https://github.com/hyprpilot/hyprpilot.nvim/commit/3d7812a49af08d115e5972cd7b63fa4c7ee75640))
* **composer:** per-instance input split with submit + cancel ([#15](https://github.com/hyprpilot/hyprpilot.nvim/issues/15)) ([74cde13](https://github.com/hyprpilot/hyprpilot.nvim/commit/74cde13e5dbf061e6809129e4270cd7478d147fd))
* **composer:** per-instance submit queue + pinned queue-strip bar ([#47](https://github.com/hyprpilot/hyprpilot.nvim/issues/47)) ([ce791dc](https://github.com/hyprpilot/hyprpilot.nvim/commit/ce791dc6243f06dac2de1e9126f45c83618e04be))
* **composer:** pin attachments to the bottom as a virt_lines stack ([#51](https://github.com/hyprpilot/hyprpilot.nvim/issues/51)) ([501c67d](https://github.com/hyprpilot/hyprpilot.nvim/commit/501c67d34d4038a15d57d2362aa13630abb4f638))
* **composer:** staged attachments + img-clip + buffer-attach helpers ([#26](https://github.com/hyprpilot/hyprpilot.nvim/issues/26)) ([277247a](https://github.com/hyprpilot/hyprpilot.nvim/commit/277247a1e4cfa24b3e6adeb106e3f527311e9b15))
* **events:** fan daemon wire events out as User Hyprpilot&lt;*&gt; autocmds ([#39](https://github.com/hyprpilot/hyprpilot.nvim/issues/39)) ([52e47dd](https://github.com/hyprpilot/hyprpilot.nvim/commit/52e47dd893d576456cc761626c0e204a5d8b89e8))
* **header:** per-segment styled pills mirroring the desktop UI's Frame ([#35](https://github.com/hyprpilot/hyprpilot.nvim/issues/35)) ([9369f6f](https://github.com/hyprpilot/hyprpilot.nvim/commit/9369f6f26386ebe31ac7fe666d9b2aa473a93af7))
* **health:** full :checkhealth matrix + lazy agent header ([#20](https://github.com/hyprpilot/hyprpilot.nvim/issues/20)) ([ec21e75](https://github.com/hyprpilot/hyprpilot.nvim/commit/ec21e75b2470c5508dcfac77f10f6ce407b7fd09))
* **highlights:** default Hyprpilot* groups + render integration ([#22](https://github.com/hyprpilot/hyprpilot.nvim/issues/22)) ([045d778](https://github.com/hyprpilot/hyprpilot.nvim/commit/045d778d1ea959f050c2d49223a3832766cc47de))
* **instances:** `with_config` overlay patches on spawn / focus ([#55](https://github.com/hyprpilot/hyprpilot.nvim/issues/55)) ([59b40ed](https://github.com/hyprpilot/hyprpilot.nvim/commit/59b40ed1a3c82e43a12c422f98bb1c9caf27fb61))
* **instances:** multi-instance Lua API ([#13](https://github.com/hyprpilot/hyprpilot.nvim/issues/13)) ([fbd4dbb](https://github.com/hyprpilot/hyprpilot.nvim/commit/fbd4dbb6a7cf596da222f5a73208e305c9a9b9e5))
* **instances:** set_mode / set_model / set_option Lua API ([#27](https://github.com/hyprpilot/hyprpilot.nvim/issues/27)) ([7ef2ac3](https://github.com/hyprpilot/hyprpilot.nvim/commit/7ef2ac3d9af5dcfb911931eea0c1166a85aaf7df))
* JSON-RPC client + status surface (consolidates [#7](https://github.com/hyprpilot/hyprpilot.nvim/issues/7)–[#11](https://github.com/hyprpilot/hyprpilot.nvim/issues/11)) ([#12](https://github.com/hyprpilot/hyprpilot.nvim/issues/12)) ([01dad53](https://github.com/hyprpilot/hyprpilot.nvim/commit/01dad53be05d81145761fa556b034644299b0802))
* **mcp:** built-in lsp / editor / open tool categories ([#62](https://github.com/hyprpilot/hyprpilot.nvim/issues/62)) ([26e4071](https://github.com/hyprpilot/hyprpilot.nvim/commit/26e4071803bf9d2e444bc34dc20b39a908142ebf))
* **mcp:** lua-side tool registry surface ([#5](https://github.com/hyprpilot/hyprpilot.nvim/issues/5)) ([0303438](https://github.com/hyprpilot/hyprpilot.nvim/commit/0303438478ba4b221aa398bd4946051ba0e1e405))
* **mcp:** python dispatcher exposing lua-side tools ([#14](https://github.com/hyprpilot/hyprpilot.nvim/issues/14)) ([eb93461](https://github.com/hyprpilot/hyprpilot.nvim/commit/eb93461c2b4330bd70b70b3e8862fdc4f83cb476))
* **notification:** attention list + opt-in bell + picker + bufnr on events ([#53](https://github.com/hyprpilot/hyprpilot.nvim/issues/53)) ([78c0d0d](https://github.com/hyprpilot/hyprpilot.nvim/commit/78c0d0db6d412fce62de27224c4d2b7ea58868df))
* **palettes,completion:** snacks previews + blink.cmp completion source ([#34](https://github.com/hyprpilot/hyprpilot.nvim/issues/34)) ([e7e0638](https://github.com/hyprpilot/hyprpilot.nvim/commit/e7e0638cab484ec461acb36463dd2c754cc5aa7d))
* **palettes:** vim.ui.select pickers for instances/modes/models/effort/sessions ([#32](https://github.com/hyprpilot/hyprpilot.nvim/issues/32)) ([f744479](https://github.com/hyprpilot/hyprpilot.nvim/commit/f74447927fa7664f3d749a23bb6e7e488f53be06))
* **profiles:** list RPC + new-instance palette ([#48](https://github.com/hyprpilot/hyprpilot.nvim/issues/48)) ([82a7f6c](https://github.com/hyprpilot/hyprpilot.nvim/commit/82a7f6cf4b261d1c82427994a63639cf0438848f))
* **sessions:** default `cwd` filter to vim cwd; `cwd = false` opts out ([#49](https://github.com/hyprpilot/hyprpilot.nvim/issues/49)) ([a6dd6b9](https://github.com/hyprpilot/hyprpilot.nvim/commit/a6dd6b9a071bdd440bedae06f6ec0160786f25b7))
* **shutdown:** graceful VimLeavePre teardown (windows + events + client) ([#37](https://github.com/hyprpilot/hyprpilot.nvim/issues/37)) ([6b8a823](https://github.com/hyprpilot/hyprpilot.nvim/commit/6b8a823e1abc7f08ec1558e24346d009263b6934))
* **ui,rpc:** focus helper + inbound rpc handlers (`nvim/*`) ([#52](https://github.com/hyprpilot/hyprpilot.nvim/issues/52)) ([3091f6b](https://github.com/hyprpilot/hyprpilot.nvim/commit/3091f6b1d7b7d595040aeec090e11b5aca62ac58))
* **ui:** inline diff preview for edit-tool permission requests ([#58](https://github.com/hyprpilot/hyprpilot.nvim/issues/58)) ([b88d3e0](https://github.com/hyprpilot/hyprpilot.nvim/commit/b88d3e07c6045be4394af96373b829ea5ab636f5))


### Bug Fixes

* **buffer:** adopt existing named buffers in ensure_buffer paths ([#41](https://github.com/hyprpilot/hyprpilot.nvim/issues/41)) ([83ae70b](https://github.com/hyprpilot/hyprpilot.nvim/commit/83ae70b7e6b04fbc216c59c6b433c89f5a78fd36))
* **chat:** partition replay items by conversational exchange, not just daemon turn_id ([#40](https://github.com/hyprpilot/hyprpilot.nvim/issues/40)) ([cf61904](https://github.com/hyprpilot/hyprpilot.nvim/commit/cf6190424f7d59b186831e1146ea64442e5d5e31))
* **chat:** pcall window focus + WinClosed cascade + vim.NIL at JSON boundary ([#59](https://github.com/hyprpilot/hyprpilot.nvim/issues/59)) ([fcec720](https://github.com/hyprpilot/hyprpilot.nvim/commit/fcec720d9a8bdbbca888745aaa0228c0dcbaf0c0))
* **header:** tolerate vim.NIL (JSON-null) in meta fields during replay ([#36](https://github.com/hyprpilot/hyprpilot.nvim/issues/36)) ([5a42e5d](https://github.com/hyprpilot/hyprpilot.nvim/commit/5a42e5dbe03d942e444b824110c0a92d3a8b65cc))
* initial commit ([a707fab](https://github.com/hyprpilot/hyprpilot.nvim/commit/a707fab38db23260bfeaf947e3c680c9e9b1f031))
* NDJSON framing in client + spawn timeout + placeholder require path ([#31](https://github.com/hyprpilot/hyprpilot.nvim/issues/31)) ([26afe5f](https://github.com/hyprpilot/hyprpilot.nvim/commit/26afe5fb8204ab98ec981a6c43da4556d66ec161))
* remove docs ([b88d3e0](https://github.com/hyprpilot/hyprpilot.nvim/commit/b88d3e07c6045be4394af96373b829ea5ab636f5))
* **ux:** cancel wire shape, edgy compat, localleader, icons, queue edit ([#60](https://github.com/hyprpilot/hyprpilot.nvim/issues/60)) ([c56b621](https://github.com/hyprpilot/hyprpilot.nvim/commit/c56b6219b40c5f15a4309113532a0a540699d21e))
* **window:** close cascade also wipes composer + drops perm queue entries ([#46](https://github.com/hyprpilot/hyprpilot.nvim/issues/46)) ([e817902](https://github.com/hyprpilot/hyprpilot.nvim/commit/e817902cc43713f30e23132eed1d925da92747ca))


### Refactor

* **chat,client:** consolidate keymap + aux-split helpers, fix socket_path throw ([#61](https://github.com/hyprpilot/hyprpilot.nvim/issues/61)) ([b8b713e](https://github.com/hyprpilot/hyprpilot.nvim/commit/b8b713e85799f2eb69430905086ed5da62902364))


### Documentation

* capture session deviations + choices in CLAUDE.md ([#17](https://github.com/hyprpilot/hyprpilot.nvim/issues/17)) ([ad2d0f1](https://github.com/hyprpilot/hyprpilot.nvim/commit/ad2d0f13a9efbf756ab60d6028f2d249ffc626eb))
* distill review-driven coding rules into CLAUDE.md ([#6](https://github.com/hyprpilot/hyprpilot.nvim/issues/6)) ([f0a6eb2](https://github.com/hyprpilot/hyprpilot.nvim/commit/f0a6eb2bdd4888f2dc3015e77c9fb094ba34bb58))
* full README for v1 ship ([#23](https://github.com/hyprpilot/hyprpilot.nvim/issues/23)) ([b643890](https://github.com/hyprpilot/hyprpilot.nvim/commit/b643890cb766c0c364af41179481f6c3f0791bab))
