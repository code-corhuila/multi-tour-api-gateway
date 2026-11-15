# Changelog

All notable changes of `multi-tour-api-gateway` (NGINX gateway) are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [3.0.0] - 2026-11-14

Cut 3 release. Every entry below is a pull request merged into `qa` and re-applied to `release/3.0.0` with `git cherry-pick -x`; the heading of each group is the user story named in the pull request, and the entry is the title of the pull request without its type. The frozen head of `qa` is `102e98bb7f56960b805e30328503c696888f83fd`.

### Changed

#### HU-COM-002 - Manage associated establishments

- The proof upload limit and the public image cache ([PR 16](https://github.com/code-corhuila/multi-tour-api-gateway/pull/16))

#### HU-FRT-001 - Mount the four portals in one container

- The cash-reporting portal route ([PR 9](https://github.com/code-corhuila/multi-tour-api-gateway/pull/9))

#### HU-GW-001 - Enter the platform through one gateway

- The portal module path rewrite ([PR 12](https://github.com/code-corhuila/multi-tour-api-gateway/pull/12))

#### HU-IDA-005 - Maintain the tenant's logo and commercial images

- Let the logo and the images of a tenant through and keep the public files cacheable ([PR 19](https://github.com/code-corhuila/multi-tour-api-gateway/pull/19))

#### HU-WFL-005 - Change the vehicles of a departure

- The 150 s wait of the saga of the vehicles ([PR 17](https://github.com/code-corhuila/multi-tour-api-gateway/pull/17))

[Unreleased]: https://github.com/code-corhuila/multi-tour-api-gateway/compare/v3.0.0...HEAD
[3.0.0]: https://github.com/code-corhuila/multi-tour-api-gateway/releases/tag/v3.0.0
